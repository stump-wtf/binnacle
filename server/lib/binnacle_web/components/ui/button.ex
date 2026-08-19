defmodule BinnacleWeb.Ui.Button do
  @moduledoc """
  Buttons.

  Governing: ADR-0004 (Tailwind v4 + daisyUI; classes as plain strings).

  Built on daisyUI's `btn` so the interaction states, disabled handling and
  sizing scaffolding come from the framework, with the Bubbletea treatment on
  top: mono type, hairline border, and — because this is the design system's
  browser dialect — a spring lift plus neon bloom on hover. No colour literals
  and no `dark:` variants: `btn-primary` resolves through the daisyUI theme
  blocks in `theme.css`, which resolve to the design tokens, which flip on
  `data-theme`.
  """

  use Phoenix.Component

  defp base_class do
    Enum.join(
      [
        "btn font-mono font-bold tracking-wide normal-case rounded-md",
        "transition-[transform,box-shadow,background-color,border-color]",
        "duration-[120ms] ease-spring hover:-translate-y-px",
        "active:translate-y-0 disabled:opacity-40 disabled:hover:translate-y-0"
      ],
      " "
    )
  end

  attr :variant, :atom, default: :primary, values: [:primary, :secondary, :ghost, :danger]
  attr :size, :atom, default: :medium, values: [:small, :medium, :large]
  attr :label, :string, required: true

  attr :rest, :global,
    include: ~w(disabled form name type value phx-click phx-value-*),
    doc: "Arbitrary attributes, including `phx-click`. Absent `phx-click` renders disabled."

  def view(assigns) do
    ~H"""
    <button
      {@rest}
      class={[base_class(), variant_class(@variant), size_class(@size), glow_class(@variant)]}
    >
      {@label}
    </button>
    """
  end

  defp variant_class(:primary), do: "btn-primary"
  defp variant_class(:secondary), do: "btn-secondary"
  defp variant_class(:ghost), do: "btn-ghost border-line"
  defp variant_class(:danger), do: "btn-error"

  defp size_class(:small), do: "btn-sm text-2xs"
  defp size_class(:medium), do: "btn-sm text-xs"
  defp size_class(:large), do: "btn-md text-sm"

  # Ghost gets no bloom: a glowing quiet option is a contradiction that also
  # makes toolbars of mostly-ghost buttons twinkle.
  defp glow_class(:primary), do: "hover:shadow-glow-purple"
  defp glow_class(:secondary), do: "hover:shadow-glow-pink"
  defp glow_class(:ghost), do: ""
  defp glow_class(:danger), do: ""
end
