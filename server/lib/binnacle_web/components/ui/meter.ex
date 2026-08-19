defmodule BinnacleWeb.Ui.Meter do
  @moduledoc """
  The horizontal metric bar — the workhorse of a fleet monitor.

  Governing: ADR-0002 (hardware metrics at host and VM level: usage,
  consumption, capacity, temperature).

  The fill is a real gradient (`--grad-neon-bar`) only while nominal. Once a
  metric crosses a threshold the fill goes flat in the alert hue: a gradient at
  95% CPU would put mint at the left edge of a bar that means trouble.

  Thresholds are per-metric and explicit. 85% memory is unremarkable; 85 °C on
  a CPU package is not. A single global "warn at 80" would either cry wolf
  about memory or stay silent about heat.
  """

  use Phoenix.Component

  import BinnacleWeb.Ui.Status, only: [dot_class: 1, text_class: 1]

  @type thresholds :: %{warn: number(), danger: number()}

  @doc "Percentage-style default: amber at 75, red at 90."
  @spec default_thresholds() :: thresholds()
  def default_thresholds, do: %{warn: 75, danger: 90}

  @doc "CPU load as a percentage. Later than memory: 80% CPU is working, not failing."
  @spec cpu() :: thresholds()
  def cpu, do: %{warn: 80, danger: 95}

  @doc "Memory as a percentage. Earlier than CPU — memory pressure ends in the OOM killer."
  @spec memory() :: thresholds()
  def memory, do: %{warn: 75, danger: 90}

  @doc "Package/sensor temperature in °C. 80 is the throttling neighbourhood for the fleet's Proxmox hosts."
  @spec temperature() :: thresholds()
  def temperature, do: %{warn: 80, danger: 90}

  @doc """
  Classify a reading. Exposed because the same thresholds must drive the
  summary chip on a collapsed row and the bar inside the expanded one —
  deriving it twice is how the two end up disagreeing.
  """
  @spec status_for(thresholds(), number()) :: BinnacleWeb.Ui.Status.t()
  def status_for(thresholds, value) do
    cond do
      value >= thresholds.danger -> :down
      value >= thresholds.warn -> :degraded
      true -> :up
    end
  end

  @doc "Clamp to the track: a metric can report over 100; the bar saturates rather than overflows."
  @spec fraction(number(), number()) :: float()
  def fraction(value, max) when max > 0, do: (value / max) |> clamp01()
  def fraction(_value, _max), do: 0.0

  defp clamp01(x) when x < 0, do: 0.0
  defp clamp01(x) when x > 1, do: 1.0
  defp clamp01(x), do: x * 1.0

  attr :label, :string, required: true
  attr :value, :float, required: true
  attr :max, :float, default: 100.0
  attr :unit, :string, default: ""

  attr :thresholds, :map,
    required: true,
    doc: "One of the `*_thresholds/0` sets or a map with :warn/:danger."

  def view(assigns) do
    %{value: value, max: max, unit: unit, thresholds: thresholds} = assigns

    assigns =
      assign(assigns,
        status: status_for(thresholds, value),
        pct: fraction(value, max) * 100,
        reading: format_value(value) <> unit,
        value_now: format_value(value),
        value_max: format_value(max)
      )

    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex items-baseline justify-between gap-3 font-mono text-2xs">
        <span class="uppercase tracking-wide text-dim">{@label}</span>
        <span class={"font-bold tabular-nums " <> text_class(@status)}>{@reading}</span>
      </div>
      <div
        class="h-1.5 w-full overflow-hidden rounded-xs bg-inset border border-line-dim"
        role="meter"
        aria-label={@label}
        aria-valuenow={@value_now}
        aria-valuemin="0"
        aria-valuemax={@value_max}
      >
        <div
          class={"h-full rounded-xs transition-[width] duration-[340ms] ease-out " <> fill_class(@status)}
          style={"width: #{format_value(@pct)}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  # Nominal reads as the neon ramp; anything else goes flat in its hue so the
  # colour is unambiguous at a glance across a wall of these.
  defp fill_class(:up), do: "bg-[var(--grad-neon-bar)]"
  defp fill_class(status), do: dot_class(status)

  @doc """
  One decimal place, and no trailing `.0`. Fleet readings are noisy enough
  that more precision is false confidence, and a column of `93.5` / `7` reads
  better than `93.5` / `7.0`.
  """
  @spec format_value(number()) :: String.t()
  def format_value(value) do
    rounded = round(value * 10)
    whole = div(rounded, 10)
    tenth = abs(rem(rounded, 10))

    if tenth == 0, do: Integer.to_string(whole), else: "#{whole}.#{tenth}"
  end
end
