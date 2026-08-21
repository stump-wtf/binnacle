defmodule Binnacle.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        BinnacleWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:binnacle, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Binnacle.PubSub},
        # Owns the API rate limiter's ETS table. Supervised rather than
        # created by a request process, because an ETS table dies with its
        # owner and every bucket would go with it (SPEC-0001 REQ rate-limit).
        BinnacleWeb.Plugs.RateLimit.Buckets,
        # The fleet context: baseline config + metrics history + sample clock.
        Binnacle.Fleet
        # Proxmox pollers (one per host with API credentials) and UniFi
        # pollers (one per site with a gateway), both from the baseline
        # config (SPEC-0001). No credentials = no poller, and the entity
        # reports having no telemetry source rather than a fabricated state.
      ] ++
        Binnacle.Fleet.poller_specs() ++
        Binnacle.Fleet.disk_poller_specs() ++
        Binnacle.Fleet.unifi_poller_specs() ++
        [
          # Start to serve requests, typically the last entry
          BinnacleWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Binnacle.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BinnacleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
