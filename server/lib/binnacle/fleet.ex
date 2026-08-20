defmodule Binnacle.Fleet do
  @moduledoc """
  The fleet context: one GenServer owning the containment spine, the metrics
  history, and the sample clock.

  Governing: ADR-0002 / SPEC-0001. Topology comes from a JSON config file or
  live discovery; readings come from the pollers. Every LiveView reads the
  model through `snapshot/0` — never the GenServer's raw state — and the
  snapshot contains no credentials, ever.

  A host binnacle has no telemetry source for reports no readings at all. It
  does not get invented ones: `Binnacle.Fleet.Sampler` is a fixture for the
  component gallery and the tests, enabled only by `:synthetic_metrics`, and
  a fleet monitor that draws a plausible sine wave over a host it cannot
  actually see is worse than one that admits it.

  History is a capped list per host, oldest first: `@history_len` samples is
  the window the trend lines draw (at `@sample_ms` cadence, ~10 minutes).
  """

  require Logger

  use GenServer

  alias Binnacle.Fleet.Config
  alias Binnacle.Fleet.Discovery
  alias Binnacle.Fleet.Model
  alias Binnacle.Fleet.Proxmox.Poller
  alias Binnacle.Fleet.Proxmox.Token
  alias Binnacle.Fleet.Sampler

  @sample_ms 5_000
  @history_len 120
  @default_baseline_path "fleet/baseline.json"
  # Consecutive poll misses before a host is surfaced as unreachable
  # (SPEC-0001: never silently dropped).
  @misses_before_down 3

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
  Child specs for the Proxmox pollers, one per host with API credentials.

  In live-discovery mode (FLEET_PROXMOX_NODES configured) the pollers come from
  the same env config the Fleet bootstraps its topology from — the baseline file
  may carry no credentials at all in that mode, and without this the discovered
  hosts would never receive an ongoing poll. Otherwise they come from the
  baseline config as before. Hosts without a proxmox block keep the sampler feed.
  """
  @spec poller_specs() :: [map()]
  def poller_specs do
    case Application.get_env(:binnacle, :proxmox_nodes, []) do
      [] ->
        poller_specs(baseline_path())

      nodes ->
        for node <- nodes do
          Supervisor.child_spec(
            {Poller,
             host_key: node["name"],
             base_url: node["url"],
             token: Token.reveal(env_node_token!(node))},
            id: {Poller, node["name"]}
          )
        end
    end
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

  # FLEET_PROXMOX_NODES bypasses Binnacle.Fleet.Config, so it needs the same
  # credential check the baseline file gets — otherwise the env path is the
  # one way a half-token still reaches PVE and 401s on every poll.
  defp env_node_token!(node) do
    where = "FLEET_PROXMOX_NODES entry #{inspect(node["name"])}"

    case {node["token"], node["token_id"], node["token_secret"]} do
      {token, nil, nil} when is_binary(token) ->
        Token.parse!(token, where)

      {nil, id, secret} when is_binary(id) and is_binary(secret) ->
        Token.compose!(id, secret, where)

      _ ->
        raise ArgumentError, "#{where} needs \"token\", or \"token_id\" + \"token_secret\""
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
    {sites, hosts, guests, containers, hw, proxmox_keys} =
      case discover_fleet(opts) do
        {:discovered, discovered} ->
          Logger.info(
            "Fleet topology discovered from live APIs: #{length(discovered.hosts)} hosts, #{length(discovered.guests)} guests"
          )

          {discovered.sites, discovered.hosts, discovered.guests, [], %{},
           MapSet.new(Enum.map(discovered.hosts, & &1.key))}

        :fallback ->
          baseline = Keyword.get(opts, :baseline, baseline_path())

          %Config{
            sites: sites,
            hosts: hosts,
            guests: guests,
            containers: containers,
            hardware: hw,
            proxmox: proxmox
          } = Config.load!(baseline)

          {sites, hosts, guests, containers, hw, MapSet.new(Map.keys(proxmox))}
      end

    tick = 0

    state = %{
      tick: tick,
      sites: sites,
      hosts: hosts,
      guests: guests,
      containers: containers,
      hardware: hw,
      history: %{},
      proxmox: proxmox_keys,
      misses: %{},
      unreachable: MapSet.new()
    }

    state = sample(state)
    :timer.send_interval(@sample_ms, :tick)
    {:ok, state}
  end

  defp discover_fleet(_opts) do
    proxmox_nodes = Application.get_env(:binnacle, :proxmox_nodes, [])
    unifi = Application.get_env(:binnacle, :unifi)
    site_map = Application.get_env(:binnacle, :site_map, %{})
    site_kinds = Application.get_env(:binnacle, :site_kinds, %{})

    parsed_nodes =
      Enum.map(proxmox_nodes, fn node ->
        %{name: node["name"], url: node["url"], token: Token.reveal(env_node_token!(node))}
      end)

    case Discovery.discover(
           proxmox_nodes: parsed_nodes,
           unifi: unifi,
           site_map: site_map,
           site_kinds: site_kinds
         ) do
      {:ok, result} ->
        {:discovered, result}

      nil ->
        :fallback

      {:error, reason} ->
        Logger.warning("Fleet discovery failed, falling back to baseline: #{reason}")
        :fallback
    end
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

    # The reason belongs in the message, not in metadata: the default console
    # formatter is configured with metadata: [:request_id], so a reason passed
    # as metadata is dropped and every failure logs the bare, useless line
    # "proxmox poll failed". Reasons from the client name the failing step and
    # never carry the credential.
    if misses >= @misses_before_down do
      Logger.warning(
        "proxmox poll failed for #{host_key} after #{misses} consecutive misses: #{reason}"
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

  # The sample clock only advances history for hosts this node is *not*
  # polling. Polled hosts are written by handle_info/2 as their results land;
  # re-touching them here would push duplicate points between polls and blur
  # the trend line with a slower clock's idea of "now".
  defp sample(%{hosts: hosts, tick: tick, proxmox: proxmox} = state) do
    history =
      Map.new(hosts, fn host ->
        prev = List.last(state.history[host.key] || [])

        next =
          cond do
            MapSet.member?(proxmox, host.key) ->
              prev

            synthetic?() ->
              Sampler.sample_host(host.key, tick, prev, seed: :erlang.phash2(host.key))

            # No telemetry source. nil is the honest reading: the sparkline
            # breaks and the row says so, rather than drawing a number binnacle
            # did not measure.
            true ->
              nil
          end

        {host.key, push_history(state.history[host.key], next)}
      end)

    %{state | history: history}
  end

  # Synthetic readings are a fixture, not a fallback: on for the component
  # gallery and the tests, off everywhere a real fleet is being watched.
  defp synthetic?, do: Application.get_env(:binnacle, :synthetic_metrics, false)

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
            guest_ref = Model.Guest.ref(guest)

            guest_containers =
              Map.get(containers_by_guest, guest_ref, [])
              |> Enum.map(fn c -> %{c | status: :up} end)

            %{
              guest
              | containers: guest_containers,
                hardware: Map.get(state.hardware, guest_ref, []),
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

          # Three different silences, told apart rather than merged into one
          # "no signal". A host we poll and cannot reach is an outage; a host
          # we have no way to measure is a gap in binnacle's coverage and must
          # not read as either an outage or as healthy.
          telemetry =
            cond do
              MapSet.member?(state.unreachable, host.key) -> :unreachable
              MapSet.member?(state.proxmox, host.key) -> :live
              true -> :none
            end

          host_status =
            cond do
              telemetry == :unreachable ->
                :down

              current ->
                Model.roll_up([
                  Model.sample_status(current),
                  Model.roll_up(Enum.map(guests, & &1.status))
                ])

              true ->
                # No reading from the host itself. Its children may still be
                # reporting, but "no reading and no complaints" is :unknown,
                # not :up.
                case Model.roll_up(Enum.map(guests, & &1.status)) do
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
            telemetry: telemetry,
            stale: current == nil or telemetry == :unreachable
          })
        end)

      %{site | hosts: hosts}
      |> Map.merge(%{status: Model.roll_up(Enum.map(hosts, & &1.status))})
    end)
  end

  # Per-metric series for the trend lines, oldest first.
  defp series(history) do
    keys = [:cpu, :memory, :disk, :cpu_temp, :hdd_temp]

    Map.new(keys, fn key ->
      {key, Enum.map(history, &if(&1, do: Map.get(&1, key), else: nil))}
    end)
  end
end
