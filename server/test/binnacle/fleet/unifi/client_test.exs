defmodule Binnacle.Fleet.Unifi.ClientTest do
  use ExUnit.Case, async: true

  alias Binnacle.Fleet.Unifi.Client

  describe "fetch_sites/3" do
    test "decodes a valid sites response via plug mock" do
      plug = fn conn ->
        body = Jason.encode!(%{data: [%{"name" => "wynberg", "desc" => "Home"}, %{"name" => "dtw", "desc" => "Airbnb"}]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      assert {:ok, sites} = Client.fetch_sites("https://unifi.example.com", "test-key", plug: plug)
      assert length(sites) == 2
      assert Enum.map(sites, & &1.slug) == ["wynberg", "dtw"]
    end

    test "returns error on non-200 status" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, "{}")
      end

      assert {:error, reason} = Client.fetch_sites("https://unifi.example.com", "bad-key", plug: plug)
      assert reason =~ "HTTP 401"
    end

    test "returns error on unreachable host" do
      plug = fn _conn ->
        raise Req.TransportError, reason: :econnrefused
      end

      assert {:error, reason} = Client.fetch_sites("https://unreachable.example.com", "key", plug: plug)
      assert reason =~ "unreachable"
    end
  end
end
