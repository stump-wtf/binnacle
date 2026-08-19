defmodule BinnacleWeb.Ui.Badge do
  @moduledoc """
  Small labels: status chips, counts, and pixel eyebrows.

  Governing: ADR-0002 (fleet taxonomy — status is rendered identically at
  every level).

  The recipe is the design system's terminal chip: a low-alpha wash of the hue,
  the hue itself as text, and a hairline border at partial alpha, written with
  `color-mix` through Tailwind's `/alpha` syntax. Square-ish (`rounded-xs`),
  never a pill — pills belong to the web dialect's larger surfaces, not to a
  status chip in a dense table.
  """

  use Phoenix.Component

  import BinnacleWeb.Ui.Status, only: [glyph: 1, label: 1, tint_class: 1, text_class: 1]

  defp base_class do
    "inline-flex items-center gap-1 px-2 py-px rounded-xs font-mono font-bold text-2xs uppercase tracking-wide border leading-relaxed whitespace-nowrap"
  end

  attr :hue, :string,
    required: true,
    doc: "Tailwind colour name from the bridge in `theme.css` — `\"ok\"`, `\"warn\"`, ..."

  attr :label, :string, required: true

  def chip(assigns) do
    ~H"""
    <span class={[base_class(), "bg-#{@hue}/15", "text-#{@hue}", "border-#{@hue}/45"]}>
      {@label}
    </span>
    """
  end

  @doc """
  The one to reach for: glyph plus lowercase label in the status hue, so the
  state is readable three ways — colour, glyph, and word — never only by colour.
  """
  attr :status, :atom, required: true, values: [:up, :degraded, :down, :unknown]

  def status(assigns) do
    ~H"""
    <span class={[base_class(), tint_class(@status), text_class(@status), "border-current/40"]}>
      <span class="not-italic">{glyph(@status)}</span>
      {label(@status)}
    </span>
    """
  end

  @doc "A neutral count — \"14 containers\". Muted on purpose: a count is context."
  attr :count, :integer, required: true
  attr :noun, :string, required: true

  def count(assigns) do
    ~H"""
    <span class={[base_class(), "bg-muted/10 text-muted border-muted/35"]}>
      {@count} {@noun}
    </span>
    """
  end

  @doc "A pixel eyebrow — `// FLEET`. Silkscreen, wide tracking, no box."
  attr :text, :string, required: true

  def eyebrow(assigns) do
    ~H"""
    <span class="font-pixel text-2xs uppercase tracking-[0.18em] text-dim">// {@text}</span>
    """
  end
end
