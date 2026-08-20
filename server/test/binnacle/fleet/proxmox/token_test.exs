defmodule Binnacle.Fleet.Proxmox.TokenTest do
  # Governing: ADR-0002 (fleet taxonomy), SPEC-0001 REQ "Proxmox Discovery"
  # and REQ "Baseline Config File" ("config loading MUST fail fast with
  # actionable errors").
  #
  # The regression these cover: the secret store keeps a PVE token's id and
  # its secret in separate fields, the baseline carried only the secret, and
  # `PVEAPIToken=<uuid>` 401s. Every hypervisor read DOWN, and nothing in the
  # logs said why.
  use ExUnit.Case, async: true

  alias Binnacle.Fleet.Proxmox.Token

  @full "homepage@pve!dashboard=00000000-0000-4000-8000-000000000000"
  @secret_only "00000000-0000-4000-8000-000000000000"

  describe "validate/1" do
    test "accepts the full USER@REALM!TOKENID=SECRET form" do
      assert :ok = Token.validate(@full)
    end

    test "rejects the secret half on its own" do
      assert {:error, reason} = Token.validate(@secret_only)
      assert reason =~ "secret half"
      assert reason =~ "USER@REALM!TOKENID=SECRET"
    end

    test "rejects a token id with no realm" do
      assert {:error, reason} = Token.validate("homepage!dashboard=#{@secret_only}")
      assert reason =~ "@"
    end

    test "rejects a user with no token id" do
      assert {:error, reason} = Token.validate("homepage@pve=#{@secret_only}")
      assert reason =~ "!"
    end

    test "rejects an empty secret" do
      assert {:error, _} = Token.validate("homepage@pve!dashboard=")
    end

    test "rejects an empty value" do
      assert {:error, reason} = Token.validate("")
      assert reason =~ "empty"
    end
  end

  describe "the error never leaks the credential" do
    test "no substring of the secret appears in the message" do
      {:error, reason} = Token.validate(@secret_only)

      refute reason =~ "00000000"
      refute reason =~ @secret_only
    end

    test "parse! raises without quoting the value" do
      error =
        assert_raise ArgumentError, fn -> Token.parse!(@secret_only, "host lir") end

      assert error.message =~ "host lir"
      refute error.message =~ "00000000"
    end
  end

  describe "compose!/3" do
    test "joins the two halves the secret store keeps apart" do
      token = Token.compose!("homepage@pve!dashboard", @secret_only, "host lir")

      assert Token.reveal(token) == @full
    end

    test "trims whitespace a file-backed secret carries" do
      token = Token.compose!(" homepage@pve!dashboard ", @secret_only <> "\n", "host lir")

      assert Token.reveal(token) == @full
    end

    test "refuses halves that do not compose into a valid token" do
      assert_raise ArgumentError, ~r/host lir/, fn ->
        Token.compose!("dashboard", @secret_only, "host lir")
      end
    end
  end

  describe "inspection" do
    test "a parsed token still refuses to render itself" do
      token = Token.parse!(@full, "host lir")

      refute inspect(token) =~ "00000000"
      refute inspect(token) =~ "homepage"
    end
  end
end
