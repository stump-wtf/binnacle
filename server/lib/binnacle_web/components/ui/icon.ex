defmodule BinnacleWeb.Ui.Icon do
  @moduledoc """
  UI icons — the Lucide frame, plus a hand-written starter set.

  Governing: ADR-0004. The frame is what every Lucide icon shares: 24×24
  viewBox, `fill="none"`, `stroke="currentColor"`, 2px stroke, round caps and
  joins. The path data is copied verbatim from `lucide-static` v1.31.0 (ISC).

  `currentColor` is the load-bearing part of the frame: an icon inherits
  `text-ok` / `text-danger` from its container, so the status hues apply to
  icons with no per-icon colour handling at all.
  """

  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  attr :name, :atom,
    required: true,
    values: [
      :site,
      :host,
      :container,
      :cpu,
      :thermometer,
      :hard_drive,
      :activity,
      :refresh,
      :box,
      :map_pin,
      :server
    ]

  attr :class, :string,
    default: "size-4",
    doc: "Size comes from the class (`size-4`, `size-5`), not a width attribute."

  def icon(assigns) do
    assigns = assign(assigns, :paths, raw(glyph(assigns.name)))

    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      aria-hidden="true"
    >
      {@paths}
    </svg>
    """
  end

  # FLEET TAXONOMY (ADR-0002) — aliases naming the four levels of the taxonomy,
  # so view code reads `name={:host}` rather than naming the Lucide glyph.
  defp glyph(:site), do: glyph(:map_pin)
  defp glyph(:host), do: glyph(:server)
  defp glyph(:container), do: glyph(:box)

  defp glyph(:server) do
    ~S(<rect width="20" height="8" x="2" y="2" rx="2" ry="2"/><rect width="20" height="8" x="2" y="14" rx="2" ry="2"/><line x1="6" x2="6.01" y1="6" y2="6"/><line x1="6" x2="6.01" y1="18" y2="18"/>)
  end

  defp glyph(:box) do
    ~S(<path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"/><path d="m3.3 7 8.7 5 8.7-5"/><path d="M12 22V12"/>)
  end

  defp glyph(:map_pin) do
    ~S(<path d="M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0"/><circle cx="12" cy="10" r="3"/>)
  end

  defp glyph(:cpu) do
    ~S(<path d="M12 20v2"/><path d="M12 2v2"/><path d="M17 20v2"/><path d="M17 2v2"/><path d="M2 12h2"/><path d="M2 17h2"/><path d="M2 7h2"/><path d="M20 12h2"/><path d="M20 17h2"/><path d="M20 7h2"/><path d="M7 20v2"/><path d="M7 2v2"/><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="8" y="8" width="8" height="8" rx="1"/>)
  end

  defp glyph(:thermometer) do
    ~S(<path d="M14 4v10.54a4 4 0 1 1-4 0V4a2 2 0 0 1 4 0Z"/>)
  end

  defp glyph(:hard_drive) do
    ~S(<path d="M10 16h.01"/><path d="M2.212 11.577a2 2 0 0 0-.212.896V18a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-5.527a2 2 0 0 0-.212-.896L18.55 5.11A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><path d="M21.946 12.013H2.054"/><path d="M6 16h.01"/>)
  end

  defp glyph(:activity) do
    ~S(<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2"/>)
  end

  defp glyph(:refresh) do
    ~S(<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>)
  end
end
