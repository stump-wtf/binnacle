defmodule BinnacleWeb.Plugs.SecurityHeaders do
  # Security headers for every response (SPEC-0001 REQ security-headers).
  #
  # nosniff, DENY framing, no referrer, and a CSP that allows inline
  # scripts only by per-request nonce — the theme bootstrap in
  # root.html.heex runs before first paint and cannot be externalised.
  # Fonts are self-hosted under /fonts, so 'self' is the whole budget
  # for both style-src and font-src. websocket connections (LiveView)
  # are allowed via ws/wss.
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001.
  # @joestump-agent 08/21/2026 - Nonce the inline theme script and
  #   self-host fonts so the CSP stops blocking the theme bootstrap
  #   and the design-system font stack (issue #61).

  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = generate_nonce()
    csp = build_csp(nonce)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", csp)
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
  end

  defp build_csp(nonce) do
    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}'",
      "style-src 'self'",
      "img-src 'self' data:",
      "font-src 'self'",
      "connect-src 'self' ws: wss:",
      "frame-ancestors 'none'",
      "base-uri 'none'"
    ]
    |> Enum.join("; ")
  end
end
