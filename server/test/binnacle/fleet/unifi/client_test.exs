defmodule Binnacle.Fleet.Unifi.ClientTest do
  use ExUnit.Case, async: true

  alias Binnacle.Fleet.Unifi.Client

  describe "fetch_sites/3" do
    test "decodes a valid sites response via plug mock (API key)" do
      plug = fn conn ->
        assert {"x-api-key", "test-key"} in conn.req_headers

        body =
          Jason.encode!(%{
            data: [
              %{"name" => "wynberg", "desc" => "Home"},
              %{"name" => "dtw", "desc" => "Airbnb"}
            ]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      assert {:ok, sites} =
               Client.fetch_sites("https://unifi.example.com", %{api_key: "test-key"}, plug: plug)

      assert length(sites) == 2
      assert Enum.map(sites, & &1.slug) == ["wynberg", "dtw"]
    end

    test "cookie login flow logs in, then reads /proxy/network sites" do
      parent = self()

      plug = fn conn ->
        case conn.request_path do
          "/api/auth/login" ->
            send(parent, {:login_headers, conn.req_headers})

            conn
            |> Plug.Conn.put_resp_header("set-cookie", "TOKEN=jwt-value; Path=/")
            |> Plug.Conn.send_resp(200, "")

          "/proxy/network/api/self/sites" ->
            send(parent, {:sites_headers, conn.req_headers})
            body = Jason.encode!(%{data: [%{"name" => "default", "desc" => "Default"}]})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, body)
        end
      end

      assert {:ok, sites} =
               Client.fetch_sites("https://unifi.example.com", %{username: "u", password: "p"},
                 plug: plug
               )

      assert Enum.map(sites, & &1.slug) == ["default"]

      assert_receive {:login_headers, headers}
      refute Enum.any?(headers, fn {name, _} -> name == "authorization" end)

      assert_receive {:sites_headers, headers}
      assert {"cookie", "TOKEN=jwt-value"} in headers
    end

    test "login failure is a named error" do
      plug = fn conn ->
        conn |> Plug.Conn.send_resp(401, "")
      end

      assert {:error, reason} =
               Client.fetch_sites("https://unifi.example.com", %{username: "u", password: "p"},
                 plug: plug
               )

      assert reason =~ "login answered HTTP 401"
    end

    test "rejects a credential with neither api key nor username" do
      assert {:error, reason} = Client.fetch_sites("https://unifi.example.com", %{})
      assert reason =~ ":api_key"
    end

    test "returns error on non-200 status" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, "{}")
      end

      assert {:error, reason} =
               Client.fetch_sites("https://unifi.example.com", %{api_key: "bad-key"}, plug: plug)

      assert reason =~ "HTTP 401"
    end

    test "returns error on unreachable host" do
      plug = fn _conn ->
        raise Req.TransportError, reason: :econnrefused
      end

      assert {:error, reason} =
               Client.fetch_sites("https://unreachable.example.com", %{api_key: "key"},
                 plug: plug
               )

      assert reason =~ "unreachable"
    end
  end
end
