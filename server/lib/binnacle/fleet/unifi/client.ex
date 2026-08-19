defmodule Binnacle.Fleet.Unifi.Client do
  # UniFi Controller API client for site discovery.
  #
  # One call, `fetch_sites/2`, returns every site the API key has access to.
  # The UDM-Pro / new-style API uses X-API-Key header auth against
  # /api/self/sites. Older controllers use cookie-based auth; this client
  # targets the modern path only.
  #
  # Site kind (home/airbnb) is business metadata the API does not carry.
  # The caller maps slug → kind from config; unmatched sites default to
  # "home".

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
    login =
      request(base_url, "/api/auth/login", [{"content-type", "application/json"}], opts,
        method: :post,
        json: %{username: username, password: password}
      )

    case login do
      {:ok, %Req.Response{status: 200, headers: headers}} ->
        cookies =
          headers
          |> Enum.filter(fn {name, _} -> name == "set-cookie" end)
          |> Enum.flat_map(fn {_name, values} -> List.wrap(values) end)
          |> Enum.map(fn cookie -> cookie |> String.split(";") |> hd() end)
          |> Enum.uniq()

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

      {:ok, %Req.Response{status: status}} ->
        {:error, "UniFi login answered HTTP #{status}"}

      {:error, err} ->
        {:error, "UniFi login unreachable: #{format(err)}"}
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
