defmodule BinnacleWeb.Plugs.ApiAuth do
  # Bearer-token authentication for the read-only API (SPEC-0001).
  #
  # A single-operator token loaded from the BINNACLE_API_TOKEN environment
  # variable at runtime — never from the baseline config file, never logged.
  # Comparison is constant-time and a missing token is indistinguishable from
  # an invalid one: both answer 401 with the same body.
  #
  # When no token is configured the API fails closed: every authenticated
  # endpoint answers 401. Only /healthz stays public.
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001 REQ api-auth.

  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    token = Application.get_env(:binnacle, :api_token)

    with [authorization] <- get_req_header(conn, "authorization"),
         <<"Bearer ", presented::binary>> <- authorization,
         false <- is_nil(token),
         true <- Plug.Crypto.secure_compare(presented, token) do
      conn
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"unauthorized"}))
        |> halt()
    end
  end
end
