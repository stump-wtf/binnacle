defmodule BinnacleWeb.Ui.Table do
  @moduledoc """
  The fleet table — dense, scannable, keyboard-selectable.

  Governing: ADR-0002 (sites → hosts → VMs → containers).

  This is the primary way binnacle shows the fleet, so it is built around
  scanning a column rather than reading a row:

  - Selection is a pink inset rail plus a surface tint, mirroring the `>`
    cursor a Bubbles list draws — not a full-row highlight, which would fight
    the status hues the row carries.
  - Numeric columns are `tabular-nums` and right-aligned; proportional digits
    make a vertical scan useless because the decimal points wander.
  - Headers are dim, uppercase, wide-tracked — present but never competing.

  Columns are declared as slots so a cell can be any component — a status
  badge or a meter, which is most of the point of a fleet table.
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :empty, :string, default: "nothing here", doc: "Empty-state message."

  attr :row_id, :any,
    required: true,
    doc: "Function from row to its identity (string), for selection and DOM ids."

  attr :rows, :list, required: true

  attr :selected, :string,
    default: nil,
    doc: "The selected row's id, or nil. Rows are clickable whenever `phx-click`-bearing."

  attr :on_select, :string,
    default: nil,
    doc:
      "LiveView event name fired on row click; nil renders a readout table with no pointer affordances."

  slot :col, required: true do
    attr :label, :string, required: true
    attr :numeric, :boolean
  end

  def view(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-md border border-line bg-surface">
      <table class="w-full border-collapse" id={@id}>
        <thead class="border-b border-line bg-surface-2">
          <tr>
            <th
              :for={col <- @col}
              class={"px-3 py-2 font-mono text-2xs font-bold uppercase tracking-wide text-dim " <> align_class(Map.get(col, :numeric, false))}
            >
              {col[:label]}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []}>
            <td colspan={length(@col)} class="px-3 py-8 text-center font-mono text-sm text-dim">
              {@empty}
            </td>
          </tr>
          <tr
            :for={row <- @rows}
            id={"#{@id}-#{id_of(@row_id, row)}"}
            class={
              "border-b border-line-dim transition-[background-color] duration-[120ms] ease-out "
              |> String.trim_trailing()
              |> Kernel.<>(" " <> selection_class(selected?(@row_id, row, @selected)))
              |> Kernel.<>(" " <> interactive_class(@on_select))
            }
            phx-click={@on_select}
            phx-value-id={@on_select && id_of(@row_id, row)}
            tabindex={if @on_select, do: "0"}
            aria-selected={@on_select && to_string(selected?(@row_id, row, @selected))}
          >
            <td
              :for={col <- @col}
              class={"px-3 py-2 text-sm text-body " <> align_class(Map.get(col, :numeric, false))}
            >
              {render_slot(col, row)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp align_class(true), do: "text-right tabular-nums"
  defp align_class(false), do: "text-left"

  defp selection_class(true), do: "tint-primary rail-active"
  defp selection_class(false), do: ""

  defp interactive_class(nil), do: ""
  defp interactive_class(_), do: "cursor-pointer hover:bg-surface-3"

  defp selected?(id_fun, row, selected) when is_function(id_fun, 1),
    do: selected != nil and id_of(id_fun, row) == selected

  defp id_of(id_fun, row) when is_function(id_fun, 1), do: to_string(id_fun.(row))
end
