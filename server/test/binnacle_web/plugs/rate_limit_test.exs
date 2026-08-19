defmodule BinnacleWeb.Plugs.RateLimitTest do
  # SPEC-0001 REQ rate-limiting, exercised against the plug directly so the
  # test is not coupled to the endpoint-wide burst budget.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @table :binnacle_rate_limit
  @ip {10, 9, 9, 9}

  setup do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)

    on_exit(fn ->
      if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    end)

    Application.put_env(:binnacle, :api_rate_per_second, 10)
    Application.put_env(:binnacle, :api_rate_burst, 3)
    :ok
  end

  test "allows up to the burst then 429s" do
    results = for _ <- 1..5, do: run() |> status()

    assert Enum.take(results, 3) == [nil, nil, nil]
    assert Enum.drop(results, 3) == [429, 429]
  end

  test "different clients get different buckets" do
    for _ <- 1..3, do: run(@ip)
    assert run({10, 9, 9, 10}) |> status() == nil
  end

  defp run(ip \\ @ip) do
    conn(:get, "/api/sites")
    |> Map.put(:remote_ip, ip)
    |> BinnacleWeb.Plugs.RateLimit.call(nil)
  end

  defp status(conn), do: if(conn.halted, do: conn.status, else: nil)
end
