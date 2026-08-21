defmodule BinnacleWeb.Plugs.SecurityHeadersTest do
  # CSP conformance (SPEC-0001 REQ security-headers).
  #
  # The header and the markup have to agree or the policy is theatre: a nonce
  # in the CSP that does not match the one on the <script> blocks the theme
  # bootstrap exactly as a missing nonce did, and nothing else in the suite
  # would notice. These tests assert the agreement, the per-request freshness,
  # and that every font the stylesheet asks for is actually served from 'self'.
  #
  # @joestump 08/21/2026 - Added while reviewing #65: the PR asserted a nonce
  #   was present but never that it matched, that it changed, or that the
  #   self-hosted fonts resolve.

  use BinnacleWeb.ConnCase, async: true

  @fonts_css "assets/styles/fonts.css"

  defp csp(conn) do
    [value] = get_resp_header(conn, "content-security-policy")
    value
  end

  defp header_nonce(conn) do
    case Regex.run(~r/script-src [^;]*'nonce-([^']+)'/, csp(conn)) do
      [_, nonce] -> nonce
      nil -> nil
    end
  end

  describe "the inline theme script" do
    test "runs under a nonce the CSP header actually grants", %{conn: conn} do
      conn = get(conn, "/")
      html = html_response(conn, 200)

      assert [_, markup_nonce] = Regex.run(~r/<script nonce="([^"]+)"/, html)
      assert header_nonce(conn) == markup_nonce

      # The nonce must be on the theme bootstrap specifically — the script
      # that reads binnacle-theme before first paint — not some other tag.
      assert [_, nonced_body] =
               Regex.run(~r/<script nonce="#{Regex.escape(markup_nonce)}">(.*?)<\/script>/s, html)

      assert nonced_body =~ "binnacle-theme"
    end

    test "gets a fresh nonce on every request", %{conn: conn} do
      first = get(conn, "/") |> header_nonce()
      second = get(build_conn(), "/") |> header_nonce()

      assert first
      assert second
      refute first == second
    end
  end

  describe "the policy itself" do
    test "stays locked to 'self' on an HTML route", %{conn: conn} do
      policy = get(conn, "/") |> csp()

      assert policy =~ "default-src 'self'"
      assert policy =~ "style-src 'self'"
      assert policy =~ "font-src 'self'"
      assert policy =~ "frame-ancestors 'none'"
      assert policy =~ "base-uri 'none'"

      # Phoenix's put_secure_browser_headers/2 runs after this plug in the
      # :browser pipeline and ships its own laxer defaults. It must not win.
      refute policy =~ "frame-ancestors 'self'"
      refute policy =~ "base-uri 'self'"
      refute policy =~ "'unsafe-inline'"
      refute policy =~ "http"
    end

    test "does not allow inline scripts wholesale", %{conn: conn} do
      policy = get(conn, "/") |> csp()

      assert [_, script_src] = Regex.run(~r/script-src ([^;]+)/, policy)
      refute script_src =~ "'unsafe-inline'"
      refute script_src =~ "'unsafe-eval'"
    end

    test "keeps no-referrer on an HTML route too", %{conn: conn} do
      conn = get(conn, "/")

      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end

  describe "self-hosted fonts" do
    test "every face fonts.css declares is served from this origin" do
      css = File.read!(@fonts_css)

      urls =
        Regex.scan(~r/url\('([^']+)'\)/, css)
        |> Enum.map(fn [_, url] -> url end)

      assert length(urls) > 0, "fonts.css declares no @font-face sources"

      for url <- urls do
        assert String.starts_with?(url, "/fonts/"),
               "#{url} is not served from this origin — font-src 'self' would block it"

        conn = get(build_conn(), url)

        assert conn.status == 200,
               "#{url} answered #{conn.status}; the file is missing or `fonts` " <>
                 "dropped out of BinnacleWeb.static_paths/0"
      end
    end

    test "the layout pulls no font from a remote origin", %{conn: conn} do
      html = get(conn, "/") |> html_response(200)

      refute html =~ "fonts.googleapis.com"
      refute html =~ "fonts.gstatic.com"
      refute html =~ ~s(style=")
    end
  end
end
