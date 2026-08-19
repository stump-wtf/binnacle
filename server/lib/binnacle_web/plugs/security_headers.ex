defmodule BinnacleWeb.Plugs.SecurityHeaders do
  # Security headers for every response (SPEC-0001 REQ security-headers).
  #
  # nosniff, DENY framing, no referrer, and a CSP that disallows inline
  # scripts — the SPA ships compiled assets from /assets, so 'self' is the
  # whole budget. websocket connections (LiveView) are allowed via ws/wss.
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001.

  @behaviour Plug
  import Plug.Conn

  @csp "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'none'; base-uri 'none'"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", @csp)
  end
end
