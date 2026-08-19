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

  Returns `{:ok, [Site.t()]}` or `{:error, reason}`. Sites are returned with
  `kind: :home` by default; the caller should re-map kinds from config.
  """
  @spec fetch_sites(String.t(), String.t(), keyword()) ::
          {:ok, [Site.t()]} | {:error, String.t()}
  def fetch_sites(base_url, api_key, opts \\ []) do
    base_url = String.trim_trailing(base_url, "/")

    case request(base_url, api_key, "/api/self/sites", opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        decode_sites(body)

      {:ok, %Req.Response{status: status}} ->
        {:error, "UniFi /api/self/sites answered HTTP #{status}"}

      {:error, err} ->
        {:error, "UniFi /api/self/sites unreachable: #{format(err)}"}
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

  defp request(base_url, api_key, path, opts) do
    options =
      [
        base_url: base_url,
        url: path,
        headers: [{"X-API-Key", api_key}],
        receive_timeout: Keyword.get(opts, :timeout, @timeout),
        retry: false,
        decode_body: false
      ] ++ Keyword.take(opts, [:plug])

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
