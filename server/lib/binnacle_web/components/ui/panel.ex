defmodule BinnacleWeb.Ui.Panel do
  @moduledoc """
  The card: a Lip Gloss rounded box, translated to the browser dialect.

  Governing: ADR-0004 (Tailwind v4 + daisyUI).

  Composition per the design system: `--bg-surface` fill, a hairline `--line`
  border, `--radius-md` corners, and a subtle purple top-gradient that fakes
  light falling on a raised panel. Elevation is glow, not blur-shadow: a drop
  shadow would read as web-app chrome and break the terminal metaphor.
  """

  use Phoenix.Component

  defp surface_class do
    "relative overflow-hidden rounded-md border border-line bg-surface bg-[linear-gradient(180deg,var(--tint-primary),transparent_120px)] transition-[border-color,box-shadow] duration-200 ease-out"
  end

  attr :title, :string, default: nil
  attr :eyebrow, :string, default: nil

  attr :accent, :string,
    default: nil,
    doc:
      "Optional hue for a 2px top rail — marks a non-nominal panel without recolouring the card."

  slot :inner_block, required: true

  def view(assigns) do
    ~H"""
    <section class={[surface_class()]}>
      <%= if @accent do %>
        <div class={"absolute inset-x-0 top-0 h-0.5 bg-#{@accent}"}></div>
      <% end %>
      <%= if @title || @eyebrow do %>
        <div class="flex flex-col gap-1 border-b border-line-dim px-5 py-4">
          <%= if @eyebrow do %>
            <span class="font-pixel text-2xs uppercase tracking-[0.18em] text-dim">// {@eyebrow}</span>
          <% end %>
          <%= if @title do %>
            <h3 class="font-display text-md font-bold text-bright">{@title}</h3>
          <% end %>
        </div>
      <% end %>
      <div class="px-5 py-4">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
