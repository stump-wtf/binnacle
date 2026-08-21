defmodule BinnacleWeb.GalleryLive do
  @moduledoc """
  The design-stack gallery.

  Governing: ADR-0004 (Elixir full-stack; Phoenix LiveView).

  **This is not binnacle.** The fleet app lands with the bootstrap story. What
  this LiveView does is exercise every component in `Ui.*` on one page, which
  buys three things a README cannot:

  - a compile-time check that the component APIs actually compose, so the
    library cannot rot between stories;
  - a real Vite/Tailwind build target, so the class strings the components
    emit are proven to exist rather than assumed;
  - somewhere to look at both themes side by side while designing.

  It is also the smallest honest example of the intended shape: a LiveView
  with a pure `handle_event/3` update and the one clock every spinner reads
  expressed as a single `:timer.send_interval/3` message stream.
  """

  use BinnacleWeb, :live_view

  alias BinnacleWeb.Ui.Theme

  alias BinnacleWeb.Ui.{
    Badge,
    Feedback,
    Icon,
    Meter,
    Panel,
    Table,
    Terminal
  }

  # One clock for every spinner on the page. 120ms is the design system's
  # `--dur-fast`; slower reads as a stutter, faster wastes frames on a glyph
  # animation nobody is staring at.
  @tick_interval_ms 120

  defmodule Host do
    @moduledoc """
    A stand-in for the real wire type, which will live in a shared context
    module when the fleet story lands. Local and deliberately minimal — the
    gallery needs something table-shaped, not the fleet model.
    """
    defstruct [:name, :site, :status, :cpu, :memory, :temp_c]
  end

  # Sample rows, chosen to put one of every status on screen at once —
  # including a down host and an unknown one, since those are the states most
  # likely to be styled carelessly and never looked at.
  @hosts [
    %{name: "lir", site: "wynberg", status: :up, cpu: 34.2, memory: 61.8, temp_c: 52},
    %{name: "dagda", site: "wynberg", status: :up, cpu: 22.1, memory: 48.3, temp_c: 49},
    %{name: "ogma", site: "wynberg", status: :degraded, cpu: 88.4, memory: 79.2, temp_c: 81},
    %{name: "nyma", site: "wynberg", status: :unknown, cpu: 0, memory: 0, temp_c: 0},
    %{name: "pidge", site: "wynberg", status: :up, cpu: 3.8, memory: 10.5, temp_c: 36},
    %{name: "pie01", site: "wynberg", status: :up, cpu: 12, memory: 44.1, temp_c: 47.5},
    %{name: "pie02", site: "wynberg", status: :up, cpu: 8.3, memory: 38.2, temp_c: 44},
    %{name: "kitt", site: "wynberg", status: :up, cpu: 15.6, memory: 52.3, temp_c: 55},
    %{name: "bender", site: "wynberg", status: :up, cpu: 42.1, memory: 68.7, temp_c: 62},
    %{name: "lotor", site: "dtw", status: :up, cpu: 18.4, memory: 35.6, temp_c: 45},
    %{name: "coran", site: "dtw", status: :up, cpu: 14.2, memory: 31.8, temp_c: 43},
    %{name: "buoy", site: "dtw", status: :down, cpu: 0, memory: 96.5, temp_c: 91.2}
  ]

  @log_lines [
    "2026-08-15T09:14:02Z  INF  serving initial configuration",
    "2026-08-15T09:14:02Z  INF  autosaved config          file=/config/caddy/autosave.json",
    "2026-08-15T09:14:07Z  INF  http.log.access  handled request  status=200 host=cairn.stump.rocks",
    "2026-08-15T09:14:09Z  WRN  http.acme_client  challenge failed  identifier=binnacle.stump.rocks",
    "2026-08-15T09:14:11Z  INF  http.log.access  handled request  status=304 host=outline.stump.rocks"
  ]

  @key_hints [
    %{key: "↑/↓", action: "navigate"},
    %{key: "enter", action: "select"},
    %{key: "t", action: "theme"},
    %{key: "r", action: "refresh"},
    %{key: "q", action: "quit"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    # The theme was resolved by the layout's bootstrap script before first
    # paint (no flash). The ThemeSync hook reports the resolved value back to
    # us on connect, and this is the only place it is derived from anything.
    if connected?(socket), do: :timer.send_interval(@tick_interval_ms, :tick)

    {:ok, assign(socket, theme: :night, tick: 0, selected: "ogma", hosts: @hosts)}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, update(socket, :tick, &(&1 + 1))}
  end

  @impl true
  def handle_event("theme-sync", %{"theme" => raw}, socket) do
    case Theme.from_string(raw) do
      {:ok, theme} -> {:noreply, assign(socket, theme: theme)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("toggle-theme", _params, socket) do
    {:noreply, assign(socket, theme: Theme.toggle(socket.assigns.theme))}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, tick: 0)}
  end

  def handle_event("select-host", %{"id" => id}, socket) do
    # Clicking the selected row clears it, so the table has a way back to
    # "nothing selected" without a second control.
    selected = if socket.assigns.selected == id, do: nil, else: id
    {:noreply, assign(socket, selected: selected)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="gallery"
      class="min-h-screen bg-void px-6 py-10"
      data-theme={Theme.to_string(@theme)}
      phx-hook="ThemeSync"
    >
      <div class="mx-auto flex max-w-[1160px] flex-col gap-8">
        <.page_header tick={@tick} theme={@theme} />
        <.overview tick={@tick} />
        <.fleet_table hosts={@hosts} selected={@selected} />
        <.logs />
        <.footer />
      </div>
    </div>
    """
  end

  defp page_header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-end justify-between gap-4">
      <div class="flex flex-col gap-2">
        <Badge.eyebrow text="design stack" />
        <h1 class="font-display text-3xl font-bold text-bright">
          binnacle<Feedback.cursor />
        </h1>
        <p class="max-w-[68ch] text-sm text-muted">
          sites → hosts → VMs → containers. every component on this page comes from Ui.*, styled by the bubbletea design system.
        </p>
      </div>
      <div class="flex items-center gap-2">
        <.theme_button theme={@theme} />
        <.refresh_button />
      </div>
    </header>
    """
  end

  defp theme_button(assigns) do
    assigns = assign(assigns, :label, "theme: " <> Theme.label(assigns.theme))

    ~H"""
    <BinnacleWeb.Ui.Button.view
      variant={:ghost}
      label={@label}
      phx-click="toggle-theme"
    />
    """
  end

  defp refresh_button(assigns) do
    ~H"""
    <BinnacleWeb.Ui.Button.view
      variant={:primary}
      label="refresh"
      phx-click="refresh"
    />
    """
  end

  # Three summary panels. The middle one carries an accent rail because it is
  # reporting a degraded host — the pattern for drawing the eye without
  # recolouring the whole card.
  defp overview(assigns) do
    ~H"""
    <div class="grid gap-5 md:grid-cols-3">
      <Panel.view title="fleet" eyebrow="rollup">
        <div class="flex flex-wrap items-center gap-2">
          <Badge.status status={:up} />
          <Badge.count count={5} noun="hosts" />
          <Badge.count count={14} noun="containers" />
        </div>
      </Panel.view>
      <Panel.view title="ogma" eyebrow="host" accent="warn">
        <div class="flex flex-col gap-3">
          <Meter.view label="cpu" value={88.4} thresholds={Meter.cpu()} />
          <Meter.view label="memory" value={79.2} thresholds={Meter.memory()} />
          <Meter.view label="package temp" value={81.0} unit="°C" thresholds={Meter.temperature()} />
        </div>
      </Panel.view>
      <Panel.view title="discovery" eyebrow="activity">
        <div class="flex flex-col gap-3">
          <Feedback.spinner frames={Feedback.braille()} tick={@tick} label="probing proxmox…" />
          <div class="flex items-center gap-2 text-sm text-muted">
            <Icon.icon name={:activity} class="size-4 text-neon-cyan" /> 3 sites reporting
          </div>
          <div class="flex items-center gap-2 text-sm text-muted">
            <Icon.icon name={:host} class="size-4 text-ok" /> last sweep 42s ago
          </div>
        </div>
      </Panel.view>
    </div>
    """
  end

  defp fleet_table(assigns) do
    ~H"""
    <Panel.view title="hosts" eyebrow="fleet">
      <Table.view
        id="hosts"
        rows={@hosts}
        row_id={& &1.name}
        selected={@selected}
        on_select="select-host"
        empty="no hosts discovered"
      >
        <:col :let={host} label="host">
          <span class="flex items-center gap-2 font-bold text-bright">
            <Icon.icon name={:host} class="size-4 text-muted" />
            {host.name}
          </span>
        </:col>
        <:col :let={host} label="site">
          <span class="text-muted">{host.site}</span>
        </:col>
        <:col :let={host} label="status">
          <Badge.status status={host.status} />
        </:col>
        <:col :let={host} label="cpu" numeric>
          {Meter.format_value(host.cpu)}%
        </:col>
        <:col :let={host} label="mem" numeric>
          {Meter.format_value(host.memory)}%
        </:col>
        <:col :let={host} label="temp" numeric>
          {Meter.format_value(host.temp_c)}°C
        </:col>
      </Table.view>
    </Panel.view>
    """
  end

  defp logs(assigns) do
    assigns = assign(assigns, lines: @log_lines)

    ~H"""
    <Terminal.view title="caddy · ie01" mode={:following} lines={@lines} />
    """
  end

  defp footer(assigns) do
    assigns = assign(assigns, pairs: @key_hints)

    ~H"""
    <footer class="border-t border-line-dim pt-4">
      <div class="flex items-center justify-between">
        <Feedback.key_hint pairs={@pairs} />
        <Feedback.build_info sha={build_sha()} />
      </div>
    </footer>
    """
  end

  defp build_sha, do: Application.get_env(:binnacle, :build_sha)
end
