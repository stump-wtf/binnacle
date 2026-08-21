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
  alias Binnacle.Fleet.Unifi.Poller, as: UnifiPoller
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
  Fleet-wide config drift: entities the APIs report that no baseline
  declares. Each entry carries `:kind`, `:detail`, `:observed`, and `:site`.
  """
  @spec drift() :: [map()]
  def drift do
    GenServer.call(__MODULE__, :drift)
  end

  @doc """
  Child specs for the Proxmox pollers, one per host with API credentials.

  Two credential sources, and FLEET_PROXMOX_NODES wins outright: it names the
  hosts to poll and carries their tokens, so the baseline file may carry no
  credentials at all. Otherwise they come from the baseline. Hosts without a
  proxmox block keep the sampler feed either way.

  Whichever source is used, `polled_host_keys/1` must agree with it — the
  snapshot decides "live" versus "no telemetry source" from that set, and the
  two disagreeing is how a host reads as unwatched while being polled every
  30 seconds.
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

  @doc """
  Child specs for the UniFi pollers, one per site that declares a gateway
  (SPEC-0001 REQ "UniFi Site Discovery").

  A site with no `unifi` block gets no poller and reports `network: nil` —
  no gateway configured, which is different from a gateway that stopped
  answering.
  """
  @spec unifi_poller_specs() :: [map()]
  def unifi_poller_specs, do: unifi_poller_specs(baseline_path())

  @spec unifi_poller_specs(Path.t()) :: [map()]
  def unifi_poller_specs(baseline) do
    for {slug, cfg} <- Config.load!(baseline).unifi do
      Supervisor.child_spec(
        {UnifiPoller,
         site: slug, base_url: cfg.base_url, credential: cfg.credential, interval_ms: cfg.poll_ms},
        id: {UnifiPoller, slug}
      )
    end
  end

  # Which hosts actually have a Proxmox poller behind them. This has to be
  # read from the same place poller_specs/0 reads it: FLEET_PROXMOX_NODES
  # replaces the baseline's pollers rather than adding to them, so deriving
  # this set from the baseline alone inverts the honest-telemetry
  # distinction — every env-polled host reports "no telemetry source" while
  # real samples arrive, and any baseline host with a proxmox block reports
  # ":live" with no poller running at all.
  #
  # @joestump-agent 08/20/2026 - Split out during review of #54. Until this
  # PR the two were kept in step by the discovery path, which seeded these
  # keys from the same env node list; removing discovery removed that.
  defp polled_host_keys(baseline_proxmox) do
    case Application.get_env(:binnacle, :proxmox_nodes, []) do
      [] -> MapSet.new(Map.keys(baseline_proxmox))
      nodes -> MapSet.new(nodes, & &1["name"])
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
    # Topology is declared, always. There is no discovery mode that replaces
    # it: sites and hosts come from the baseline, and the pollers only ever
    # ENRICH what is declared here — guests, samples, network inventory.
    #
    # The replaced-wholesale path that used to live here dropped every
    # standalone host (hosts came only from Proxmox node lists) and took site
    # names from UniFi, where all four properties answer "default". See
    # Binnacle.Fleet.Discovery, which is now drift reporting rather than
    # topology construction.
    baseline = Keyword.get(opts, :baseline, baseline_path())

    %Config{
      sites: sites,
      hosts: hosts,
      guests: guests,
      containers: containers,
      hardware: hw,
      proxmox: proxmox
    } = Config.load!(baseline)

    proxmox_keys = polled_host_keys(proxmox)

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
      unreachable: MapSet.new(),
      networks: %{},
      drift: %{}
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
  def handle_call(:drift, _from, state) do
    {:reply, flatten_drift(state.drift), state}
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
  # its metric sample. Consecutive-miss state resets. Drift is computed from
  # the node names the API reports against the declared host keys.
  def handle_info(
        {:proxmox, host_key, {:ok, %{guests: discovered, sample: sample} = result}},
        state
      ) do
    guests =
      Enum.reject(state.guests, &(&1.host == host_key)) ++
        Enum.map(discovered, &%{&1 | host: host_key})

    history = push_history(Map.get(state.history, host_key, []), sample)

    # Compute drift: a node the API names that no baseline host declares.
    # A result without :nodes is a poller that does not report them, which is
    # not evidence of no drift — leave whatever this host last said standing.
    drift =
      put_drift(state.drift, {:proxmox, host_key}, Map.get(result, :nodes), fn nodes ->
        declared_keys = Enum.map(state.hosts, & &1.key)

        # Tag Proxmox drift with the host's site so the snapshot can group it.
        host_site = Enum.find_value(state.hosts, fn h -> if h.key == host_key, do: h.site end)

        host_key
        |> Discovery.proxmox_node_drift(declared_keys, nodes)
        |> Enum.map(&%{&1 | site: host_site})
      end)

    {:noreply,
     %{
       state
       | guests: guests,
         history: Map.put(state.history, host_key, history),
         misses: Map.put(state.misses, host_key, 0),
         unreachable: MapSet.delete(state.unreachable, host_key),
         drift: drift
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

  # ---- unifi discovery -----------------------------------------------------

  # A successful poll replaces the site's whole network picture: the gateway
  # and the device inventory behind it, stamped with the time it was read so
  # the UI can say how fresh it is. Drift is computed from the site names
  # the controller reports against the declared slug.
  def handle_info({:unifi, slug, {:ok, %{gateway: gateway, devices: devices} = result}}, state) do
    network = %Model.Network{
      reachable: true,
      reason: nil,
      at: DateTime.utc_now(),
      gateway: gateway,
      devices: devices
    }

    # site_names is nil when the sites call failed while the device call
    # succeeded. That is "not observed this cycle", not "no drift" — clearing
    # on it would make a transient controller hiccup silently retract a real
    # finding, so the previous answer stands until a poll actually observes.
    drift =
      put_drift(state.drift, {:unifi, slug}, Map.get(result, :site_names), fn names ->
        Discovery.unifi_site_drift(slug, names)
      end)

    {:noreply, %{state | networks: Map.put(state.networks, slug, network), drift: drift}}
  end

  # A failed poll marks the site's network unreachable WITH its reason, rather
  # than dropping the entry. An absent network and an unreachable one look
  # identical in a UI that only checks for presence, and they mean opposite
  # things: one is a site nobody configured, the other is a site that lost its
  # gateway.
  def handle_info({:unifi, slug, {:error, reason}}, state) do
    Logger.warning("unifi poll failed for site #{slug}: #{reason}")

    network = %Model.Network{
      reachable: false,
      reason: reason,
      at: DateTime.utc_now(),
      gateway: nil,
      devices: []
    }

    {:noreply, %{state | networks: Map.put(state.networks, slug, network)}}
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

  # Drift is stored per source — {:proxmox, host_key} or {:unifi, slug} — so a
  # poll replaces exactly what that source last reported and nothing else.
  #
  # An earlier shape kept one flat list and cleared a host's entries by testing
  # `detail =~ host_key`. `=~` is substring containment, and the detail carries
  # the observed node name as well as the host key, so a host named `lir` polling
  # successfully would delete dagda's finding about an undeclared node `lir-old`.
  # Keying the source removes the ambiguity instead of escaping around it.
  #
  # `observed` of nil means the poll did not observe this dimension at all. That
  # is not the same as observing nothing: the prior answer is left in place
  # rather than retracted.
  defp put_drift(drift, _source, nil, _compute), do: drift

  defp put_drift(drift, source, observed, compute) do
    case compute.(observed) do
      [] -> Map.delete(drift, source)
      entries -> Map.put(drift, source, entries)
    end
  end

  defp flatten_drift(drift) do
    drift
    |> Enum.sort_by(fn {source, _} -> source end)
    |> Enum.flat_map(fn {_source, entries} -> entries end)
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

            # Containers keep the status they were reported with. They used to
            # be stamped `:up` unconditionally here, which meant every
            # container in the config rendered green whether or not anything
            # had looked at it — and nothing had, because the discovery
            # channel for containers (SPEC-0001 REQ "Container Discovery") is
            # not built yet. A declared container nobody has polled is
            # `:unknown`, which is what the config gives it.
            guest_containers = Map.get(containers_by_guest, guest_ref, [])

            # The guest's own status comes from Proxmox — `running` is :up,
            # `stopped` is :down. Rolling up only the containers threw that
            # away, so a stopped VM was indistinguishable from a running one.
            %{
              guest
              | containers: guest_containers,
                hardware: Map.get(state.hardware, guest_ref, []),
                status: Model.roll_up([guest.status | Enum.map(guest_containers, & &1.status)])
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

      site_drift = Enum.filter(flatten_drift(state.drift), &site_matches_drift?(site.slug, &1))

      %{site | hosts: hosts, network: Map.get(state.networks, site.slug)}
      |> Map.merge(%{status: site_status(hosts, Map.get(state.networks, site.slug))})
      |> Map.merge(%{drift: site_drift})
    end)
  end

  defp site_matches_drift?(slug, %{site: slug}), do: true
  defp site_matches_drift?(_slug, _drift), do: false

  # A site is as bad as its worst host, plus its gateway. An unreachable
  # gateway degrades the site even when every host is fine: the hosts are
  # reachable from binnacle, which sits inside the network, and that says
  # nothing about whether the property has connectivity.
  #
  # A site with no hosts and no gateway is :unknown — nothing has been
  # measured, and green would be a claim binnacle cannot support.
  defp site_status(hosts, network) do
    Model.roll_up(Enum.map(hosts, & &1.status) ++ gateway_status(network))
  end

  defp gateway_status(nil), do: []
  defp gateway_status(%Model.Network{reachable: false}), do: [:down]
  defp gateway_status(%Model.Network{gateway: nil}), do: [:degraded]
  defp gateway_status(%Model.Network{gateway: gateway}), do: [gateway.status]

  # Per-metric series for the trend lines, oldest first.
  defp series(history) do
    keys = [:cpu, :memory, :disk, :cpu_temp, :hdd_temp]

    Map.new(keys, fn key ->
      {key, Enum.map(history, &if(&1, do: Map.get(&1, key), else: nil))}
    end)
  end
end
