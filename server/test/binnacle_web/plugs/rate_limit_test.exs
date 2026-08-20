defmodule BinnacleWeb.Plugs.RateLimitTest do
  # SPEC-0001 REQ rate-limiting, exercised against the plug directly so the
  # test is not coupled to the endpoint-wide burst budget.
  #
  # Several of these deliberately do not drive the plug inline: a bucket that
  # only survives inside one long-lived test process is exactly the defect the
  # supervised ETS owner exists to fix, and an inline test cannot see it.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias BinnacleWeb.Plugs.RateLimit
  alias BinnacleWeb.Plugs.RateLimit.Buckets

  @ip {10, 9, 9, 9}
  @proxy {10, 0, 0, 1}

  setup do
    # The table is owned by a supervised process now, so tests clear it rather
    # than deleting it out from under its owner.
    :ets.delete_all_objects(Buckets.table())

    Application.put_env(:binnacle, :api_rate_per_second, 10)
    Application.put_env(:binnacle, :api_rate_burst, 3)
    Application.put_env(:binnacle, :trusted_proxies, [])

    on_exit(fn -> Application.put_env(:binnacle, :trusted_proxies, []) end)

    :ok
  end

  describe "budget" do
    test "allows up to the burst then 429s" do
      results = for _ <- 1..5, do: run() |> status()

      assert Enum.take(results, 3) == [nil, nil, nil]
      assert Enum.drop(results, 3) == [429, 429]
    end

    test "different peers get different buckets" do
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

  describe "client address" do
    test "two forwarded clients behind one proxy get separate buckets" do
      trust(["10.0.0.1"])

      for _ <- 1..3, do: assert(forwarded("203.0.113.7") == nil)
      assert forwarded("203.0.113.7") == 429

      # A second client behind the same proxy is a second bucket, not the
      # tail of the first one's.
      assert forwarded("198.51.100.9") == nil
    end

    test "a forwarded header from an untrusted peer buys no extra buckets" do
      trust(["10.0.0.1"])

      # The peer is not the proxy, so the header is data, not identity: all
      # four requests bill to the peer and the fourth is refused.
      for i <- 1..3, do: assert(spoofed(i) == nil)
      assert spoofed(4) == 429
    end

    test "the client is the rightmost address the proxy saw" do
      trust(["10.0.0.1"])

      # A client that pre-seeds x-forwarded-for cannot pick its own bucket:
      # the proxy appends what it actually saw, so only the tail is ours.
      for _ <- 1..3, do: assert(forwarded("172.31.255.1, 203.0.113.7") == nil)
      assert forwarded("192.0.2.55, 203.0.113.7") == 429
    end

    test "a chain of trusted proxies resolves to the client behind them" do
      trust(["10.0.0.0/24"])

      for _ <- 1..3, do: assert(forwarded("203.0.113.7, 10.0.0.2") == nil)
      assert forwarded("203.0.113.7, 10.0.0.2") == 429
    end

    test "a header of nothing but trusted proxies falls back to the peer" do
      trust(["10.0.0.0/24"])

      for _ <- 1..3, do: assert(forwarded("10.0.0.2") == nil)
      assert forwarded("10.0.0.3") == 429
    end

    test "an unparseable forwarded entry is skipped, not keyed on" do
      trust(["10.0.0.1"])

      for _ <- 1..3, do: assert(forwarded("not-an-ip, 203.0.113.7") == nil)
      assert forwarded("203.0.113.7") == 429
    end

    test "an IPv4-mapped peer matches an IPv4 trusted proxy" do
      trust(["10.0.0.1"])

      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}

      for _ <- 1..3, do: assert(forwarded("203.0.113.7", mapped) == nil)
      assert forwarded("203.0.113.7", mapped) == 429
    end

    test "an IPv4 peer and its IPv4-mapped form share one bucket" do
      for _ <- 1..3, do: assert(run(@ip) |> status() == nil)
      assert run({0, 0, 0, 0, 0, 0xFFFF, 0x0A09, 0x0909}) |> status() == 429
    end
  end

  describe "trusted proxy configuration" do
    test "parses addresses and CIDRs" do
      trust(["10.0.0.1", "172.18.0.0/16", "::1", "fd00::/8"])

      assert RateLimit.trusted_proxies!() ==
               [
                 {{10, 0, 0, 1}, 32},
                 {{172, 18, 0, 0}, 16},
                 {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
                 {{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8}
               ]
    end

    test "rejects a malformed entry, naming it" do
      trust(["10.0.0.0/nope"])
      assert_raise ArgumentError, ~r/10\.0\.0\.0\/nope/, &RateLimit.trusted_proxies!/0

      trust(["not-a-network"])
      assert_raise ArgumentError, ~r/not-a-network/, &RateLimit.trusted_proxies!/0

      trust(["10.0.0.0/40"])
      assert_raise ArgumentError, ~r/exceeds 32 bits/, &RateLimit.trusted_proxies!/0

      trust([{10, 0, 0, 1}])
      assert_raise ArgumentError, ~r/expected an address or CIDR/, &RateLimit.trusted_proxies!/0
    end
  end

  describe "eviction" do
    test "drops idle buckets and keeps active ones" do
      run()

      stale = {10, 7, 0, 1}
      idle_for = :timer.minutes(30)

      :ets.insert(
        Buckets.table(),
        {stale, 3.0, System.monotonic_time(:millisecond) - idle_for}
      )

      assert Buckets.evict_idle() == 1
      assert :ets.lookup(Buckets.table(), stale) == []
      assert [{@ip, _tokens, _last}] = :ets.lookup(Buckets.table(), @ip)
    end
  end

  defp trust(proxies), do: Application.put_env(:binnacle, :trusted_proxies, proxies)

  defp run(ip \\ @ip) do
    conn(:get, "/api/sites")
    |> Map.put(:remote_ip, ip)
    |> RateLimit.call(nil)
  end

  defp forwarded(client, peer \\ @proxy) do
    conn(:get, "/api/sites")
    |> Map.put(:remote_ip, peer)
    |> put_req_header("x-forwarded-for", client)
    |> RateLimit.call(nil)
    |> status()
  end

  defp spoofed(i) do
    conn(:get, "/api/sites")
    |> Map.put(:remote_ip, {192, 168, 1, 50})
    |> put_req_header("x-forwarded-for", "203.0.113.#{i}")
    |> RateLimit.call(nil)
    |> status()
  end

  # Drive one request in its own short-lived process, the way the endpoint
  # does, so a bucket that only lives as long as its creator is visible.
  defp in_request(fun) do
    Task.async(fn -> fun.() |> status() end) |> Task.await(5_000)
  end

  defp status(conn), do: if(conn.halted, do: conn.status, else: nil)
end
