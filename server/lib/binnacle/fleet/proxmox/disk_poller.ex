defmodule Binnacle.Fleet.Proxmox.DiskPoller do
  # One disk-health poller per Proxmox host (issue #69). Follows the same
  # pattern as the main Poller: emits messages, never touches shared state.
  # Runs at a slower cadence (60s default) because SMART queries are
  # per-disk and take longer than the status/guest poll.
  #
  # @joestump-agent 08/21/2026 - Initial version for issue #69.

  use GenServer

  alias Binnacle.Fleet.Proxmox.Client
  alias Binnacle.Fleet.Proxmox.Token

  @default_interval :timer.seconds(60)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: keyword_name(opts))
  end

  defp keyword_name(opts), do: Keyword.get(opts, :name)

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)

    host_key = Keyword.fetch!(opts, :host_key)
    base_url = Keyword.fetch!(opts, :base_url)
    token = Token.new(Keyword.fetch!(opts, :token))
    interval = Keyword.get(opts, :interval_ms, @default_interval)
    fetch_disks = Keyword.get(opts, :fetch_disks, &Client.fetch_disks/3)
    fetch_pools = Keyword.get(opts, :fetch_pools, &Client.fetch_pools/3)
    fetch_opts = Keyword.get(opts, :fetch_opts, [])
    sink = Keyword.get(opts, :sink, Binnacle.Fleet)

    state = %{
      host_key: host_key,
      base_url: base_url,
      token: token,
      interval_ms: interval,
      fetch_disks: fetch_disks,
      fetch_pools: fetch_pools,
      fetch_opts: fetch_opts,
      sink: sink
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    token = Token.reveal(state.token)

    disks = state.fetch_disks.(state.base_url, token, state.fetch_opts)
    pools = state.fetch_pools.(state.base_url, token, state.fetch_opts)

    send(state.sink, {:disk_health, state.host_key, %{disks: disks, pools: pools}})
    {:noreply, state, {:continue, :reschedule}}
  end

  @impl true
  def handle_continue(:reschedule, state) do
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end
end
