defmodule BinnacleWeb.FallbackController do
  # Uniform 404/418-shaped errors for the API (SPEC-0001 REQ error-handling).
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001.

  use BinnacleWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end

  def call(conn, {:error, :method_not_allowed}) do
    conn
    |> put_status(:method_not_allowed)
    |> json(%{error: "method not allowed"})
  end
end
