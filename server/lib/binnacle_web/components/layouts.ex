defmodule BinnacleWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality used by your
  application. The HTML skeleton lives in `layouts/root.html.heex`; this
  module carries the function components the skeleton and LiveViews share.
  """

  use BinnacleWeb, :html

  embed_templates "layouts/*"

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
