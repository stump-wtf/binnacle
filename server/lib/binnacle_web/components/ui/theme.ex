defmodule BinnacleWeb.Ui.Theme do
  @moduledoc """
  The two palettes the Bubbletea design system ships, as a type.

  Governing: ADR-0004 (Elixir full-stack; Tailwind v4 + daisyUI as the CSS
  layer).

  The whole theming mechanism is one attribute: `data-theme` on `<html>`. Both
  the design tokens (`[data-theme="day"]` re-points every custom property) and
  daisyUI (which switches components on the same attribute) read it, which is
  why this module never touches a colour. It owns the *name* and the persistence
  key; CSS owns everything the name means.
  """

  @type t :: :night | :day

  @doc "Every theme, in the order a picker should offer them."
  @spec all() :: [t()]
  def all, do: [:night, :day]

  @doc """
  The attribute value. These two strings are a contract with three other
  places — the layout's bootstrap script, the `[data-theme="day"]` scope in
  `tokens/colors.css`, and the daisyUI theme names in `theme.css`. Changing
  one without the others silently half-applies a theme.
  """
  @spec to_string(t()) :: String.t()
  def to_string(:night), do: "night"
  def to_string(:day), do: "day"

  @doc """
  Parse a stored or attribute value. Returns `:error` rather than defaulting
  to night, because "no stored choice" and "stored night" must stay
  distinguishable: a user who has never chosen should keep following their OS
  preference.
  """
  @spec from_string(String.t()) :: {:ok, t()} | :error
  def from_string("night"), do: {:ok, :night}
  def from_string("day"), do: {:ok, :day}
  def from_string(_), do: :error

  @doc "Human-facing name for a toggle or menu."
  @spec label(t()) :: String.t()
  def label(:night), do: "night"
  def label(:day), do: "day"

  @doc "The other theme. With exactly two, a toggle is total."
  @spec toggle(t()) :: t()
  def toggle(:night), do: :day
  def toggle(:day), do: :night

  @doc """
  `localStorage` key. App-scoped rather than the design system's own
  `btds-theme`: binnacle and any other Bubbletea-styled surface on
  `*.pages.stump.rocks` share an origin, so a shared key would make one app's
  toggle silently retheme the other. Must match the layout's bootstrap script.
  """
  @spec storage_key() :: String.t()
  def storage_key, do: "binnacle-theme"
end
