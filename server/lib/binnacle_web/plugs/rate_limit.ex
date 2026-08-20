defmodule BinnacleWeb.Plugs.RateLimit do
  # Per-Client Token-Bucket Rate Limiting For The API
  #
  # The API fronts integrations (Proxmox, UniFi) with a shared inventory;
  # unbounded request amplification would multiply upstream load on every
  # poll. Each client IP gets a bucket refilled at :rate requests/second up
  # to :burst; over-budget requests answer 429. /healthz does not pass
  # through this plug, so orchestrator probes are never throttled.
  #
  # The buckets live in an ETS table owned by
  # `BinnacleWeb.Plugs.RateLimit.Buckets`, supervised from
  # `Binnacle.Application`.
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001 REQ rate-limit.
  #
  # @joestump-agent 08/20/2026 - Moved bucket storage into a supervised owner.
  # `ensure_table!/0` used to create the table from whichever request process
  # reached it first, and an ETS table is destroyed when its owner exits, so
  # every bucket was discarded as soon as the request that wrote it finished
  # and concurrent first requests raced in `:ets.new/2` — the loser raising
  # ArgumentError, which the endpoint renders as a 500.

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

  defp client_key(conn) do
    conn.remote_ip |> :erlang.phash2()
  end
end
