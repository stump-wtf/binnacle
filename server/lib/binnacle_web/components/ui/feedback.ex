defmodule BinnacleWeb.Ui.Feedback do
  @moduledoc """
  Spinners, the block cursor, and the help footer.

  Governing: ADR-0004 (glyphs are the icon set).

  Spinners cycle glyph frames; they do not rotate an SVG. The frame is a
  function of the tick counter held in the LiveView, which keeps every spinner
  on screen in lockstep off one tick, instead of each drifting on its own CSS
  animation clock.

  The block cursor blinks hard on/off at `steps(1)` via the `cursor-block`
  utility in `theme.css`, so it keeps beating while the LiveView is idle. The
  help footer is load-bearing per the design system: every screen ends in a
  dim row of `key action` pairs joined by bullets.
  """

  use Phoenix.Component

  @braille ~w(⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷)
  @dots ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  @moon ~w(🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘)

  @doc "The Bubbles default — dense, fast, unobtrusive."
  def braille, do: @braille

  @doc "Lighter weight; better next to small text."
  def dots, do: @dots

  @doc "The one place the design system sanctions emoji, because Bubbles ships this spinner."
  def moon, do: @moon

  @doc """
  Pick the frame for a tick. Wraps with `rem/2`, so the caller's counter can
  increment forever. Returns `"⠿"` for an empty frame list rather than
  crashing — a spinner is never important enough to take the page down.
  """
  @spec spinner_frame([String.t()], non_neg_integer()) :: String.t()
  def spinner_frame([], _tick), do: "⠿"

  def spinner_frame(frames, tick) do
    Enum.at(frames, rem(tick, length(frames)), "⠿")
  end

  attr :frames, :list, required: true
  attr :tick, :integer, required: true
  attr :label, :string, required: true

  def spinner(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2 font-mono text-sm text-muted" role="status">
      <span class="text-neon-cyan" aria-hidden="true">
        {spinner_frame(@frames, @tick)}
      </span>
      {@label}
    </span>
    """
  end

  @doc "The blinking block cursor. Decorative, hidden from the accessibility tree."
  def cursor(assigns) do
    ~H"""
    <span class="cursor-block" aria-hidden="true"></span>
    """
  end

  attr :pairs, :list,
    required: true,
    doc: "List of %{key: key, action: action} maps — the help footer's `key action` pairs."

  def key_hint(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-1 gap-y-1 font-mono text-xs">
      <span
        :for={{pair, index} <- Enum.with_index(@pairs)}
        class="inline-flex items-center gap-1.5"
      >
        <%= if index > 0 do %>
          <span class="px-1 text-line-bright">•</span>
        <% end %>
        <kbd class="font-mono font-bold text-charm-pink">{pair[:key]}</kbd>
        <span class="text-dim">{pair[:action]}</span>
      </span>
    </div>
    """
  end
end
