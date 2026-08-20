defmodule Binnacle.Fleet.Unifi.Client do
  # UniFi Controller API client for site discovery.
  #
  # One call, `fetch_sites/2`, returns every site the API key has access to.
  # The UDM-Pro / new-style API uses X-API-Key header auth against
  # /api/self/sites. Older controllers use cookie-based auth; this client
  # targets the modern path only.
  #
  # This client never names a site. Every controller in this fleet reports a
  # single site called "default" (each property runs its own), so the API can
  # confirm that a gateway answers and list what is behind it, but it cannot
  # say which property it is standing in. Site identity is config's
  # (SPEC-0001 REQ "Discovery Does Not Invent Topology"); `fetch_sites/3`
  # exists to detect drift, not to name anything.
  #
  # @joestump-agent 08/20/2026 - Added fetch_devices/3 for REQ "UniFi Site
  # Discovery": gateway presence plus the network-device inventory.

  alias Binnacle.Fleet.Model.NetworkDevice
  alias Binnacle.Fleet.Model.Site

  @timeout 5_000

  @doc """
  Fetch sites from a UniFi controller.

  `credential` is either `%{api_key: key}` (UDM-Pro local API key, sent as
  X-API-Key against /api/self/sites) or `%{username: u, password: p}` (cookie
  login at /api/auth/login, then the /proxy/network/api/self/sites path —
  the flow every controller supports, including firmware without API keys).

  Returns `{:ok, [Site.t()]}` or `{:error, reason}`. Sites are returned with
  `kind: :home` by default; the caller should re-map kinds from config.
  """
  @spec fetch_sites(String.t(), map(), keyword()) :: {:ok, [Site.t()]} | {:error, String.t()}
  def fetch_sites(base_url, credential, opts \\ []) do
    base_url = String.trim_trailing(base_url, "/")

    case credential do
      %{api_key: api_key} ->
        fetch_with_api_key(base_url, api_key, opts)

      %{username: username, password: password} ->
        fetch_with_login(base_url, username, password, opts)

      _ ->
        {:error, "UniFi credential must carry :api_key or :username + :password"}
    end
  end

  @doc """
  Fetch the network-device inventory for a controller's site.

  Returns `{:ok, %{gateway: NetworkDevice.t() | nil, devices: [NetworkDevice.t()]}}`.
  The gateway is the device UniFi types as a gateway (`ugw`/`udm`/`uxg`/`udr`);
  it is `nil` when the controller lists none, which is a real answer — a site
  whose gateway has gone missing is not the same as one that never had one.

  `site` is the controller's OWN site name, which is "default" on every
  controller in this fleet. It is not binnacle's site slug and must never be
  used as one.
  """
  @spec fetch_devices(String.t(), map(), keyword()) ::
          {:ok, %{gateway: NetworkDevice.t() | nil, devices: [NetworkDevice.t()]}}
          | {:error, String.t()}
  def fetch_devices(base_url, credential, opts \\ []) do
    base_url = String.trim_trailing(base_url, "/")
    site = Keyword.get(opts, :site, "default")

    case credential do
      %{api_key: api_key} ->
        base_url
        |> request("/proxy/network/api/s/#{site}/stat/device", [{"X-API-Key", api_key}], opts)
        |> decode_devices()

      %{username: username, password: password} ->
        with {:ok, cookies} <- login(base_url, username, password, opts) do
          base_url
          |> request(
            "/proxy/network/api/s/#{site}/stat/device",
            [{"cookie", Enum.join(cookies, "; ")}],
            opts
          )
          |> decode_devices()
        end

      _ ->
        {:error, "UniFi credential must carry :api_key or :username + :password"}
    end
  end

  defp decode_devices({:ok, %Req.Response{status: 200, body: body}}) do
    with {:ok, %{"data" => entries}} when is_list(entries) <- decode_json(body) do
      devices = Enum.map(entries, &to_device/1)
      {:ok, %{gateway: Enum.find(devices, &(&1.kind == :gateway)), devices: devices}}
    else
      {:ok, _} -> {:error, "UniFi device list returned no data array"}
      {:error, _} = err -> err
    end
  end

  defp decode_devices({:ok, %Req.Response{status: status}}),
    do: {:error, "UniFi device list answered HTTP #{status}"}

  defp decode_devices({:error, err}),
    do: {:error, "UniFi device list unreachable: #{format(err)}"}

  # UniFi's `type` is the device family. The gateway families are the ones
  # that route: UDM/UDR/UXG/USG. Anything unrecognized is :other rather than
  # dropped — an inventory that silently omits a device is worse than one
  # that cannot classify it.
  defp to_device(entry) do
    %NetworkDevice{
      mac: entry["mac"],
      name: entry["name"] || entry["model"] || entry["mac"],
      model: entry["model"],
      kind: device_kind(entry["type"]),
      status: device_status(entry["state"]),
      adopted: entry["adopted"],
      version: entry["version"],
      uptime: entry["uptime"]
    }
  end

  defp device_kind(type) when type in ~w(ugw udm uxg udr), do: :gateway
  defp device_kind("usw"), do: :switch
  defp device_kind("uap"), do: :access_point
  defp device_kind(_), do: :other

  # UniFi state: 1 is connected, 0 is disconnected, and the rest are
  # transitional (pending adoption, upgrading, provisioning). Transitional is
  # not an outage.
  defp device_status(1), do: :up
  defp device_status(0), do: :down
  defp device_status(nil), do: :unknown
  defp device_status(_), do: :degraded

  # The cookie half of fetch_with_login, hoisted so fetch_devices can reuse it.
  defp login(base_url, username, password, opts) do
    case request(base_url, "/api/auth/login", [{"content-type", "application/json"}], opts,
           method: :post,
           json: %{username: username, password: password}
         ) do
      {:ok, %Req.Response{status: 200, headers: headers}} ->
        {:ok, session_cookies(headers)}

      {:ok, %Req.Response{status: status}} ->
        {:error, "UniFi login answered HTTP #{status}"}

      {:error, err} ->
        {:error, "UniFi login unreachable: #{format(err)}"}
    end
  end

  defp session_cookies(headers) do
    headers
    |> Enum.filter(fn {name, _} -> name == "set-cookie" end)
    |> Enum.flat_map(fn {_name, values} -> List.wrap(values) end)
    |> Enum.map(fn cookie -> cookie |> String.split(";") |> hd() end)
    |> Enum.uniq()
  end

  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, err} -> {:error, "UniFi returned undecodable JSON: #{Exception.message(err)}"}
    end
  end

  defp decode_json(_), do: {:error, "UniFi returned no JSON"}

  defp fetch_with_api_key(base_url, api_key, opts) do
    case request(base_url, "/api/self/sites", [{"X-API-Key", api_key}], opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        decode_sites(body)

      {:ok, %Req.Response{status: status}} ->
        {:error, "UniFi /api/self/sites answered HTTP #{status}"}

      {:error, err} ->
        {:error, "UniFi /api/self/sites unreachable: #{format(err)}"}
    end
  end

  # Cookie flow: the same JWT the web UI uses, against the /proxy/network
  # path every controller exposes. The credential is only ever attached to
  # the request — it never enters state, a log line, or a crash report.
  defp fetch_with_login(base_url, username, password, opts) do
    with {:ok, cookies} <- login(base_url, username, password, opts) do
      case request(
             base_url,
             "/proxy/network/api/self/sites",
             [{"cookie", Enum.join(cookies, "; ")}],
             opts
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          decode_sites(body)

        {:ok, %Req.Response{status: status}} ->
          {:error, "UniFi self/sites answered HTTP #{status}"}

        {:error, err} ->
          {:error, "UniFi self/sites unreachable: #{format(err)}"}
      end
    end
  end

  defp decode_sites(body) when is_map(body) do
    case body do
      %{"data" => sites} when is_list(sites) ->
        {:ok, Enum.map(sites, &to_site/1)}

      _ ->
        {:error, "UniFi response missing data array"}
    end
  end

  defp decode_sites(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_sites(decoded)
      {:error, err} -> {:error, "UniFi returned undecodable JSON: #{Exception.message(err)}"}
    end
  end

  defp decode_sites(_), do: {:error, "UniFi returned no JSON"}

  defp to_site(%{"name" => name} = entry) do
    desc = entry["desc"] || name

    %Site{
      slug: name,
      kind: :home,
      hosts: []
    }
    |> Map.put(:description, desc)
  end

  defp request(base_url, path, headers, opts, extra \\ []) do
    options =
      [
        base_url: base_url,
        url: path,
        headers: headers,
        receive_timeout: Keyword.get(opts, :timeout, @timeout),
        retry: false,
        decode_body: false,
        # Controllers on the LAN present self-signed certificates (the
        # homepage widget allows them for the same reason); discovery is
        # site *names*, not sensitive payloads.
        connect_options: [transport_opts: [verify: Keyword.get(opts, :verify, :verify_none)]]
      ] ++
        extra ++ Keyword.take(opts, [:plug])

    try do
      options
      |> Req.new()
      |> Req.request()
    rescue
      e in Req.TransportError -> {:error, e}
    end
  end

  defp format(%{__exception__: true} = err), do: Exception.message(err)
  defp format(other), do: inspect(other)
end
