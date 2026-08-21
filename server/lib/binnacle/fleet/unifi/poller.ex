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
  # @joestump-agent 08/21/2026 - Added fetch_sites to also return observed
  #   site names for config drift detection (issue #55).

  use GenServer

  alias Binnacle.Fleet.Unifi.Client
  alias Binnacle.Fleet.Unifi.Credential

  @default_interval :timer.seconds(60)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    # The credential lives in this process's state for its whole life, so it
    # gets both halves of the Proxmox poller's defence. :sensitive disables
    # tracing and hides the message queue, the dictionary and the backtrace —
    # but NOT the State line, which gen_server formats itself and which a
    # sensitive process still logs in full. Binnacle.Fleet.Unifi.Credential is
    # what redacts that, and the value is unwrapped only on the way to the
    # wire.
    #
    # @joestump-agent 08/20/2026 - Wrapped the credential during review of
    # #54; the sensitive flag alone left the password in every crash report.
    Process.flag(:sensitive, true)

    state = %{
      site: Keyword.fetch!(opts, :site),
      base_url: Keyword.fetch!(opts, :base_url),
      credential: Credential.new(Keyword.fetch!(opts, :credential)),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval),
      fetch: Keyword.get(opts, :fetch, &Client.fetch_devices/3),
      fetch_sites: Keyword.get(opts, :fetch_sites, &Client.fetch_sites/3),
      fetch_opts: Keyword.get(opts, :fetch_opts, []),
      sink: Keyword.get(opts, :sink, Binnacle.Fleet)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    cred = Credential.reveal(state.credential)

    result =
      case state.fetch.(state.base_url, cred, state.fetch_opts) do
        {:ok, data} ->
          # Also fetch site names for drift detection. A failure here does not
          # degrade the device poll — drift is secondary to the device inventory.
          site_names =
            case state.fetch_sites.(state.base_url, cred, state.fetch_opts) do
              {:ok, sites} -> Enum.map(sites, &site_name/1)
              {:error, _} -> nil
            end

          {:ok, Map.put(data, :site_names, site_names)}

        {:error, _} = error ->
          error
      end

    # Errors are delivered too: a site whose controller stops answering must
    # say so, rather than keeping a stale inventory that looks current.
    send(state.sink, {:unifi, state.site, result})
    {:noreply, state, {:continue, :reschedule}}
  end

  # Client.fetch_sites/3 returns %Site{}, but :fetch_sites is an injectable
  # seam and drift is secondary to the device inventory — so an unexpected
  # shape is described, never raised on. `to_string/1` here raised
  # Protocol.UndefinedError on any map without a "name" key, which would take
  # the poller down mid-cycle and lose the device poll that had just
  # succeeded.
  defp site_name(%Binnacle.Fleet.Model.Site{slug: slug}), do: slug
  defp site_name(%{"name" => name}) when is_binary(name), do: name
  defp site_name(name) when is_binary(name), do: name
  defp site_name(other), do: inspect(other)

  @impl true
  def handle_continue(:reschedule, state) do
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end
end
