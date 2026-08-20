defmodule BinnacleWeb.Plugs.RateLimit do
  # Per-Client Token-Bucket Rate Limiting For The API
  #
  # The API fronts integrations (Proxmox, UniFi) with a shared inventory;
  # unbounded request amplification would multiply upstream load on every
  # poll. Each client address gets a bucket refilled at :rate requests/second
  # up to :burst; over-budget requests answer 429. /healthz does not pass
  # through this plug, so orchestrator probes are never throttled.
  #
  # "Client" is the peer address — unless the peer is a configured trusted
  # proxy, in which case it is the address that proxy reports in
  # `x-forwarded-for`. binnacle runs behind Caddy, so the peer is Caddy on
  # every request and keying on it makes the limit global rather than per
  # client. The header is only believed from a trusted peer, because a client
  # that can name its own bucket has an unlimited supply of them.
  #
  # The buckets themselves live in an ETS table owned by
  # `BinnacleWeb.Plugs.RateLimit.Buckets`, supervised from
  # `Binnacle.Application`.
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001 REQ rate-limit.
  #
  # @joestump-agent 08/20/2026 - Two fixes that between them made this close to
  # a no-op in production. The ETS table is now created and owned by a
  # supervised process instead of by whichever request arrived first — an ETS
  # table dies with its owner, so every bucket was discarded as the request
  # that wrote it finished. And the bucket key is now the forwarded client
  # address rather than `conn.remote_ip`, which behind Caddy is Caddy.

  @behaviour Plug
  import Plug.Conn

  alias BinnacleWeb.Plugs.RateLimit.Buckets

  @default_rate 10
  @default_burst 20

  def init(opts), do: opts

  def call(conn, _opts) do
    rate = Application.get_env(:binnacle, :api_rate_per_second, @default_rate)
    burst = Application.get_env(:binnacle, :api_rate_burst, @default_burst)

    if Buckets.take(client_key(conn), rate, burst) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(429, ~s({"error":"rate limited"}))
      |> halt()
    end
  end

  @doc """
  The address this request is billed to: the peer, unless the peer is a
  trusted proxy, in which case the rightmost `x-forwarded-for` entry that is
  not itself a trusted proxy.

  Rightmost, not leftmost: a proxy appends the peer it saw, so the tail of the
  header is what our own infrastructure observed and the head is whatever the
  client chose to send. Walking from the left would key the bucket on a value
  the client writes.
  """
  @spec client_key(Plug.Conn.t()) :: :inet.ip_address()
  def client_key(conn) do
    peer = normalize(conn.remote_ip)
    proxies = trusted_proxies!()

    if trusted?(peer, proxies) do
      conn
      |> forwarded_for()
      |> Enum.reverse()
      |> Enum.find(&(not trusted?(&1, proxies)))
      |> case do
        nil -> peer
        client -> client
      end
    else
      peer
    end
  end

  @doc """
  The configured trusted-proxy networks, parsed as `{address, prefix_length}`.

  Raises on a malformed entry, naming it. `Buckets` calls this at boot so a
  typo fails the release rather than every request.
  """
  @spec trusted_proxies!() :: [{:inet.ip_address(), non_neg_integer()}]
  def trusted_proxies! do
    :binnacle
    |> Application.get_env(:trusted_proxies, [])
    |> List.wrap()
    |> Enum.map(&parse_cidr!/1)
  end

  defp forwarded_for(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.flat_map(fn value ->
      case parse_address(value) do
        {:ok, ip} -> [ip]
        :error -> []
      end
    end)
  end

  defp trusted?(_ip, []), do: false
  defp trusted?(ip, proxies), do: Enum.any?(proxies, &in_network?(ip, &1))

  defp in_network?(ip, {network, length}) do
    ip_bits = to_bits(ip)
    network_bits = to_bits(network)

    bit_size(ip_bits) == bit_size(network_bits) and
      prefix(ip_bits, length) == prefix(network_bits, length)
  end

  defp prefix(bits, length) do
    <<taken::bitstring-size(^length), _rest::bitstring>> = bits
    taken
  end

  defp parse_cidr!(spec) when is_binary(spec) do
    {address, length} =
      case String.split(spec, "/", parts: 2) do
        [address] -> {address, nil}
        [address, length] -> {address, parse_length!(spec, length)}
      end

    case parse_address(address) do
      {:ok, ip} ->
        width = bit_size(to_bits(ip))

        if length && length > width do
          raise ArgumentError,
                "trusted_proxies: prefix length in #{inspect(spec)} exceeds #{width} bits"
        end

        {ip, length || width}

      :error ->
        raise ArgumentError, "trusted_proxies: #{inspect(spec)} is not an address or CIDR"
    end
  end

  defp parse_cidr!(spec) do
    raise ArgumentError,
          "trusted_proxies: expected an address or CIDR string, got #{inspect(spec)}"
  end

  defp parse_length!(spec, length) do
    case Integer.parse(length) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> raise ArgumentError, "trusted_proxies: #{inspect(spec)} has no valid prefix length"
    end
  end

  defp parse_address(value) do
    value =
      value
      |> String.trim()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> {:ok, normalize(ip)}
      {:error, _reason} -> :error
    end
  end

  # The prod endpoint binds `::`, so an IPv4 client arrives as an IPv4-mapped
  # IPv6 address. Fold it back so one client is one bucket key and a v4 CIDR
  # in :trusted_proxies still matches.
  defp normalize({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    <<a, b, c, d>> = <<ab::16, cd::16>>
    {a, b, c, d}
  end

  defp normalize(ip), do: ip

  defp to_bits({a, b, c, d}), do: <<a, b, c, d>>

  defp to_bits({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
end
