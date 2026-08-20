defmodule BinnacleWeb.Plugs.RateLimitTest do
  # SPEC-0001 REQ rate-limiting, exercised against the plug directly so the
  # test is not coupled to the endpoint-wide burst budget.
  #
  # The ownership cases deliberately do not drive the plug inline: a bucket
  # that only survives inside one long-lived test process is exactly the
  # defect the supervised ETS owner exists to fix, and an inline test cannot
  # see it.
  use ExUnit.Case, async: false

  import Plug.Test

  alias BinnacleWeb.Plugs.RateLimit
  alias BinnacleWeb.Plugs.RateLimit.Buckets

  @ip {10, 9, 9, 9}

  setup do
    # The table is owned by a supervised process now, so tests clear it rather
    # than deleting it out from under its owner.
    :ets.delete_all_objects(Buckets.table())

    Application.put_env(:binnacle, :api_rate_per_second, 10)
    Application.put_env(:binnacle, :api_rate_burst, 3)

    :ok
  end

  describe "budget" do
    test "allows up to the burst then 429s" do
      results = for _ <- 1..5, do: run() |> status()

      assert Enum.take(results, 3) == [nil, nil, nil]
      assert Enum.drop(results, 3) == [429, 429]
    end

    test "different clients get different buckets" do
      for _ <- 1..3, do: run(@ip)
      assert run({10, 9, 9, 10}) |> status() == nil
    end
  end

  describe "bucket ownership" do
    # The regression: `ensure_table!/0` used to run in whichever request
    # process arrived first, and an ETS table is destroyed when its owner
    # exits. Each of these requests is its own short-lived process, so the
    # table (and the bucket in it) has to outlive all of them for the fourth
    # to be refused.
    test "buckets survive the request process that created them" do
      for _ <- 1..3, do: assert(in_request(fn -> run() end) == nil)

      assert in_request(fn -> run() end) == 429
      assert :ets.whereis(Buckets.table()) != :undefined
    end

    test "concurrent cold start does not fail a request" do
      # Take the table's owner down and let the supervisor restart it while
      # requests arrive at once. Previously every one of them saw an absent
      # table, raced into `:ets.new/2`, and the losers raised ArgumentError,
      # which the endpoint renders as a 500.
      owner = Process.whereis(Buckets)
      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 1_000

      results =
        1..50
        |> Enum.map(fn i -> Task.async(fn -> run({10, 8, 0, i}) |> status() end) end)
        |> Task.await_many(5_000)

      assert length(results) == 50
      assert Enum.all?(results, &(&1 in [nil, 429])), "a request failed during cold start"

      # And the restarted owner is serving buckets again.
      assert Process.whereis(Buckets) != nil
      assert Process.whereis(Buckets) != owner
      assert :ets.whereis(Buckets.table()) != :undefined
    end
  end

  describe "eviction" do
    test "drops idle buckets and keeps active ones" do
      run()

      stale = :erlang.phash2({10, 7, 0, 1})
      idle_for = :timer.minutes(30)

      :ets.insert(
        Buckets.table(),
        {stale, 3.0, System.monotonic_time(:millisecond) - idle_for}
      )

      assert Buckets.evict_idle() == 1
      assert :ets.lookup(Buckets.table(), stale) == []
      assert [{_client, _tokens, _last}] = :ets.lookup(Buckets.table(), :erlang.phash2(@ip))
    end
  end

  defp run(ip \\ @ip) do
    conn(:get, "/api/sites")
    |> Map.put(:remote_ip, ip)
    |> RateLimit.call(nil)
  end

  # Drive one request in its own short-lived process, the way the endpoint
  # does, so a bucket that only lives as long as its creator is visible.
  defp in_request(fun) do
    Task.async(fn -> fun.() |> status() end) |> Task.await(5_000)
  end

  defp status(conn), do: if(conn.halted, do: conn.status, else: nil)
end
