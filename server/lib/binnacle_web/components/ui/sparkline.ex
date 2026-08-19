defmodule BinnacleWeb.Ui.Sparkline do
  @moduledoc """
  The trend line — a small SVG polyline drawn from a metric's history.

  Governing: ADR-0005 (hardware metrics over time). A sparkline is the trend
  companion to `Ui.Meter`'s now-reading: the meter says what it is, the
  sparkline says where it is going.

  Drawn dim by default — a wall of sparklines should read as texture, not as
  N competing charts — with the line taking the status hue only when the
  metric is outside nominal, which `Ui.Meter.status_for/2` already decides.

  Pure geometry: the points are computed here from the series and the box,
  so it renders identically on the server (first paint, no JS) and after
  every patch.
  """

  use Phoenix.Component

  import BinnacleWeb.Ui.Meter, only: [status_for: 2]

  attr :series, :list,
    required: true,
    doc: "Number-or-nil list, oldest first; nils (no signal) create gaps."

  attr :label, :string, required: true
  attr :width, :integer, default: 120
  attr :height, :integer, default: 28
  attr :max, :float, default: 100.0
  attr :warn, :float, required: true
  attr :danger, :float, required: true
  attr :class, :string, default: ""

  def sparkline(assigns) do
    assigns =
      assign(assigns,
        segments: segments(assigns.series, assigns.width, assigns.height, assigns.max),
        status: status_at(assigns.series, assigns.warn, assigns.danger),
        last: last_value(assigns.series)
      )

    ~H"""
    <svg
      viewBox={"0 0 #{@width} #{@height}"}
      fill="none"
      class={[@class]}
      role="img"
      aria-label={aria_label(@label, @last)}
    >
      <polyline
        :for={segment <- @segments}
        points={format_points(segment)}
        class={stroke_class(@status)}
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  defp aria_label(label, last) do
    reading = if last, do: Float.round(last * 1.0, 1), else: "unknown"
    "#{label} trend, latest #{reading}"
  end

  # Nil readings break the line rather than interpolating across a monitoring
  # gap — a flat line through missing data would invent an outage or hide one.
  defp segments(series, width, height, max) do
    n = length(series)
    x_step = if n <= 1, do: 0.0, else: width / (n - 1)

    series
    |> Enum.with_index()
    |> split_runs(fn {value, _} -> is_number(value) end)
    |> Enum.map(fn run ->
      Enum.map(run, fn {value, index} ->
        {Float.round(index * x_step * 1.0, 1),
         Float.round((height - height * clamp01(value / max)) * 1.0, 1)}
      end)
    end)
  end

  defp split_runs(list, keep?) do
    {runs, current} =
      Enum.reduce(list, {[], []}, fn element, {runs, current} ->
        if keep?.(element) do
          {runs, [element | current]}
        else
          if current == [] do
            {runs, []}
          else
            {[current | runs], []}
          end
        end
      end)

    runs = if current == [], do: runs, else: [current | runs]

    runs |> Enum.reverse() |> Enum.map(&Enum.reverse/1)
  end

  defp status_at(series, warn, danger) do
    case last_value(series) do
      nil -> :unknown
      value -> status_for(%{warn: warn, danger: danger}, value)
    end
  end

  defp last_value(series) do
    series
    |> Enum.reverse()
    |> Enum.find(&is_number/1)
  end

  # Nominal is quiet texture; outside nominal the line speaks in its hue.
  defp stroke_class(:up), do: "stroke-current text-line-bright opacity-60"
  defp stroke_class(:degraded), do: "stroke-current text-warn"
  defp stroke_class(:down), do: "stroke-current text-danger"
  defp stroke_class(:unknown), do: "stroke-current text-dim"

  defp format_points(points) do
    Enum.map_join(points, " ", fn {x, y} -> "#{x},#{y}" end)
  end

  defp clamp01(v) when v < 0, do: 0.0
  defp clamp01(v) when v > 1, do: 1.0
  defp clamp01(v), do: v / 1
end
