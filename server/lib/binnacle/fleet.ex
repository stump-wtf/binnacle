defmodule Binnacle.Fleet do
  @moduledoc """
  The fleet context: one GenServer owning the containment spine, the metrics
  history, and the sample clock.

  Governing: ADR-0002 / SPEC-0001. The baseline comes from a JSON config file;
  until live discovery lands, `Binnacle.Fleet.Sampler` produces the readings.
  Every LiveView reads the model through `snapshot/0` — never the GenServer's
  raw state — and the snapshot contains no credentials, ever.

  History is a capped list per host, oldest first: `@history_len` samples is
  the window the trend lines draw (at `@sample_ms` cadence, ~10 minutes).
  """

  use GenServer

  alias Binnacle.Fleet.Config
  alias Binnacle.Fleet.Model
  alias Binnacle.Fleet.Sampler

  @sample_ms 5_000
  @history_len 120
  @default_baseline "priv/fleet/baseline.json"

  # Enrichment profile per host key: :hot (degraded-ish), :silent (unknown),
  # or :plain. Stand-in for discovery, keyed like the real fleet.
  @profiles %{
    "ogma" => :hot,
    "hud01" => :silent,
    "buoy" => :down
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The render-ready fleet: sites with their hosts, guests, containers,
  hardware inventories, current sample, trend series, and rolled-up statuses.
  """
  @spec snapshot() :: [map()]
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc "Subscribe the calling process to `:fleet_tick` pushes on every sample."
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(Binnacle.PubSub, "fleet")
  end

  # ---- GenServer -----------------------------------------------------------

  @impl true
  def init(opts) do
    baseline = Keyword.get(opts, :baseline, @default_baseline)

    %Config{sites: sites, hosts: hosts, guests: guests, containers: containers, hardware: hw} =
      Config.load!(baseline)

    tick = 0

    state = %{
      tick: tick,
      sites: sites,
      hosts: hosts,
      guests: guests,
      containers: containers,
      hardware: hw,
      history: %{}
    }

    state = sample(state)
    :timer.send_interval(@sample_ms, :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = sample(%{state | tick: state.tick + 1})
    Phoenix.PubSub.broadcast(Binnacle.PubSub, "fleet", :fleet_tick)
    {:noreply, state}
  end

  # ---- sampling ------------------------------------------------------------

  defp sample(%{hosts: hosts, tick: tick} = state) do
    history =
      Map.new(hosts, fn host ->
        prev = List.last(state.history[host.key] || [])
        next = sample_host(host.key, tick, prev)
        {host.key, push_history(state.history[host.key], next)}
      end)

    %{state | history: history}
  end

  defp sample_host(key, tick, prev) do
    case Map.get(@profiles, key, :plain) do
      :hot -> Sampler.sample_hot_host(key, tick, prev, seed: :erlang.phash2(key))
      :silent -> Sampler.sample_silent_host()
      :down -> Sampler.sample_silent_host()
      :plain -> Sampler.sample_host(key, tick, prev, seed: :erlang.phash2(key))
    end
  end

  defp push_history(nil, sample), do: push_history([], sample)

  defp push_history(history, sample) do
    history
    |> Kernel.++([sample])
    |> Enum.take(-@history_len)
  end

  # ---- snapshot ------------------------------------------------------------

  defp build_snapshot(state) do
    containers_by_guest = Enum.group_by(state.containers, & &1.guest)

    guests_by_host =
      Map.new(state.hosts, fn host ->
        guests =
          Enum.filter(state.guests, &(&1.host == host.key))
          |> Enum.map(fn guest ->
            guest_containers =
              Map.get(containers_by_guest, guest.vmid, [])
              |> Enum.map(fn c -> %{c | status: :up} end)

            %{
              guest
              | containers: guest_containers,
                hardware: Map.get(state.hardware, guest.vmid, []),
                status: Model.roll_up(Enum.map(guest_containers, & &1.status))
            }
          end)

        {host.key, guests}
      end)

    Enum.map(state.sites, fn site ->
      hosts =
        Enum.filter(state.hosts, &(&1.site == site.slug))
        |> Enum.map(fn host ->
          history = state.history[host.key] || []
          current = List.last(history)
          guests = Map.get(guests_by_host, host.key, [])

          host_status =
            if current do
              Model.roll_up([
                host_profile_status(host.key),
                Model.sample_status(current),
                Model.roll_up(Enum.map(guests, & &1.status))
              ])
            else
              # No signal from the host itself. Its children may still be
              # reporting, but "no reading and no complaints" is :unknown,
              # not :up — unless the profile says it is actually down.
              case Model.roll_up([host_profile_status(host.key) | Enum.map(guests, & &1.status)]) do
                :up -> :unknown
                other -> other
              end
            end

          %{
            host
            | guests: guests,
              hardware: Map.get(state.hardware, host.key, []),
              status: host_status,
              history: nil
          }
          |> Map.merge(%{
            sample: current,
            series: series(history),
            stale: current == nil
          })
        end)

      %{site | hosts: hosts}
      |> Map.merge(%{status: Model.roll_up(Enum.map(hosts, & &1.status))})
    end)
  end

  defp host_profile_status("buoy"), do: :down
  defp host_profile_status("hud01"), do: :unknown
  defp host_profile_status(_), do: :up

  # Per-metric series for the trend lines, oldest first.
  defp series(history) do
    keys = [:cpu, :memory, :disk, :cpu_temp, :hdd_temp]

    Map.new(keys, fn key ->
      {key, Enum.map(history, &if(&1, do: Map.get(&1, key), else: nil))}
    end)
  end
end
