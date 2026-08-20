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
  alias Binnacle.Fleet.Proxmox.Token
  alias Binnacle.Fleet.Unifi.Credential
  alias Model.{Container, Guest, HardwareDevice, Host, Site}

  @enforce_keys [:sites, :hosts, :guests, :containers, :hardware, :proxmox, :unifi]
  defstruct [:sites, :hosts, :guests, :containers, :hardware, :proxmox, :unifi]

  @type t :: %__MODULE__{
          sites: [Site.t()],
          hosts: [Host.t()],
          guests: [Guest.t()],
          containers: [Container.t()],
          hardware: %{optional(String.t() | integer()) => [HardwareDevice.t()]},
          proxmox: %{optional(String.t()) => proxmox_config()},
          unifi: %{optional(String.t()) => unifi_config()}
        }

  @type proxmox_config :: %{
          base_url: String.t(),
          token: String.t(),
          poll_ms: non_neg_integer()
        }

  @type unifi_config :: %{
          base_url: String.t(),
          credential: Credential.t(),
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
    unifi = unifi_configs(sites)
    guests = Map.get(config, "guests", [])
    containers = Map.get(config, "containers", [])
    hardware = Map.get(config, "hardware", [])

    site_slugs = Enum.map(sites, & &1["slug"])
    validate_unique_slugs!(site_slugs)
    validate_kinds!(sites)

    host_keys = Enum.map(hosts, &host_key/1)
    validate_host_membership!(hosts, MapSet.new(site_slugs))

    guest_refs = Enum.map(guests, &guest_ref/1)
    validate_unique_guests!(guests)
    validate_guest_membership!(guests, MapSet.new(host_keys))
    validate_container_membership!(containers, MapSet.new(guest_refs))

    nodes = MapSet.union(MapSet.new(host_keys), MapSet.new(guest_refs))

    %__MODULE__{
      sites: Enum.map(sites, &site/1),
      hosts: Enum.map(hosts, &host/1),
      guests: Enum.map(guests, &guest/1),
      containers: Enum.map(containers, &container/1),
      hardware: group_hardware(hardware, nodes),
      proxmox: proxmox,
      unifi: unifi
    }
  end

  def new!(other),
    do:
      raise(
        ArgumentError,
        "baseline config must be a map with sites and hosts, got: #{inspect(other)}"
      )

  # Optional per-host Proxmox API access (SPEC-0001 REQ proxmox). A host entry
  # may declare "proxmox": {"url": ..., "poll_seconds": n} plus its credential
  # in either shape:
  #
  #   "token":        "homepage@pve!dashboard=<uuid>"   — the composed value
  #   "token_id" +    "homepage@pve!dashboard"          — the two halves, which
  #   "token_secret": "<uuid>"                            is how a secret store
  #                                                       usually holds them
  #
  # Either way the credential is validated here, at load, and a half-token is
  # a startup error naming the host. It used to be accepted and then rejected
  # by PVE with a 401 on every poll of every node, which surfaces as the whole
  # hypervisor fleet reading DOWN with no reason attached.
  #
  # Tokens live only in this struct; they are never rendered, logged, or
  # reachable through the snapshot.
  defp proxmox_configs(hosts) do
    hosts
    |> Enum.flat_map(fn host ->
      case host["proxmox"] do
        nil ->
          []

        %{"url" => url} = block ->
          poll_ms = Map.get(block, "poll_seconds", 30) * 1000
          token = proxmox_token!(block, host_key(host))
          [{host_key(host), %{base_url: url, token: token, poll_ms: poll_ms}}]

        block ->
          raise ArgumentError,
                "host #{host_key(host)} has an incomplete proxmox block #{inspect(Map.keys(block || %{}))} (url and a token are required)"
      end
    end)
    |> Map.new()
  end

  defp proxmox_token!(block, key) do
    where = "host #{key}"

    case {block["token"], block["token_id"], block["token_secret"]} do
      {token, nil, nil} when is_binary(token) ->
        Token.reveal(Token.parse!(token, where))

      {nil, id, secret} when is_binary(id) and is_binary(secret) ->
        Token.reveal(Token.compose!(id, secret, where))

      {nil, nil, nil} ->
        raise ArgumentError,
              "#{where} has a proxmox block with no credential (needs \"token\", or \"token_id\" + \"token_secret\")"

      _ ->
        raise ArgumentError,
              "#{where} has a proxmox block mixing credential shapes: give either \"token\" or both \"token_id\" and \"token_secret\", not a partial pair"
    end
  end

  # Optional per-site UniFi gateway (SPEC-0001 REQ "UniFi Site Discovery"). A
  # site entry may declare:
  #
  #   "unifi": {"url": ..., "api_key": ...,   "poll_seconds": n}
  #   "unifi": {"url": ..., "username": ..., "password": ..., "poll_seconds": n}
  #
  # Exactly one credential shape, and at most one gateway per site — the site
  # is the unit a gateway belongs to, so a second one would be a second site.
  #
  # UniFi never contributes a site. Every controller in this fleet reports a
  # single site named "default", so site identity cannot come from the API
  # (REQ "Discovery Does Not Invent Topology"); it comes from the slug beside
  # this block.
  defp unifi_configs(sites) do
    sites
    |> Enum.flat_map(fn site ->
      case site["unifi"] do
        nil ->
          []

        %{"url" => url} = block ->
          poll_ms = Map.get(block, "poll_seconds", 60) * 1000
          credential = Credential.new(unifi_credential!(block, site["slug"]))
          [{site["slug"], %{base_url: url, credential: credential, poll_ms: poll_ms}}]

        block ->
          raise ArgumentError,
                "site #{site["slug"]} has a unifi block with no url (keys: #{inspect(Map.keys(block || %{}))})"
      end
    end)
    |> Map.new()
  end

  defp unifi_credential!(block, slug) do
    case {block["api_key"], block["username"], block["password"]} do
      {key, nil, nil} when is_binary(key) ->
        %{api_key: key}

      {nil, user, pass} when is_binary(user) and is_binary(pass) ->
        %{username: user, password: pass}

      {nil, nil, nil} ->
        raise ArgumentError,
              "site #{slug} has a unifi block with no credential (needs \"api_key\", or \"username\" + \"password\")"

      _ ->
        raise ArgumentError,
              "site #{slug} has a unifi block mixing credential shapes: give either \"api_key\" or both \"username\" and \"password\""
    end
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

  defp validate_unique_guests!(guests) do
    refs = Enum.map(guests, &guest_ref/1)

    case Enum.find(Enum.frequencies(refs), fn {_ref, n} -> n > 1 end) do
      nil -> :ok
      {ref, _} -> raise ArgumentError, "duplicate guest #{ref} in baseline config"
    end
  end

  defp guest_ref(%{"vmid" => vmid, "host" => host}), do: "#{vmid}@#{host}"

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

  defp site(%{"slug" => slug, "kind" => kind} = entry) do
    %Site{
      slug: slug,
      kind: site_kind(kind),
      # The human label for the property ("51 Wynberg Park"). Optional: the
      # slug is the identity, the name is only what a person calls it.
      name: entry["name"] || slug,
      hosts: [],
      network: nil
    }
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
    %Container{id: id, guest: to_string(guest), name: name, status: :unknown}
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
      node_key = to_string(node)

      device = %HardwareDevice{
        name: entry["name"],
        kind: device_kind(entry["kind"]),
        model: entry["model"],
        passthrough: Map.get(entry, "passthrough", false),
        smart: Map.get(entry, "smart")
      }

      {node_key, device}
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
