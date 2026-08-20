defmodule BinnacleWeb.Plugs.RateLimit.Buckets do
  # Token Bucket Storage For The API Rate Limiter
  #
  # Owns `:binnacle_rate_limit`, the ETS table `BinnacleWeb.Plugs.RateLimit`
  # keeps its per-client token buckets in. An ETS table belongs to the process
  # that created it and is destroyed when that process exits, so the owner is
  # this supervised GenServer rather than whichever request happened to arrive
  # first.
  #
  # The table stays `:public`: request processes read and write their own
  # bucket directly, so this process is never in the request path and is free
  # to sweep. Two requests for one client can interleave their
  # read-modify-write and let an extra token through; for a limiter sized to
  # keep the API from amplifying load onto Proxmox and UniFi, that is cheaper
  # than serialising every request through one mailbox.
  #
  # Buckets idle longer than `@idle_ms` are evicted. A bucket that has been
  # idle for longer than it takes to refill is indistinguishable from a fresh
  # one, so eviction costs its client nothing and keeps the table from growing
  # one row per address ever seen.
  #
  # @joestump-agent 08/20/2026 - Extracted from BinnacleWeb.Plugs.RateLimit,
  # where `ensure_table!/0` created the table from the first request process to
  # reach it. That table died with the request, so every bucket was discarded
  # as soon as it was written, and concurrent cold starts raced in `:ets.new/2`
  # with the loser raising ArgumentError.

  @moduledoc false

  use GenServer

  @table :binnacle_rate_limit
  @sweep_ms :timer.minutes(1)
  @idle_ms :timer.minutes(10)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The bucket table's name, for tests and diagnostics."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Take a token from `client`'s bucket, refilling it from the elapsed time
  since that client's last request first. Returns true when the request is
  within budget, false when the bucket is empty.

  Answers true when the table is missing, which means this process is between
  a crash and its restart: a window of unthrottled requests is a better
  failure than 500ing every caller over a supervisor blip.
  """
  @spec take(term(), number(), number()) :: boolean()
  def take(client, rate, burst) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, client) do
      [{^client, tokens, last}] ->
        refilled = min(burst, tokens + (now - last) * rate / 1000)

        if refilled >= 1 do
          :ets.insert(@table, {client, refilled - 1, now})
          true
        else
          :ets.insert(@table, {client, refilled, now})
          false
        end

      [] ->
        :ets.insert(@table, {client, burst - 1, now})
        true
    end
  rescue
    ArgumentError -> true
  end

  @doc """
  Drop every bucket untouched for `idle_ms`, returning how many were dropped.
  Called on the sweep timer; takes the window as an argument so a test can
  drive it without waiting one out.
  """
  @spec evict_idle(non_neg_integer()) :: non_neg_integer()
  def evict_idle(idle_ms \\ @idle_ms) do
    cutoff = System.monotonic_time(:millisecond) - idle_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    evict_idle()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end
end
