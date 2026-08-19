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
        # The fleet context: baseline config + metrics history + sample clock.
        Binnacle.Fleet
        # Proxmox pollers, one per host with API credentials in the baseline
        # config (SPEC-0001). No creds = no poller; the sampler feeds instead.
      ] ++
        Binnacle.Fleet.poller_specs() ++
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
