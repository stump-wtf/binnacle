defmodule BinnacleWeb.HealthController do
  # Public liveness probe — the one unauthenticated endpoint (SPEC-0001).
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001.

  use BinnacleWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
