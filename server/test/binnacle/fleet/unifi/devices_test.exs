defmodule Binnacle.Fleet.Unifi.DevicesTest do
  # Governing: ADR-0002 (fleet taxonomy), SPEC-0001 REQ "UniFi Site
  # Discovery" — "confirm gateway presence and collect network-device
  # inventory and gateway health metrics".
  use ExUnit.Case, async: true

  alias Binnacle.Fleet.Unifi.Client

  defp devices_plug(entries, opts \\ []) do
    parent = Keyword.get(opts, :notify)

    fn conn ->
      if parent, do: send(parent, {:path, conn.request_path})

      case conn.request_path do
        "/api/auth/login" ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "TOKEN=abc; Path=/; HttpOnly")
          |> Plug.Conn.send_resp(200, "{}")

        _ ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{data: entries}))
      end
    end
  end

  describe "fetch_devices/3" do
    test "classifies the gateway, switches and access points" do
      plug =
        devices_plug([
          %{"mac" => "aa:00", "name" => "udr7", "model" => "UDR7", "type" => "udr", "state" => 1},
          %{
            "mac" => "bb:00",
            "name" => "sw-rack",
            "model" => "USW",
            "type" => "usw",
            "state" => 1
          },
          %{"mac" => "cc:00", "name" => "ap-loft", "model" => "U6", "type" => "uap", "state" => 1}
        ])

      assert {:ok, %{gateway: gateway, devices: devices}} =
               Client.fetch_devices("https://unifi", %{api_key: "k"}, plug: plug)

      assert gateway.name == "udr7"
      assert gateway.kind == :gateway
      assert Enum.map(devices, & &1.kind) == [:gateway, :switch, :access_point]
    end

    test "a site with no gateway reports nil rather than guessing" do
      plug = devices_plug([%{"mac" => "bb:00", "type" => "usw", "state" => 1}])

      assert {:ok, %{gateway: nil, devices: [switch]}} =
               Client.fetch_devices("https://unifi", %{api_key: "k"}, plug: plug)

      assert switch.kind == :switch
    end

    test "an unrecognized device type is inventory, not a dropped row" do
      # An inventory that silently omits a device is worse than one that
      # cannot classify it: the count is what someone checks against reality.
      plug = devices_plug([%{"mac" => "dd:00", "type" => "ucamera", "state" => 1}])

      assert {:ok, %{devices: [device]}} =
               Client.fetch_devices("https://unifi", %{api_key: "k"}, plug: plug)

      assert device.kind == :other
    end

    test "UniFi's state integers map to statuses, with transitional not an outage" do
      plug =
        devices_plug([
          %{"mac" => "a", "type" => "usw", "state" => 1},
          %{"mac" => "b", "type" => "usw", "state" => 0},
          %{"mac" => "c", "type" => "usw", "state" => 5},
          %{"mac" => "d", "type" => "usw"}
        ])

      assert {:ok, %{devices: devices}} =
               Client.fetch_devices("https://unifi", %{api_key: "k"}, plug: plug)

      assert Enum.map(devices, & &1.status) == [:up, :down, :degraded, :unknown]
    end

    test "names a device by model or mac when it has no name" do
      plug = devices_plug([%{"mac" => "ee:00", "model" => "USW-Lite", "type" => "usw"}])

      assert {:ok, %{devices: [device]}} =
               Client.fetch_devices("https://unifi", %{api_key: "k"}, plug: plug)

      assert device.name == "USW-Lite"
    end

    test "the cookie flow logs in first, then reads the device endpoint" do
      plug = devices_plug([], notify: self())

      assert {:ok, _} =
               Client.fetch_devices("https://unifi", %{username: "u", password: "p"}, plug: plug)

      assert_receive {:path, "/api/auth/login"}
      assert_receive {:path, "/proxy/network/api/s/default/stat/device"}
    end

    test "a controller that will not authenticate is a named error" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "") end

      assert {:error, reason} =
               Client.fetch_devices("https://unifi", %{username: "u", password: "p"}, plug: plug)

      assert reason =~ "login"
      assert reason =~ "401"
    end

    test "a credential of neither shape is refused before any request" do
      assert {:error, reason} = Client.fetch_devices("https://unifi", %{})
      assert reason =~ ":api_key"
    end
  end
end
