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
  #
  # @joestump-agent 08/19/2026 - Added shape validation. Proxmox authenticates
  # a token by the whole `USER@REALM!TOKENID=SECRET` string; the secret half
  # alone is not a credential. Our secret store keeps the two halves apart
  # (the token id sits beside the secret as a separate field), so the config
  # that carried only the secret produced a header PVE answers 401 to — on
  # every poll, for every node, silently, until the fleet showed every
  # hypervisor DOWN. `parse!/1` refuses a half-token at load rather than
  # letting it fail one HTTP request at a time.

  @derive {Inspect, only: []}
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @doc """
  Wrap a token value without checking its shape.

  For call sites that received an already-validated token (the poller). New
  configuration should go through `parse!/1` or `compose!/2` instead.
  """
  @spec new(String.t() | t()) :: t()
  def new(%__MODULE__{} = token), do: token
  def new(value) when is_binary(value), do: %__MODULE__{value: value}

  @doc """
  Validate and wrap a full Proxmox API token value.

  Raises `ArgumentError` naming `where` when the value is not the full
  `USER@REALM!TOKENID=SECRET` form. The error text never contains the value.
  """
  @spec parse!(String.t() | t(), String.t()) :: t()
  def parse!(%__MODULE__{value: value}, where), do: parse!(value, where)

  def parse!(value, where) when is_binary(value) do
    case validate(value) do
      :ok -> %__MODULE__{value: value}
      {:error, why} -> raise ArgumentError, "#{where} has an unusable Proxmox API token: #{why}"
    end
  end

  def parse!(other, where),
    do:
      raise(
        ArgumentError,
        "#{where} has a Proxmox API token of type #{inspect(other |> type_of())}, expected a string"
      )

  @doc """
  Build a full token from its two stored halves.

  This is the shape a secret store naturally holds: the token id
  (`homepage@pve!dashboard`) is not secret and lives in configuration, while
  only the UUID secret is vaulted.
  """
  @spec compose!(String.t(), String.t(), String.t()) :: t()
  def compose!(token_id, secret, where)
      when is_binary(token_id) and is_binary(secret) do
    parse!("#{String.trim(token_id)}=#{String.trim(secret)}", where)
  end

  def compose!(_token_id, _secret, where),
    do: raise(ArgumentError, "#{where} needs both token_id and token_secret as strings")

  @doc """
  Check a token value's shape without raising.

  Returns `:ok` or `{:error, reason}`. The reason describes the defect and
  never quotes the value.
  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(value) when is_binary(value) do
    with [id, secret] <- String.split(value, "=", parts: 2),
         true <- String.contains?(id, "@"),
         [_user_realm, token_id] <- String.split(id, "!", parts: 2),
         true <- token_id != "",
         true <- secret != "" do
      :ok
    else
      _ -> {:error, describe(value)}
    end
  end

  def validate(_), do: {:error, "expected a string"}

  # A defect report that is useful without being a leak: length and structural
  # facts only, never a substring of the secret.
  defp describe(value) do
    cond do
      value == "" ->
        "it is empty"

      not String.contains?(value, "=") ->
        "it is #{String.length(value)} characters with no \"=\", so it looks like the secret half " <>
          "on its own. Proxmox needs the whole token: USER@REALM!TOKENID=SECRET " <>
          "(supply token_id alongside token_secret, or store the composed value)"

      not String.contains?(value, "@") ->
        "the part before \"=\" has no \"@\", so it is not a USER@REALM!TOKENID"

      not String.contains?(value, "!") ->
        "the part before \"=\" has no \"!\", so it names a user but no token id"

      true ->
        "it is not the form USER@REALM!TOKENID=SECRET"
    end
  end

  defp type_of(nil), do: nil
  defp type_of(value) when is_map(value), do: :map
  defp type_of(value) when is_list(value), do: :list
  defp type_of(value) when is_number(value), do: :number
  defp type_of(_), do: :unknown

  @spec reveal(t() | String.t()) :: String.t()
  def reveal(%__MODULE__{value: value}), do: value
  def reveal(value) when is_binary(value), do: value
end
