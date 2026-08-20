defmodule Binnacle.Fleet.Unifi.Poller do
  # One poller per site with a UniFi gateway (SPEC-0001 REQ "UniFi Site
  # Discovery"). Mirrors Binnacle.Fleet.Proxmox.Poller: it only emits
  # `{:unifi, site_slug, result}` to the Fleet, never touches shared state,
  # and the Fleet is the single serialization point.
  #
  # Cadence defaults to 60s — slower than the Proxmox pollers, because a
  # network-device inventory changes on the timescale of somebody plugging in
  # a switch, not on the timescale of CPU load.
  #
  # @joestump-agent 08/20/2026 - Initial version for REQ "UniFi Site Discovery".

  use GenServer

  alias Binnacle.Fleet.Unifi.Client

  @default_interval :timer.seconds(60)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    # The credential lives in this process's state for its whole life, so the
    # same defence the Proxmox poller documents applies: :sensitive disables
    # tracing and message-queue inspection. Unlike a PVE token there is no
    # single opaque value to wrap — a username/password pair is two fields —
    # so the state map is built with the credential under a key that is never
    # logged, and nothing in this module ever puts it in a message.
    Process.flag(:sensitive, true)

    state = %{
      site: Keyword.fetch!(opts, :site),
      base_url: Keyword.fetch!(opts, :base_url),
      credential: Keyword.fetch!(opts, :credential),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval),
      fetch: Keyword.get(opts, :fetch, &Client.fetch_devices/3),
      fetch_opts: Keyword.get(opts, :fetch_opts, []),
      sink: Keyword.get(opts, :sink, Binnacle.Fleet)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    result = state.fetch.(state.base_url, state.credential, state.fetch_opts)

    # Errors are delivered too: a site whose controller stops answering must
    # say so, rather than keeping a stale inventory that looks current.
    send(state.sink, {:unifi, state.site, result})
    {:noreply, state, {:continue, :reschedule}}
  end

  @impl true
  def handle_continue(:reschedule, state) do
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end
end
