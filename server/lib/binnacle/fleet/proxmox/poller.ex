defmodule Binnacle.Fleet.Proxmox.Poller do
  # One poller per Proxmox host (SPEC-0001 REQ proxmox, design: polling
  # architecture). Pollers only emit messages — `{:proxmox, host_key,
  # result}` cast to Binnacle.Fleet — and never touch shared state; the
  # Fleet GenServer is the single serialization point. Cadence is
  # config-driven with a 30s default. On shutdown the timer stops and any
  # in-flight poll result is discarded by the Fleet (stale host key).
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001.

  use GenServer

  alias Binnacle.Fleet.Proxmox.Client

  @default_interval :timer.seconds(30)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: keyword_name(opts))
  end

  defp keyword_name(opts), do: Keyword.get(opts, :name)

  @impl true
  def init(opts) do
    host_key = Keyword.fetch!(opts, :host_key)
    base_url = Keyword.fetch!(opts, :base_url)
    token = Keyword.fetch!(opts, :token)
    interval = Keyword.get(opts, :interval_ms, @default_interval)
    fetch = Keyword.get(opts, :fetch, &Client.fetch/3)
    fetch_opts = Keyword.get(opts, :fetch_opts, [])
    sink = Keyword.get(opts, :sink, Binnacle.Fleet)

    state = %{
      host_key: host_key,
      base_url: base_url,
      token: token,
      interval_ms: interval,
      fetch: fetch,
      fetch_opts: fetch_opts,
      sink: sink
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    result = state.fetch.(state.base_url, state.token, state.fetch_opts)

    # Errors are delivered too: the Fleet counts consecutive misses so it can
    # degrade the host after three (SPEC-0001: never silently dropped).
    send(state.sink, {:proxmox, state.host_key, result})
    {:noreply, state, {:continue, :reschedule}}
  end

  @impl true
  def handle_continue(:reschedule, state) do
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end
end
