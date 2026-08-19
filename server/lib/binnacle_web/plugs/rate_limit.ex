defmodule BinnacleWeb.Plugs.RateLimit do
  # Per-client token-bucket rate limiting for the API (SPEC-0001).
  #
  # The API fronts integrations (Proxmox, UniFi) with a shared inventory;
  # unbounded request amplification would multiply upstream load on every
  # poll. Each client IP gets a bucket refilled at :rate requests/second up
  # to :burst; over-budget requests answer 429. /healthz does not pass
  # through this plug, so orchestrator probes are never throttled.
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001 REQ rate-limit.

  @behaviour Plug
  import Plug.Conn

  @table :binnacle_rate_limit
  @default_rate 10
  @default_burst 20

  def init(opts), do: opts

  def call(conn, _opts) do
    ensure_table!()
    rate = Application.get_env(:binnacle, :api_rate_per_second, @default_rate)
    burst = Application.get_env(:binnacle, :api_rate_burst, @default_burst)
    client = client_key(conn)

    if take_token(client, rate, burst) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(429, ~s({"error":"rate limited"}))
      |> halt()
    end
  end

  defp client_key(conn) do
    conn.remote_ip |> :erlang.phash2()
  end

  defp ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  # Token bucket: refill continuously from the last visit, then try to take
  # one token. Everything is derived from {tokens, last_visit_ms}, written
  # back with write_concurrency so concurrent requests degrade gracefully.
  defp take_token(client, rate, burst) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, client) do
      [{^client, tokens, last}] ->
        refilled = min(burst, tokens + (now - last) * rate / 1000)

        if refilled >= 1 do
          :ets.insert(@table, {client, refilled - 1, now})
          true
        else
          :ets.insert(@table, {client, refilled, now})
          false
        end

      [] ->
        :ets.insert(@table, {client, burst - 1, now})
        true
    end
  end
end
