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

  require Logger

  use GenServer

  alias Binnacle.Fleet.Config
  alias Binnacle.Fleet.Model
  alias Binnacle.Fleet.Proxmox.Poller
  alias Binnacle.Fleet.Sampler

  @sample_ms 5_000
  @history_len 120
  @default_baseline_path "fleet/baseline.json"
  # Consecutive poll misses before a host is surfaced as unreachable
  # (SPEC-0001: never silently dropped).
  @misses_before_down 3

  # Enrichment profile per host key: :hot (degraded-ish), :silent (unknown),
  # or :plain. Stand-in for discovery, keyed like the real fleet.
  @profiles %{
    "ogma" => :hot,
    "hud01" => :silent,
    "buoy" => :down
  }

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
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

  @doc """
  Child specs for the Proxmox pollers, one per host with API credentials in
  the baseline config. Hosts without a proxmox block keep the sampler feed.
  """
  @spec poller_specs(Path.t()) :: [map()]
  def poller_specs(baseline) do
    for {key, cfg} <- Config.load!(baseline).proxmox do
      Supervisor.child_spec(
        {Poller,
         host_key: key, base_url: cfg.base_url, token: cfg.token, interval_ms: cfg.poll_ms},
        id: {Poller, key}
      )
    end
  end

  # ---- GenServer -----------------------------------------------------------

  # Resolved at runtime, not as a module attribute. `priv/fleet/baseline.json`
  # is relative to the cwd, which is server/ under `mix phx.server` but /app in
  # a release — where priv actually lives at lib/binnacle-<vsn>/priv. The
  # release therefore crashed on boot with :enoent while every local run and
  # every test passed. Application.app_dir/2 resolves correctly under both, but
  # only if it is called at runtime: at compile time it bakes in the build path.
  defp default_baseline, do: Application.app_dir(:binnacle, ["priv", @default_baseline_path])

  @doc """
  The baseline config path: the `BINNACLE_BASELINE` override if one is set,
  otherwise the copy shipped inside the release.

  Public and single-sourced on purpose. Binnacle.Application needs the same
  path to build the Proxmox poller specs, and when it carried its own literal
  the two drifted: the pollers got a cwd-relative `priv/fleet/baseline.json`,
  which resolves under `mix phx.server` and does not exist in a release, so
  the application failed to start. It also meant BINNACLE_BASELINE moved the
  pollers' config without moving the fleet's.
  """
  @spec baseline_path() :: Path.t()
  def baseline_path do
    Application.get_env(:binnacle, :baseline) || default_baseline()
  end

  @impl true
  def init(opts) do
    baseline = Keyword.get(opts, :baseline, baseline_path())

    %Config{
      sites: sites,
      hosts: hosts,
      guests: guests,
      containers: containers,
      hardware: hw,
      proxmox: proxmox
    } = Config.load!(baseline)

    tick = 0

    state = %{
      tick: tick,
      sites: sites,
      hosts: hosts,
      guests: guests,
      containers: containers,
      hardware: hw,
      history: %{},
      proxmox: MapSet.new(Map.keys(proxmox)),
      misses: %{},
      unreachable: MapSet.new()
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

  # ---- proxmox discovery ---------------------------------------------------

  # A successful poll replaces everything the host owns: its guest list
  # (identity is vmid, so a migration re-parents instead of duplicating) and
  # its metric sample. Consecutive-miss state resets.
  def handle_info({:proxmox, host_key, {:ok, %{guests: discovered, sample: sample}}}, state) do
    guests =
      Enum.reject(state.guests, &(&1.host == host_key)) ++
        Enum.map(discovered, &%{&1 | host: host_key})

    history = push_history(Map.get(state.history, host_key, []), sample)

    {:noreply,
     %{
       state
       | guests: guests,
         history: Map.put(state.history, host_key, history),
         misses: Map.put(state.misses, host_key, 0),
         unreachable: MapSet.delete(state.unreachable, host_key)
     }}
  end

  # A failed poll degrades only its host (SPEC-0001: single integration
  # failure degrades one entity). The first misses keep last-known state
  # without comment; at @misses_before_down the host is surfaced as
  # unreachable while its last-known snapshot is retained and marked stale.
  def handle_info({:proxmox, host_key, {:error, reason}}, state) do
    misses = Map.get(state.misses, host_key, 0) + 1

    if misses >= @misses_before_down do
      Logger.warning("proxmox poll failed",
        host: host_key,
        consecutive_misses: misses,
        reason: reason
      )
    end

    {:noreply,
     %{
       state
       | misses: Map.put(state.misses, host_key, misses),
         unreachable:
           if(misses >= @misses_before_down,
             do: MapSet.put(state.unreachable, host_key),
             else: state.unreachable
           )
     }}
  end

  # ---- sampling ------------------------------------------------------------

  defp sample(%{hosts: hosts, tick: tick, proxmox: proxmox} = state) do
    history =
      Map.new(hosts, fn host ->
        prev = List.last(state.history[host.key] || [])

        # Hosts with live Proxmox discovery get their samples from the
        # poller; the synthetic sampler would only blur real readings.
        next =
          if MapSet.member?(proxmox, host.key) do
            prev
          else
            sample_host(host.key, tick, prev)
          end

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
            cond do
              MapSet.member?(state.unreachable, host.key) ->
                :down

              current ->
                Model.roll_up([
                  host_profile_status(host.key),
                  Model.sample_status(current),
                  Model.roll_up(Enum.map(guests, & &1.status))
                ])

              true ->
                # No signal from the host itself. Its children may still be
                # reporting, but "no reading and no complaints" is :unknown,
                # not :up — unless the profile says it is actually down.
                case Model.roll_up([
                       host_profile_status(host.key) | Enum.map(guests, & &1.status)
                     ]) do
                  :up -> :unknown
                  other -> other
                end
            end

          host_stale = current == nil or MapSet.member?(state.unreachable, host.key)

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
            stale: host_stale
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
