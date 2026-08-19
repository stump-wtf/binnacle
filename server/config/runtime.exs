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

if rate = System.get_env("BINNACLE_API_RATE") do
  config :binnacle, api_rate_per_second: String.to_integer(rate)
end

if burst = System.get_env("BINNACLE_API_BURST") do
  config :binnacle, api_rate_burst: String.to_integer(burst)
end
