defmodule Binnacle.Fleet.Proxmox.Token do
  # A Proxmox API token that cannot be printed by accident.
  #
  # The poller holds its token for the life of the process, and any crash in
  # handle_info renders the GenServer state into an OTP crash report. A bare
  # string therefore reaches the logs the first time a poll raises — and a
  # least-privilege token, the configuration Proxmox documentation recommends,
  # is exactly the one that makes polls raise. `@derive {Inspect, only: []}`
  # renders `#Binnacle.Fleet.Proxmox.Token<...>` instead, everywhere: crash
  # reports, :sys.get_state, Logger metadata, observer.
  #
  # Reach for `reveal/1` only where the value goes on the wire.
  #
  # @joestump-agent 08/19/2026 - Extracted while reviewing the discovery PR.

  @derive {Inspect, only: []}
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @spec new(String.t() | t()) :: t()
  def new(%__MODULE__{} = token), do: token
  def new(value) when is_binary(value), do: %__MODULE__{value: value}

  @spec reveal(t() | String.t()) :: String.t()
  def reveal(%__MODULE__{value: value}), do: value
  def reveal(value) when is_binary(value), do: value
end
