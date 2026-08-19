defmodule BinnacleWeb.Ui.Status do
  @moduledoc """
  Fleet health, as a closed set — and the one place that decides what each
  state looks like.

  Governing: ADR-0002 (StumpCloud fleet taxonomy).

  binnacle renders the same four states at every level of the taxonomy: a site,
  a host, a VM and a container are all "up, degraded, down, or not answering".
  The mapping lives here once:

      Up        ●  mint    the ANSI "go" colour
      Degraded  ▲  gold    the design system's warning role
      Down      ✗  coral   the danger role
      Unknown   ○  dim     absence of signal, deliberately not a colour

  `:unknown` being grey rather than red is a real distinction: "the probe did
  not answer" is not "the host is down", and colouring them alike would
  manufacture outages out of monitoring gaps.

  Glyphs, not icons: the design system's iconography is Unicode rendered in the
  mono font, so status survives a copy-paste into Signal or a terminal and stays
  legible to anyone who cannot separate the hues.
  """

  @type t :: :up | :degraded | :down | :unknown

  @all [:up, :degraded, :down, :unknown]

  @spec all() :: [t()]
  def all, do: @all

  @spec glyph(t()) :: String.t()
  def glyph(:up), do: "●"
  def glyph(:degraded), do: "▲"
  def glyph(:down), do: "✗"
  def glyph(:unknown), do: "○"

  @doc "Lowercase, matching the design system's voice."
  @spec label(t()) :: String.t()
  def label(:up), do: "up"
  def label(:degraded), do: "degraded"
  def label(:down), do: "down"
  def label(:unknown), do: "unknown"

  @doc """
  Parse a stored or wire value. Returns `:error` rather than defaulting, so
  "no value" and "unknown" stay distinguishable at the call site.
  """
  @spec from_string(String.t()) :: {:ok, t()} | :error
  def from_string("up"), do: {:ok, :up}
  def from_string("degraded"), do: {:ok, :degraded}
  def from_string("down"), do: {:ok, :down}
  def from_string("unknown"), do: {:ok, :unknown}
  def from_string(_), do: :error

  @doc "Foreground colour utility; compiles to `var(--role-*)` tokens."
  @spec text_class(t()) :: String.t()
  def text_class(:up), do: "text-ok"
  def text_class(:degraded), do: "text-warn"
  def text_class(:down), do: "text-danger"
  def text_class(:unknown), do: "text-dim"

  @doc "Background utility for a filled dot or bar segment."
  @spec dot_class(t()) :: String.t()
  def dot_class(:up), do: "bg-ok"
  def dot_class(:degraded), do: "bg-warn"
  def dot_class(:down), do: "bg-danger"
  def dot_class(:unknown), do: "bg-dim"

  @doc "A low-alpha wash for a whole row or cell, via `color-mix`."
  @spec tint_class(t()) :: String.t()
  def tint_class(:up), do: "bg-ok/10"
  def tint_class(:degraded), do: "bg-warn/10"
  def tint_class(:down), do: "bg-danger/10"
  def tint_class(:unknown), do: "bg-dim/10"
end
