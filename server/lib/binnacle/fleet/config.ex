defmodule Binnacle.Fleet.Config do
  @moduledoc """
  Baseline fleet config, loaded from JSON and validated fail-fast
  (SPEC-0001).

  Startup fails with an error naming the offender on: a duplicate site slug,
  a host referencing an unknown site, a missing or invalid site kind, or more
  than one Home Assistant reference per site. Credentials declared in the
  config are parsed but never rendered, logged, or returned by the snapshot
  API — the UI and API see the model, not the config.
  """

  alias Binnacle.Fleet.Model
  alias Model.{Container, Guest, HardwareDevice, Host, Site}

  @enforce_keys [:sites, :hosts, :guests, :containers, :hardware, :proxmox]
  defstruct [:sites, :hosts, :guests, :containers, :hardware, :proxmox]

  @type t :: %__MODULE__{
          sites: [Site.t()],
          hosts: [Host.t()],
          guests: [Guest.t()],
          containers: [Container.t()],
          hardware: %{optional(String.t() | integer()) => [HardwareDevice.t()]},
          proxmox: %{optional(String.t()) => proxmox_config()}
        }

  @type proxmox_config :: %{
          base_url: String.t(),
          token: String.t(),
          poll_ms: non_neg_integer()
        }

  @kinds ~w(home airbnb)
  @device_kinds ~w(cpu gpu disk sensor)

  @doc "Load and validate a baseline config from a JSON file path."
  @spec load!(Path.t()) :: t()
  def load!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> new!()
  end

  @doc "Validate and build a config from a decoded JSON map."
  @spec new!(map()) :: t()
  def new!(%{"sites" => sites, "hosts" => hosts} = config) do
    proxmox = proxmox_configs(hosts)
    guests = Map.get(config, "guests", [])
    containers = Map.get(config, "containers", [])
    hardware = Map.get(config, "hardware", [])

    site_slugs = Enum.map(sites, & &1["slug"])
    validate_unique_slugs!(site_slugs)
    validate_kinds!(sites)

    host_keys = Enum.map(hosts, &host_key/1)
    validate_host_membership!(hosts, MapSet.new(site_slugs))

    guest_ids = Enum.map(guests, & &1["vmid"])
    validate_unique_guests!(guest_ids)
    validate_guest_membership!(guests, MapSet.new(host_keys))
    validate_container_membership!(containers, MapSet.new(guest_ids))

    nodes = MapSet.union(MapSet.new(host_keys), MapSet.new(guest_ids))

    %__MODULE__{
      sites: Enum.map(sites, &site/1),
      hosts: Enum.map(hosts, &host/1),
      guests: Enum.map(guests, &guest/1),
      containers: Enum.map(containers, &container/1),
      hardware: group_hardware(hardware, nodes),
      proxmox: proxmox
    }
  end

  def new!(other),
    do:
      raise(
        ArgumentError,
        "baseline config must be a map with sites and hosts, got: #{inspect(other)}"
      )

  # Optional per-host Proxmox API access (SPEC-0001 REQ proxmox). A host
  # entry may declare "proxmox": {"url": ..., "token": ..., "poll_seconds": n}
  # — both url and token are required when the block is present. Tokens are
  # parsed here and live only in this struct; they are never rendered,
  # logged, or reachable through the snapshot.
  defp proxmox_configs(hosts) do
    hosts
    |> Enum.flat_map(fn host ->
      case host["proxmox"] do
        nil ->
          []

        %{"url" => url, "token" => token} = block ->
          poll_ms = Map.get(block, "poll_seconds", 30) * 1000
          [{host_key(host), %{base_url: url, token: token, poll_ms: poll_ms}}]

        block ->
          raise ArgumentError,
                "host #{host_key(host)} has an incomplete proxmox block #{inspect(Map.keys(block || %{}))} (url and token are required)"
      end
    end)
    |> Map.new()
  end

  defp validate_unique_slugs!(slugs) do
    case Enum.find(Enum.frequencies(slugs), fn {_slug, n} -> n > 1 end) do
      nil -> :ok
      {slug, _} -> raise ArgumentError, "duplicate site slug in baseline config: #{slug}"
    end
  end

  defp validate_kinds!(sites) do
    Enum.each(sites, fn site ->
      unless site["kind"] in @kinds do
        raise ArgumentError,
              "site #{site["slug"]} has missing or invalid kind #{inspect(site["kind"])} (expected one of #{inspect(@kinds)})"
      end
    end)
  end

  defp validate_host_membership!(hosts, slugs) do
    Enum.each(hosts, fn host ->
      unless host["site"] in slugs do
        raise ArgumentError,
              "host #{host_key(host)} references unknown site #{inspect(host["site"])}"
      end
    end)
  end

  defp validate_unique_guests!(ids) do
    case Enum.find(Enum.frequencies(ids), fn {_id, n} -> n > 1 end) do
      nil -> :ok
      {id, _} -> raise ArgumentError, "duplicate guest vmid in baseline config: #{id}"
    end
  end

  defp validate_guest_membership!(guests, host_keys) do
    Enum.each(guests, fn guest ->
      unless guest["host"] in host_keys do
        raise ArgumentError,
              "guest #{guest["vmid"]} references unknown host #{inspect(guest["host"])}"
      end
    end)
  end

  defp validate_container_membership!(containers, guest_ids) do
    Enum.each(containers, fn container ->
      unless container["guest"] in guest_ids do
        raise ArgumentError,
              "container #{container["name"]} references unknown guest #{inspect(container["guest"])}"
      end
    end)
  end

  defp host_key(%{"key" => key}), do: key

  defp site(%{"slug" => slug, "kind" => kind}) do
    %Site{slug: slug, kind: site_kind(kind), hosts: []}
  end

  defp site_kind(kind) when kind in @kinds, do: String.to_atom(kind)

  defp site_kind(kind),
    do:
      raise(
        ArgumentError,
        "invalid site kind #{inspect(kind)} (expected one of #{inspect(@kinds)})"
      )

  defp host(%{"key" => key, "site" => site} = entry) do
    %Host{
      key: key,
      site: site,
      dial_ip: entry["dial_ip"],
      guests: [],
      hardware: [],
      status: :unknown,
      history: []
    }
  end

  defp guest(%{"vmid" => vmid, "host" => host, "name" => name}) do
    %Guest{vmid: vmid, host: host, name: name, containers: [], hardware: [], status: :unknown}
  end

  defp container(%{"id" => id, "guest" => guest, "name" => name}) do
    %Container{id: id, guest: guest, name: name, status: :unknown}
  end

  defp device_kind(kind) when kind in @device_kinds, do: String.to_atom(kind)

  defp device_kind(kind),
    do:
      raise(
        ArgumentError,
        "hardware has invalid kind #{inspect(kind)} (expected one of #{inspect(@device_kinds)})"
      )

  defp group_hardware(entries, nodes) do
    entries
    |> Enum.map(fn %{"node" => node} = entry ->
      device = %HardwareDevice{
        name: entry["name"],
        kind: device_kind(entry["kind"]),
        model: entry["model"],
        passthrough: Map.get(entry, "passthrough", false),
        smart: Map.get(entry, "smart")
      }

      {node, device}
    end)
    |> Enum.group_by(fn {node, _} -> node end, fn {_, device} -> device end)
    |> Map.new(fn {node, devices} ->
      unless MapSet.member?(nodes, node) do
        raise ArgumentError,
              "hardware \"#{hd(devices).name}\" references unknown node #{inspect(node)}"
      end

      {node, devices}
    end)
  end
end
