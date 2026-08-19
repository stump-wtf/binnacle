defmodule Binnacle.Fleet.Model do
  @moduledoc """
  The four-level containment spine: Site → Host → Guest → Container
  (ADR-0002, SPEC-0001).

  Every entity other than Site references exactly one parent; hosts never span
  sites, and guests and containers never span parents. Hardware devices attach
  to exactly one node — a Host or a Guest — and their metrics are attributed
  to the owner.
  """

  defmodule Site do
    @moduledoc "A home or Airbnb with a UniFi gateway. `kind` is exactly one of `:home` / `:airbnb`."
    defstruct [:slug, :kind, :hosts]
  end

  defmodule Host do
    @moduledoc "A Proxmox hardware host (or standalone box) belonging to exactly one site."
    defstruct [:key, :site, :dial_ip, :guests, :hardware, :status, :history]
  end

  defmodule Guest do
    @moduledoc "A VM. Re-parents (migration) by changing `host`; identity is `vmid`."
    defstruct [:vmid, :host, :name, :containers, :hardware, :status]
  end

  defmodule Container do
    @moduledoc "A Docker container — the leaf of the taxonomy."
    defstruct [:id, :guest, :name, :status]
  end

  defmodule HardwareDevice do
    @moduledoc """
    A physical device attached to one node. `kind` is `:cpu`, `:gpu`, `:disk`,
    `:sensor`, ...; `passthrough` marks a host device handed to a guest, whose
    metrics then belong to the guest.
    """
    defstruct [:name, :kind, :model, :passthrough, :smart]
  end

  defmodule Sample do
    @moduledoc """
    One point in time for one node. Percentages are 0–100 floats;
    temperatures are °C. `at` is the wall clock the sample was taken.
    """
    defstruct [:at, :cpu, :gpu, :memory, :disk, :cpu_temp, :gpu_temp, :hdd_temp]
  end

  @type status :: :up | :degraded | :down | :unknown

  @doc """
  Roll up child statuses into a parent's: a parent is as bad as its worst
  child — except `:unknown` children, which never promote the parent past
  `:up`. Absence of signal is not an outage; only a parent with no known
  children at all is itself `:unknown`.
  """
  @spec roll_up([status()]) :: status()
  def roll_up([]), do: :up

  def roll_up(statuses) do
    case Enum.reject(statuses, &(&1 == :unknown)) do
      [] -> :unknown
      known -> Enum.min_by(known, &rank/1)
    end
  end

  defp rank(:down), do: 0
  defp rank(:degraded), do: 1
  defp rank(:unknown), do: 2
  defp rank(:up), do: 3

  @doc "A sample's overall health, using the per-metric thresholds from Ui.Meter semantics."
  @spec sample_status(Sample.t()) :: status()
  def sample_status(sample) do
    sample
    |> metrics()
    |> Enum.map(fn {value, warn, danger} ->
      cond do
        value >= danger -> :down
        value >= warn -> :degraded
        true -> :up
      end
    end)
    |> roll_up()
  end

  defp metrics(%Sample{} = s) do
    [
      {s.cpu || 0, 80, 95},
      {s.gpu || 0, 80, 95},
      {s.memory || 0, 75, 90},
      {s.disk || 0, 85, 95},
      {s.cpu_temp || 0, 80, 90},
      {s.gpu_temp || 0, 80, 90},
      {s.hdd_temp || 0, 45, 55}
    ]
  end
end
