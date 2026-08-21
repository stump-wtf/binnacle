defmodule Binnacle.Fleet.Proxmox.Client do
  # Proxmox VE API client for host discovery (SPEC-0001 REQ proxmox).
  #
  # One call, `fetch/2`, produces everything the fleet context needs for a
  # host poll: node status, the guest list (qemu + lxc), and a normalized
  # hardware Sample. Requests use an API token (PVEAPIToken header), a 5s
  # connect timeout, and no retries — poll cadence is the retry.
  #
  # The client never talks to a host that is not in the baseline config;
  # authorization to poll comes from the config, not from discovery.
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001 REQ proxmox.

  alias Binnacle.Fleet.Model.{Guest, Sample}

  @timeout 5_000

  @doc """
  Poll one Proxmox host.

  Returns `{:ok, %{guests: [Guest.t()], sample: Sample.t() | nil, node_status: map(), nodes: [String.t()]}}`
  or `{:error, reason}` with the failing step named. The sample is nil when
  the host answers but exposes no sensor data — missing metrics are omitted,
  never zero-filled. `nodes` is the list of all node names the API reported,
  used by the Fleet to detect config drift (a node nobody declared).
  """
  @spec fetch(String.t(), String.t(), keyword()) ::
          {:ok,
           %{
             guests: [Guest.t()],
             sample: Sample.t() | nil,
             node_status: map(),
             nodes: [String.t()]
           }}
          | {:error, String.t()}
  def fetch(base_url, token, opts \\ []) do
    base_url = String.trim_trailing(base_url, "/")

    with {:ok, node, all_nodes} <-
           request(base_url, token, "/api2/json/nodes", opts) |> nodes(opts),
         {:ok, node_status} <-
           request(base_url, token, "/api2/json/nodes/#{node}/status", opts) |> body(opts),
         {:ok, qemu} <-
           request(base_url, token, "/api2/json/nodes/#{node}/qemu", opts)
           |> body(opts)
           |> guest_list("/qemu"),
         {:ok, lxc} <-
           request(base_url, token, "/api2/json/nodes/#{node}/lxc", opts)
           |> body(opts)
           |> guest_list("/lxc") do
      guests =
        (decode_guests(qemu, "qemu") ++ decode_guests(lxc, "lxc"))
        |> Enum.sort_by(& &1.vmid)

      {:ok,
       %{
         guests: guests,
         sample: sample(node_status),
         node_status: node_status,
         nodes: all_nodes
       }}
    end
  end

  # A node name from /nodes: the single node this API endpoint serves. If the
  # endpoint reports several (a multi-node address), take the first online
  # node — v1 scopes one API token per host.
  defp nodes({:ok, %Req.Response{status: 200, body: body}}, _opts) do
    with {:ok, %{"data" => nodes}} <- decode_body(body, "/api2/json/nodes") do
      all_names = Enum.map(nodes, & &1["node"])

      case Enum.find(nodes, &(&1["status"] == "online")) || List.first(nodes) do
        %{"node" => name} -> {:ok, name, all_names}
        _ -> {:error, "Proxmox /api2/json/nodes returned no nodes"}
      end
    end
  end

  defp nodes({:ok, %Req.Response{status: status}}, _opts),
    do: {:error, "Proxmox /api2/json/nodes answered HTTP #{status}"}

  defp nodes({:error, err}, _opts),
    do: {:error, "Proxmox /api2/json/nodes unreachable: #{format(err)}"}

  defp body({:ok, %Req.Response{status: 200, body: body}}, _opts) do
    with {:ok, %{"data" => data}} <- decode_body(body, "the node endpoint") do
      {:ok, data}
    end
  end

  defp body({:ok, %Req.Response{status: status}}, _opts),
    do: {:error, "Proxmox answered HTTP #{status}"}

  defp body({:error, err}, _opts), do: {:error, "Proxmox unreachable: #{format(err)}"}

  defp request(base_url, token, path, opts) do
    options =
      [
        base_url: base_url,
        url: path,
        headers: [authorization: "PVEAPIToken=#{token}"],
        receive_timeout: Keyword.get(opts, :timeout, @timeout),
        retry: false,
        decode_body: false
      ] ++ Keyword.take(opts, [:plug])

    options
    |> Req.new()
    |> Req.request()
  end

  # `data` is only a list when the token may actually read the endpoint. A
  # least-privilege token gets `{"data": null}` instead, and mapping over that
  # raised Protocol.UndefinedError inside the poller's handle_info -- which
  # crashes the poller, and OTP crash reports render the GenServer state. The
  # token lives in that state, so the narrow decode bug was also the way a
  # credential reached the logs. Name it as a failed poll instead; the Fleet's
  # miss counter degrades the host, which is the designed response.
  defp guest_list({:ok, entries}, _path) when is_list(entries), do: {:ok, entries}

  defp guest_list({:ok, _other}, path),
    do: {:error, "Proxmox #{path} returned no guest list (token may lack permission)"}

  defp guest_list({:error, _} = err, _path), do: err

  defp decode_guests(entries, kind) do
    Enum.map(entries, fn entry ->
      %Guest{
        vmid: entry["vmid"],
        host: entry["node"],
        name: entry["name"] || "vm-#{entry["vmid"]}",
        containers: [],
        hardware: [],
        status: guest_status(entry["status"], kind)
      }
    end)
  end

  defp guest_status("running", _), do: :up
  defp guest_status("stopped", _), do: :down
  defp guest_status(_, "lxc"), do: :up
  defp guest_status(_, _), do: :unknown

  # Normalize node status into a Sample. CPU/memory/load come from the
  # status payload; temperatures only when the node exposes them (pve
  # sensors in `sensors` or cpu package temp in `cpuinfo`).
  defp sample(%{"cpu" => cpu, "memory" => mem} = status) do
    %Sample{
      at: DateTime.utc_now(),
      cpu: percent(cpu),
      gpu: nil,
      memory: percent(ratio(mem["used"], mem["total"])),
      disk: nil,
      cpu_temp: temp(status["sensors"]),
      gpu_temp: nil,
      hdd_temp: nil
    }
  end

  defp sample(_), do: nil

  # `value * 100` is an INTEGER when Proxmox reports an integer, and
  # Float.round/2 only accepts floats — so a node reporting `"cpu": 0` raised
  # FunctionClauseError inside the poller's handle_info and crash-looped it.
  #
  # An idle node is exactly the one that does this: PVE serializes 0.0 as `0`,
  # so the nodes that never crash are the busy ones. nyma, a fresh hypervisor
  # with no guests, was the first to hit it — and only once authentication
  # started working, because before that no reading ever got this far.
  #
  # Third bug of this shape in this function (see `ratio/2` below, and the
  # null guest list above): Proxmox's JSON types are not stable across load,
  # and every metric has to survive the idle case.
  defp percent(value) when is_number(value), do: Float.round(value * 100.0, 1)
  defp percent(_), do: nil

  # `total || 1` did not guard this: 0 is truthy in Elixir, so a node
  # reporting zero total memory divided by zero and raised. An absent metric
  # is nil, per the "omitted, never zero-filled" rule above.
  defp ratio(used, total) when is_number(used) and is_number(total) and total > 0,
    do: used / total

  defp ratio(_used, _total), do: nil

  # Temperature extraction: any node-level cpu/package sensor entry shaped
  # like %{"cpu-package" => %{"temperature" => n}} (board-dependent; absence
  # is normal and yields nil).
  defp temp(%{} = sensors) do
    sensors
    |> Map.values()
    |> Enum.find_value(fn
      %{"temperature" => t} when is_number(t) -> Float.round(t * 1.0, 1)
      _ -> nil
    end)
  end

  defp temp(_), do: nil

  defp decode_body(body, _what) when is_map(body), do: {:ok, body}

  defp decode_body(body, what) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, err} ->
        {:error, "Proxmox #{what} returned undecodable JSON: #{Exception.message(err)}"}
    end
  end

  defp decode_body(_body, what), do: {:error, "Proxmox #{what} returned no JSON"}

  defp format(%{__exception__: true} = err), do: Exception.message(err)
  defp format(other), do: inspect(other)
end
