defmodule Binnacle.Fleet.Unifi.Credential do
  # A UniFi Controller Credential That Cannot Be Printed By Accident
  #
  # The UniFi poller holds its credential for the life of the process, and any
  # crash in handle_info renders the GenServer state into an OTP crash report.
  # A bare map therefore reaches the logs the first time a poll raises, which
  # SPEC-0001 REQ "Baseline Config" forbids outright: "Credentials declared in
  # the config MUST NOT be exposed through the API, the UI, or logs."
  #
  # `Process.flag(:sensitive, true)` does not cover this. It hides the message
  # queue, the dictionary and the stack backtrace, and it disables tracing —
  # but `gen_server` formats State itself, and a sensitive process still logs
  #
  #   State: %{credential: %{username: "ro", password: "..."}}
  #
  # verbatim. `@derive {Inspect, only: []}` is what actually redacts it, the
  # same defence Binnacle.Fleet.Proxmox.Token provides for a PVE token.
  #
  # Reach for `reveal/1` only where the value goes on the wire.
  #
  # @joestump-agent 08/20/2026 - Added while reviewing #54, after confirming
  # against elixir:1.20-alpine that the sensitive flag leaves State intact.

  @derive {Inspect, only: []}
  defstruct [:value]

  @type t :: %__MODULE__{value: map()}

  @doc "Wrap a validated credential map. Idempotent."
  @spec new(map() | t()) :: t()
  def new(%__MODULE__{} = credential), do: credential
  def new(value) when is_map(value), do: %__MODULE__{value: value}

  @doc "The credential map, for the one call that puts it on the wire."
  @spec reveal(t() | map()) :: map()
  def reveal(%__MODULE__{value: value}), do: value
  def reveal(value) when is_map(value), do: value
end
