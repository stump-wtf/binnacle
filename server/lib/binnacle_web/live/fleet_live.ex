defmodule BinnacleWeb.FleetLive do
  @moduledoc """
  The zen overview: every site, host, guest, and container on one quiet page,
  with hardware metrics and trend lines.

  Governing: ADR-0002 (containment spine), ADR-0005 (hardware over time).

  The design brief is *chill*: a low-contrast terminal canvas, no motion
  except the data itself, and colour reserved for status. Rows are collapsed
  to a scan-friendly line — host, site status, key readings with sparklines —
  and expand in place into the hardware panel (usage, consumption, capacity,
  temperature, SMART) plus the guest/container tree.

  The LiveView subscribes to the fleet context's PubSub tick and re-reads
  `Fleet.snapshot/0` on every push; it owns no data of its own.
  """

  use BinnacleWeb, :live_view

  alias Binnacle.Fleet
  alias BinnacleWeb.Ui.{Badge, Feedback, Icon, Meter, Panel, Sparkline, Status, Theme}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Fleet.subscribe()
    end

    socket =
      socket
      |> assign(theme: :night, expanded: MapSet.new())
      |> refresh()

    {:ok, socket}
  end

  def handle_info(:fleet_tick, socket), do: {:noreply, refresh(socket)}

  def handle_event("toggle-theme", _params, socket) do
    {:noreply, assign(socket, theme: Theme.toggle(socket.assigns.theme))}
  end

  def handle_event("expand", %{"id" => id}, socket) do
    expanded = toggle_expanded(socket.assigns.expanded, id)
    {:noreply, assign(socket, expanded: expanded)}
  end

  def handle_event("theme-sync", %{"theme" => raw}, socket) do
    case Theme.from_string(raw) do
      {:ok, theme} -> {:noreply, assign(socket, theme: theme)}
      :error -> {:noreply, socket}
    end
  end

  defp refresh(socket) do
    assign(socket, sites: Fleet.snapshot())
  end

  defp toggle_expanded(set, id) do
    if MapSet.member?(set, id) do
      MapSet.delete(set, id)
    else
      MapSet.put(set, id)
    end
  end

  def render(assigns) do
    ~H"""
    <div
      id="fleet"
      class="min-h-screen bg-void px-6 py-10"
      data-theme={Theme.to_string(@theme)}
      phx-hook="ThemeSync"
    >
      <div class="mx-auto flex max-w-[1160px] flex-col gap-8">
        <header class="flex flex-wrap items-end justify-between gap-4">
          <div class="flex flex-col gap-2">
            <Badge.eyebrow text="fleet" />
            <h1 class="font-display text-3xl font-bold text-bright">
              binnacle<Feedback.cursor />
            </h1>
            <p class="max-w-[68ch] text-sm text-muted">
              sites → hosts → VMs → containers, with hardware readings over time.
            </p>
          </div>
          <div class="flex items-center gap-2 text-sm text-muted">
            <Icon.icon name={:activity} class="size-4 text-neon-cyan" /> sampling every 5s
          </div>
        </header>

        <div :for={site <- @sites} class="flex flex-col gap-4" id={"site-#{site.slug}"}>
          <div class="flex flex-wrap items-center gap-3">
            <Icon.icon name={:site} class="size-4 text-muted" />
            <h2 class="font-display text-lg font-bold text-bright">{site.slug}</h2>
            <%= if site.kind == :airbnb do %>
              <Badge.chip hue="info" label="airbnb" />
            <% else %>
              <span class="font-mono text-2xs uppercase tracking-wide text-dim">home</span>
            <% end %>
            <Badge.status status={site.status} />
          </div>

          <div class="flex flex-col gap-3">
            <.host_row
              :for={host <- site.hosts}
              host={host}
              site_slug={site.slug}
              expanded={MapSet.member?(@expanded, host.key)}
            />
          </div>
        </div>

        <footer class="border-t border-line-dim pt-4">
          <Feedback.key_hint pairs={[
            %{key: "t", action: "theme"},
            %{key: "enter", action: "expand"}
          ]} />
        </footer>
      </div>
    </div>
    """
  end

  defp host_row(assigns) do
    ~H"""
    <div id={"host-#{@host.key}"} class="flex flex-col gap-3">
      <button
        class="group flex flex-wrap items-center gap-x-4 gap-y-2 rounded-md border border-line bg-surface bg-[linear-gradient(180deg,var(--tint-primary),transparent_80px)] px-4 py-3 text-left transition-[border-color] duration-200 hover:border-line-bright"
        phx-click="expand"
        phx-value-id={@host.key}
      >
        <span class="flex min-w-[9rem] items-center gap-2 font-bold text-bright">
          <Icon.icon name={:host} class="size-4 text-muted" />
          {@host.key}
        </span>
        <Badge.status status={@host.status} />
        <%= if @host.stale do %>
          <span class="font-mono text-2xs uppercase tracking-wide text-dim">no signal</span>
        <% else %>
          <span class="flex items-center gap-4">
            <.reading
              label="cpu"
              value={@host.sample.cpu}
              unit="%"
              thresholds={Meter.cpu()}
              series={@host.series.cpu}
            />
            <.reading
              label="mem"
              value={@host.sample.memory}
              unit="%"
              thresholds={Meter.memory()}
              series={@host.series.memory}
            />
            <.reading
              label="temp"
              value={@host.sample.cpu_temp}
              unit="°C"
              thresholds={Meter.temperature()}
              series={@host.series.cpu_temp}
              max={100.0}
            />
          </span>
        <% end %>
        <span class="ml-auto font-mono text-2xs text-dim group-hover:text-muted">
          {if @expanded, do: "− collapse", else: "+ hardware"}
        </span>
      </button>

      <%= if @expanded do %>
        <.hardware_panel host={@host} />
      <% end %>
    </div>
    """
  end

  # One metric on the collapsed row: reading in its status hue plus the trend
  # line beside it. The number is now; the line is where it is going.
  defp reading(assigns) do
    assigns =
      assign(assigns,
        max: Map.get(assigns, :max) || 100.0,
        status: metric_status(assigns.value, assigns.thresholds)
      )

    ~H"""
    <span class="flex items-center gap-2 font-mono text-xs">
      <span class="uppercase tracking-wide text-dim">{@label}</span>
      <span class={"font-bold tabular-nums " <> Status.text_class(@status)}>
        {format(@value)}{@unit}
      </span>
      <Sparkline.sparkline
        label={@label}
        series={@series}
        warn={@thresholds.warn}
        danger={@thresholds.danger}
        max={@max}
        class="h-6 w-28"
      />
    </span>
    """
  end

  defp hardware_panel(assigns) do
    ~H"""
    <Panel.view title={"#{@host.key} hardware"} eyebrow="host">
      <div class="flex flex-col gap-5">
        <div class="grid gap-5 md:grid-cols-2">
          <div class="flex flex-col gap-3">
            <Meter.view label="cpu" value={@host.sample.cpu || 0} thresholds={Meter.cpu()} />
            <Meter.view label="memory" value={@host.sample.memory || 0} thresholds={Meter.memory()} />
            <Meter.view
              label="disk"
              value={@host.sample.disk || 0}
              thresholds={%{warn: 85, danger: 95}}
            />
          </div>
          <div class="flex flex-col gap-3">
            <Meter.view
              label="package temp"
              value={@host.sample.cpu_temp || 0}
              unit="°C"
              thresholds={Meter.temperature()}
            />
            <Meter.view
              label="hdd temp"
              value={@host.sample.hdd_temp || 0}
              unit="°C"
              thresholds={%{warn: 45, danger: 55}}
            />
          </div>
        </div>

        <div class="flex flex-col gap-4 border-t border-line-dim pt-4">
          <div class="flex flex-col gap-3">
            <Sparkline.sparkline
              label="cpu trend"
              series={@host.series.cpu}
              warn={Meter.cpu().warn}
              danger={Meter.cpu().danger}
              class="h-8 w-full"
            />
            <Sparkline.sparkline
              label="memory trend"
              series={@host.series.memory}
              warn={Meter.memory().warn}
              danger={Meter.memory().danger}
              class="h-8 w-full"
            />
          </div>
        </div>

        <div class="flex flex-col gap-3 border-t border-line-dim pt-4">
          <Badge.eyebrow text="devices" />
          <div class="flex flex-wrap gap-2">
            <span
              :for={device <- @host.hardware}
              class="inline-flex items-center gap-2 rounded-xs border border-line-dim bg-inset px-2 py-1 font-mono text-xs text-body"
            >
              <span class="text-dim">{device.name}</span>
              {device.model}
              <%= if device.smart do %>
                <Badge.chip hue={smart_hue(device.smart)} label={"smart: #{device.smart}"} />
              <% end %>
            </span>
          </div>
        </div>

        <%= if @host.guests != [] do %>
          <div class="flex flex-col gap-3 border-t border-line-dim pt-4">
            <Badge.eyebrow text="guests" />
            <div class="flex flex-col gap-2">
              <div :for={guest <- @host.guests} class="flex flex-wrap items-center gap-x-4 gap-y-1">
                <span class="flex items-center gap-2 font-mono text-sm text-bright">
                  <Icon.icon name={:container} class="size-4 text-muted" />
                  {guest.name}
                  <span class="text-dim">#{guest.vmid}</span>
                </span>
                <Badge.status status={guest.status} />
                <span class="flex flex-wrap gap-2">
                  <Badge.chip
                    :for={container <- guest.containers}
                    hue="info"
                    label={container.name}
                  />
                </span>
                <span :if={guest.hardware != []} class="flex flex-wrap gap-2">
                  <span
                    :for={device <- guest.hardware}
                    class="font-mono text-2xs text-dim"
                    title="passed through to this guest"
                  >
                    ⤷ {device.name}
                  </span>
                </span>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </Panel.view>
    """
  end

  defp metric_status(nil, _thresholds), do: :unknown

  defp metric_status(value, thresholds),
    do: Meter.status_for(thresholds, value)

  defp smart_hue("ok"), do: "ok"
  defp smart_hue("warn"), do: "warn"
  defp smart_hue(_), do: "danger"

  defp format(nil), do: "–"

  defp format(value) do
    Meter.format_value(value)
  end
end
