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
    @moduledoc """
    A property: a home or an Airbnb, with a UniFi gateway and the hosts
    standing in it. `kind` is exactly one of `:home` / `:airbnb`.

    A site is **declared**, never discovered (SPEC-0001 REQ "Discovery Does Not
    Invent Topology"). Each property runs its own UniFi controller and every
    one of them reports a single site named "default", so the API can confirm
    that a gateway answers but can never say which property it is standing in.
    `slug` and `kind` come from config; `name` is the human label for the
    property, also from config.

    `network` is what UniFi contributes: the gateway's reachability and the
    device inventory behind it. It is `nil` until the first poll, and
    `%Network{reachable: false}` when the controller stops answering — never
    silently absent.

    `status` and `drift` are what `Fleet.build_snapshot/1` computes for the
    property: its worst-host-plus-gateway rollup, and the config drift
    attributed to it. Both are declared fields with defaults rather than keys
    the snapshot grafts on with `Map.merge/2`. `SiteJSON` and `FleetLive` read
    `site.status` and `site.drift` directly, and on a `%Site{}` built anywhere
    other than `build_snapshot/1` an undeclared key is a `KeyError` at render
    time — not the `nil` those callers are written to handle.
    """
    defstruct [:slug, :kind, :name, :hosts, :network, status: :unknown, drift: []]
  end

  defmodule Network do
    @moduledoc """
    A site's network as UniFi reports it: whether the controller answered,
    when, and the devices it lists.

    `reachable: false` carries `reason` so a site that has lost its gateway
    says why rather than rendering as an empty inventory, which is what an
    unconfigured site also looks like.
    """
    defstruct [:reachable, :reason, :at, :gateway, devices: []]
  end

  defmodule NetworkDevice do
    @moduledoc """
    One UniFi-managed device: the gateway, a switch, an access point.

    `kind` is normalized from UniFi's `type` field. `adopted` and `state`
    are reported as UniFi gives them; a device the controller lists but has
    not adopted is inventory, not an outage.
    """
    defstruct [:mac, :name, :model, :kind, :status, :adopted, :version, :uptime]
  end

  defmodule Host do
    @moduledoc "A Proxmox hardware host (or standalone box) belonging to exactly one site."
    defstruct [:key, :site, :dial_ip, :guests, :hardware, :status, :history]
  end

  defmodule Guest do
    @moduledoc """
    A VM or LXC container. Identity is `"vmid@host"` — unique across standalone
    hypervisors that may share vmid numbers. Re-parents (migration) by changing
    `host`.
    """
    defstruct [:vmid, :host, :name, :containers, :hardware, :status]

    @type t :: %__MODULE__{}

    @doc "The composite guest reference: `\"vmid@host\"`."
    @spec ref(t()) :: String.t()
    def ref(%__MODULE__{vmid: vmid, host: host}), do: "#{vmid}@#{host}"
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

  defmodule Disk do
    @moduledoc """
    A physical disk on a hypervisor, with SMART health and key attributes
    (ADR-0005, issue #69).

    `health` is the SMART overall verdict: `:passed`, `:failed`, or `:unknown`.
    `attributes` holds the raw SMART counters that matter for imminent failure
    detection — `reallocated`, `pending`, `uncorrectable`, `crc_errors`,
    `command_timeout`, `power_on_hours`. `temperature` is °C or nil.

    Two of those counters alert on **movement**, not on their absolute value:
    `crc_errors` and `command_timeout` are lifetime totals, so a drive carrying
    scars from a cable replaced years ago would alert forever. `DiskPoller`
    stamps each reading with `:crc_delta` and `:cmd_delta` — how far each moved
    since that drive's previous poll — and `disk_status/1` keys on those. The
    first sighting of a drive is a baseline, not an indictment.

    `pending` and `uncorrectable` alert on the absolute value instead, because
    any non-zero reading there is a sector the drive could not read *now*.
    `reallocated` and `power_on_hours` are carried for display only; neither
    feeds the status roll-up.
    """
    defstruct [
      :device,
      :model,
      :serial,
      :size,
      :type,
      :health,
      :temperature,
      :attributes,
      :wearout
    ]

    @type health :: :passed | :failed | :unknown
    @type t :: %__MODULE__{}
  end

  defmodule ZfsPool do
    @moduledoc """
    A ZFS pool on a hypervisor, with state and per-vdev error counters
    (ADR-0005, issue #69).

    `state` is `:online`, `:degraded`, `:faulted`, `:suspended`, or `:unknown`.
    `errors` is the `errors:` line from `zpool status` — "No known data
    errors" vs anything else. `scan` carries scrub/resilver progress if active.
    `vdevs` is a flat list of vdev entries with `read`/`write`/`cksum` error
    counts.
    """
    defstruct [
      :name,
      :state,
      :size,
      :allocated,
      :free,
      :fragmentation,
      :errors,
      :scan,
      :vdevs
    ]

    @type t :: %__MODULE__{}
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

  A parent with **no children** is `:unknown`, not `:up`. A site with no hosts
  (Cornell Ave is a gateway and nothing else) has had nothing measured, and
  reporting it green is a claim binnacle cannot support — the same fabrication
  as inventing a metric for a host with no telemetry source.
  """
  @spec roll_up([status()]) :: status()
  def roll_up([]), do: :unknown

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

  @doc """
  A sample's overall health, using the per-metric thresholds from Ui.Meter
  semantics.

  A saturated metric is `:degraded`, never `:down`. `:down` means the thing
  is not answering; a host that reports 92% memory answered, and answered
  with a number. ADR-0005: "status colour must stay honest ... a monitoring
  gap is not an outage" — and neither is a full cache.

  This mattered the moment real readings arrived: lir and ogma both run ZFS,
  whose ARC deliberately occupies most of RAM, so both sat at ~90% memory and
  the overview rendered two healthy hypervisors as DOWN. Threshold crossings
  are what the meter hues are for; the status chip is for whether the thing
  is there.
  """
  @spec sample_status(Sample.t()) :: status()
  def sample_status(sample) do
    sample
    |> metrics()
    |> Enum.map(fn {value, warn, _danger} ->
      if value >= warn, do: :degraded, else: :up
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

  @doc """
  A disk's health status from its SMART verdict and key attributes.

  - `:failed` SMART → `:down` — the drive has failed its self-test.
  - `Current_Pending_Sector` or `Offline_Uncorrectable` > 0 → `:degraded` —
    imminent media failure, but the drive is still answering.
  - `UDMA_CRC_Error_Count` or `Command_Timeout` increasing since the drive's
    previous poll (`:crc_delta` / `:cmd_delta` > 0, stamped by `DiskPoller`) →
    `:degraded` — cable/link degrading.
  - Temperature > 50 °C → `:degraded` (Exos X18 rated to 60 °C).
  - Otherwise → `:up`.

  A pool not ONLINE or with non-zero vdev errors → `:degraded` or `:down`.
  """
  @spec disk_status(Disk.t()) :: status()
  def disk_status(%Disk{health: :failed}), do: :down

  def disk_status(%Disk{health: :unknown}), do: :unknown

  def disk_status(%Disk{attributes: attrs, temperature: temp}) do
    pending = attrs[:pending] || 0
    uncorrectable = attrs[:uncorrectable] || 0
    crc_delta = attrs[:crc_delta] || 0
    cmd_delta = attrs[:cmd_delta] || 0

    cond do
      pending > 0 or uncorrectable > 0 -> :degraded
      crc_delta > 0 or cmd_delta > 0 -> :degraded
      is_number(temp) and temp > 50 -> :degraded
      true -> :up
    end
  end

  def disk_status(_), do: :unknown

  @doc """
  A ZFS pool's health status from its state and vdev errors.

  - `:faulted` or `:suspended` → `:down` — the pool is not operational.
  - `:degraded` → `:degraded` — running but with failed vdevs.
  - Any non-zero vdev error counter → `:degraded`.
  - `:online` with zero errors → `:up`.
  """
  @spec pool_status(ZfsPool.t()) :: status()
  def pool_status(%ZfsPool{state: :faulted}), do: :down
  def pool_status(%ZfsPool{state: :suspended}), do: :down
  def pool_status(%ZfsPool{state: :degraded}), do: :degraded
  def pool_status(%ZfsPool{state: :unknown}), do: :unknown

  def pool_status(%ZfsPool{vdevs: vdevs}) do
    total_errors =
      Enum.reduce(vdevs || [], 0, fn vdev, acc ->
        acc + (vdev[:read] || 0) + (vdev[:write] || 0) + (vdev[:cksum] || 0)
      end)

    if total_errors > 0, do: :degraded, else: :up
  end

  def pool_status(_), do: :unknown
end
