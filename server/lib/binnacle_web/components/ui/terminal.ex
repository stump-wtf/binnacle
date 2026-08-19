defmodule BinnacleWeb.Ui.Terminal do
  @moduledoc """
  An embedded terminal window — for genuinely terminal content only.

  Governing: ADR-0002 (containers are the leaf of the taxonomy; their logs are
  terminal output).

  The design system draws a hard line between its two dialects, and this
  component is the only place binnacle is allowed to cross it: a framed window
  on a web surface means exactly one thing — a literal embedded terminal. It is
  for `docker logs`, a `systemctl status` dump, an SSH session; it is not a
  decorative frame for a dashboard panel (that is `Ui.Panel`).

  Two consequences fall out of it being a real terminal:

  - It stays night in both themes: `data-theme="night"` is pinned on the
    frame, because a terminal emulator does not repaint its scrollback when
    the surrounding page goes light.
  - The chrome may glow; the body may not. Emphasis inside is colour and
    weight only.
  """

  use Phoenix.Component

  attr :title, :string, required: true
  attr :mode, :atom, required: true, values: [:normal, :following, :paused]
  attr :lines, :list, required: true, doc: "Plain log lines; column-aligned, never reflowed."

  def view(assigns) do
    ~H"""
    <div
      data-theme="night"
      class="overflow-hidden rounded-lg border border-line bg-terminal shadow-window font-mono text-sm"
    >
      <div class="flex items-center gap-2 border-b border-line-dim bg-surface px-3 py-2">
        <div class="flex items-center gap-1.5" aria-hidden="true">
          <span class="size-2.5 rounded-full bg-neon-coral"></span>
          <span class="size-2.5 rounded-full bg-neon-gold"></span>
          <span class="size-2.5 rounded-full bg-neon-mint"></span>
        </div>
        <span class="flex-1 text-center text-xs text-muted">{@title}</span>
        <div class="w-[42px]" aria-hidden="true"></div>
      </div>
      <div class="max-h-96 overflow-auto px-4 py-3 leading-[1.35]">
        <div :for={line <- @lines} class="whitespace-pre text-body">{line}</div>
      </div>
      <div class="flex items-stretch border-t border-line-dim bg-surface text-2xs">
        <span class={"px-2.5 py-1 font-bold tracking-wide " <> mode_class(@mode)}>
          {mode_label(@mode)}
        </span>
        <span class="flex-1 px-2.5 py-1 text-dim">j/k scroll • f follow • q close</span>
      </div>
    </div>
    """
  end

  defp mode_label(:normal), do: "NORMAL"
  defp mode_label(:following), do: "FOLLOWING"
  defp mode_label(:paused), do: "PAUSED"

  defp mode_class(:normal), do: "bg-charm-purple text-[var(--text-on-purple)]"
  defp mode_class(:following), do: "bg-neon-mint text-[var(--text-on-accent)]"
  defp mode_class(:paused), do: "bg-neon-gold text-[var(--text-on-accent)]"
end
