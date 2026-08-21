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

  alias Binnacle.Fleet.Model.{Disk, Guest, Sample, ZfsPool}

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

  @doc """
  Poll disk health on one Proxmox host: the physical disk list with SMART
  health, and per-disk SMART attributes for the ones that support it.

  Returns `{:ok, [Disk.t()]}` or `{:error, reason}`. Disks that fail SMART
  parsing are still returned with `health: :unknown` — a partial answer is
  better than dropping the whole list.
  """
  @spec fetch_disks(String.t(), String.t(), keyword()) ::
          {:ok, [Disk.t()]} | {:error, String.t()}
  def fetch_disks(base_url, token, opts \\ []) do
    base_url = String.trim_trailing(base_url, "/")

    with {:ok, node} <- request(base_url, token, "/api2/json/nodes", opts) |> nodes(opts),
         {:ok, disk_list} <-
           request(base_url, token, "/api2/json/nodes/#{node}/disks/list", opts)
           |> body(opts) do
      disks =
        Enum.map(disk_list, fn entry ->
          device = entry["devpath"] || "/dev/unknown"

          smart =
            if entry["health"] && entry["health"] != "UNKNOWN" do
              fetch_smart(base_url, token, node, device, opts)
            else
              nil
            end

          {temp, attrs} =
            case smart do
              %{attributes: a} when is_list(a) -> {smart_temp(a), parse_smart_attrs(a)}
              _ -> {nil, %{}}
            end

          %Disk{
            device: device,
            model: entry["model"],
            serial: entry["serial"],
            size: entry["size"],
            type: disk_type(entry["type"]),
            health: smart_health(entry["health"]),
            temperature: temp,
            attributes: attrs,
            wearout: wearout(entry["wearout"])
          }
        end)

      {:ok, disks}
    end
  end

  @doc """
  Poll ZFS pool health on one Proxmox host.

  Returns `{:ok, [ZfsPool.t()]}` or `{:error, reason}`. An empty list means
  the host has no ZFS pools — not an error.
  """
  @spec fetch_pools(String.t(), String.t(), keyword()) ::
          {:ok, [ZfsPool.t()]} | {:error, String.t()}
  def fetch_pools(base_url, token, opts \\ []) do
    base_url = String.trim_trailing(base_url, "/")

    with {:ok, node} <- request(base_url, token, "/api2/json/nodes", opts) |> nodes(opts),
         {:ok, pool_list} <-
           request(base_url, token, "/api2/json/nodes/#{node}/disks/zfs", opts)
           |> body(opts) do
      pools =
        Enum.map(pool_list, fn entry ->
          %ZfsPool{
            name: entry["name"],
            state: pool_state(entry["health"]),
            size: entry["size"],
            allocated: entry["alloc"],
            free: entry["free"],
            fragmentation: entry["frag"],
            errors: nil,
            scan: nil,
            vdevs: []
          }
        end)

      {:ok, pools}
    end
  end

  # Fetch SMART attributes for a single disk. Non-fatal: returns nil on any
  # error so one uncooperative disk does not take down the whole list.
  defp fetch_smart(base_url, token, node, device, opts) do
    path = "/api2/json/nodes/#{node}/disks/smart?disk=#{URI.encode_www_form(device)}"

    case request(base_url, token, path, opts) |> body(opts) do
      {:ok, %{"health" => health, "attributes" => attrs}} ->
        %{health: smart_health(health), attributes: attrs}

      {:ok, %{"health" => health}} ->
        %{health: smart_health(health), attributes: []}

      _ ->
        nil
    end
  end

  defp smart_health("PASSED"), do: :passed
  defp smart_health("FAILED"), do: :failed
  defp smart_health(_), do: :unknown

  defp disk_type("hdd"), do: :hdd
  defp disk_type("ssd"), do: :ssd
  defp disk_type("nvme"), do: :nvme
  defp disk_type("usb"), do: :usb
  defp disk_type(_), do: :unknown

  defp wearout(value) when is_integer(value), do: value
  defp wearout(_), do: nil

  defp pool_state("ONLINE"), do: :online
  defp pool_state("DEGRADED"), do: :degraded
  defp pool_state("FAULTED"), do: :faulted
  defp pool_state("SUSPENDED"), do: :suspended
  defp pool_state(_), do: :unknown

  # Extract temperature from SMART attributes. The attribute name varies by
  # drive family — Temperature_Celsius (ATA), Temperature, or encoded in
  # raw values. We look for the common names and parse the raw value.
  defp smart_temp(attrs) do
    Enum.find_value(attrs, fn attr ->
      case attr["name"] do
        "Temperature_Celsius" -> parse_temp_raw(attr["raw"])
        "Temperature" -> parse_temp_raw(attr["raw"])
        _ -> nil
      end
    end)
  end

  defp parse_temp_raw(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _} when n > 0 and n < 200 -> n * 1.0
      _ -> nil
    end
  end

  defp parse_temp_raw(_), do: nil

  # Parse the SMART attributes that matter for failure detection (issue #69).
  # The attribute IDs are standard across ATA drives:
  #   5  = Reallocated_Sector_Ct
  #   12 = Power_Cycle_Count (not used for alerts, but informative)
  #   194 = Temperature_Celsius (handled above)
  #   197 = Current_Pending_Sector
  #   198 = Offline_Uncorrectable
  #   199 = UDMA_CRC_Error_Count
  #   9  = Power_On_Hours
  # We key by name for clarity, not ID, since names are stable in smartctl.
  defp parse_smart_attrs(attrs) do
    by_name = Map.new(attrs, fn a -> {a["name"], a} end)

    %{
      reallocated: raw_int(by_name["Reallocated_Sector_Ct"]),
      pending: raw_int(by_name["Current_Pending_Sector"]),
      uncorrectable: raw_int(by_name["Offline_Uncorrectable"]),
      crc_errors: raw_int(by_name["UDMA_CRC_Error_Count"]),
      command_timeout: raw_int(by_name["Command_Timeout"]),
      power_on_hours: raw_int(by_name["Power_On_Hours"])
    }
  end

  defp raw_int(%{"raw" => raw}) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp raw_int(_), do: nil
  # endpoint reports several (a multi-node address), take the first online
  # node — v1 scopes one API token per host.
  defp nodes({:ok, %Req.Response{status: 200, body: body}}, _opts) do
    with {:ok, %{"data" => nodes}} <- decode_body(body, "/api2/json/nodes") do
      # A node entry without a "node" key yields nil, which is not a name and
      # would otherwise be reported as an undeclared node called `nil`.
      all_names = nodes |> Enum.map(& &1["node"]) |> Enum.filter(&is_binary/1)

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
