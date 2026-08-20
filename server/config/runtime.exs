import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/binnacle start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :binnacle, BinnacleWeb.Endpoint, server: true
end

config :binnacle, BinnacleWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :binnacle, BinnacleWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/binnacle_web/router\.ex$",
        ~r"lib/binnacle_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  # binnacle is a LAN fleet monitor behind Caddy with no authenticated
  # sessions; a release-scoped generated key keeps the container bootable
  # without a secret-provisioning step. Sessions reset on redeploy, which
  # costs nothing here. Set SECRET_KEY_BASE to override.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      :crypto.strong_rand_bytes(64) |> Base.encode64(padding: false)

  host = System.get_env("PHX_HOST") || "example.com"

  config :binnacle, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :binnacle, BinnacleWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :binnacle, BinnacleWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :binnacle, BinnacleWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# API auth + rate limiting (SPEC-0001). The bearer token is env-only:
# never in the baseline config file, never logged. Unset token = API fails
# closed; /healthz stays public either way.
# Env vars are only applied when set so test config is not clobbered by
# runtime loading.
if token = System.get_env("BINNACLE_API_TOKEN") do
  config :binnacle, api_token: token
end

# Baseline fleet config path override (the deployment mounts its fleet
# baseline as a compose secret file; the bundled fixture is the default).
if baseline = System.get_env("BINNACLE_BASELINE") do
  config :binnacle, baseline: baseline
end

if rate = System.get_env("BINNACLE_API_RATE") do
  config :binnacle, api_rate_per_second: String.to_integer(rate)
end

if burst = System.get_env("BINNACLE_API_BURST") do
  config :binnacle, api_rate_burst: String.to_integer(burst)
end

# Reverse proxies whose `x-forwarded-for` the rate limiter believes: a
# comma-separated list of addresses or CIDRs (e.g. "172.18.0.0/16,10.0.0.5").
# binnacle sits behind Caddy, so without this the peer address is Caddy on
# every request and the whole fleet shares one bucket. Set it to the proxy
# only: any client inside the range can name its own bucket, and an
# unlimited supply of bucket keys is no rate limit at all. Unset means the
# header is never believed. A malformed entry fails the boot, naming it.
if proxies = System.get_env("BINNACLE_TRUSTED_PROXIES") do
  config :binnacle,
    trusted_proxies: proxies |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# Proxmox Poller Credentials From The Environment
#
# Topology is declared in the baseline, never in the environment. The one
# thing FLEET_* still carries is Proxmox poller credentials, for a deployment
# that would rather not put tokens in the baseline file. The value may be
# either the literal content or a path to a file containing it (the
# /run/secrets compose files SPEC-0002 provisions), so credentials never have
# to sit in `docker inspect`-visible environment entries.
#
#   FLEET_PROXMOX_NODES — JSON array of {name, url, token} objects.
#     Example: [{"name":"lir","url":"https://lir.stump.rocks:8006","token":"user@pam!id=secret"}]
#
# @joestump-agent 08/20/2026 - Dropped FLEET_UNIFI_*, FLEET_SITE_MAP and
# FLEET_SITE_KINDS while reviewing #54. That PR removed the code that read
# them: sites and their kinds now come only from the baseline, and UniFi is
# configured per site (each property runs its own controller, so a single
# global FLEET_UNIFI_URL cannot address four of them). Left in place they
# were env vars an operator could set, that validated, and that then did
# nothing at all — the same silent-ignore defect #54 is about. UniFi
# credentials belong in the site's `unifi` block; see Binnacle.Fleet.Config.

defmodule Binnacle.FleetRuntime do
  @moduledoc false

  def read_env(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        if File.exists?(value), do: String.trim(File.read!(value)), else: value
    end
  end

  def decode_json!(name) do
    case Jason.decode(read_env(name) || "") do
      {:ok, decoded} -> decoded
      {:error, _} -> raise ArgumentError, "#{name} must be valid JSON or a path to a JSON file"
    end
  end
end

alias Binnacle.FleetRuntime

if FleetRuntime.read_env("FLEET_PROXMOX_NODES") do
  nodes = FleetRuntime.decode_json!("FLEET_PROXMOX_NODES")

  unless is_list(nodes), do: raise(ArgumentError, "FLEET_PROXMOX_NODES must be a JSON array")
  config :binnacle, proxmox_nodes: nodes
end
