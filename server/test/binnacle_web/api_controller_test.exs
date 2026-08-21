defmodule BinnacleWeb.ApiControllerTest do
  # SPEC-0001 REQ read-only-api + security requirements. Exercises the wire
  # surface end-to-end against the baseline fixture: auth, shapes, method
  # policy, headers, and error handling.
  use BinnacleWeb.ConnCase, async: true

  describe "GET /healthz" do
    test "is public and reports liveness", %{conn: conn} do
      conn = get(conn, "/healthz")
      assert json_response(conn, 200)["status"] == "ok"
    end

    test "carries the security headers", %{conn: conn} do
      conn = get(conn, "/healthz")
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src 'self'" and csp =~ "frame-ancestors 'none'"
      assert csp =~ "font-src 'self'"
      assert csp =~ ~s('nonce-)
    end
  end

  describe "authentication" do
    test "401 without a token", %{conn: conn} do
      conn = get(conn, "/api/sites")
      assert conn.status == 401
    end

    test "401 with an invalid token, indistinguishable from missing", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "Bearer wrong") |> get("/api/sites")
      assert conn.status == 401
      missing = get(build_conn(), "/api/sites")
      assert conn.resp_body == missing.resp_body
    end

    test "401 when no token is configured (fail closed)", %{conn: conn} do
      original = Application.get_env(:binnacle, :api_token)
      Application.put_env(:binnacle, :api_token, nil)
      conn = conn |> put_req_header("authorization", "Bearer anything") |> get("/api/sites")
      Application.put_env(:binnacle, :api_token, original)
      assert conn.status == 401
    end

    test "401 does not leak taxonomy data", %{conn: conn} do
      conn = get(conn, "/api/sites")
      refute conn.resp_body =~ "wynberg"
    end
  end

  describe "GET /api/sites" do
    test "lists sites with kind and health rollup", %{conn: conn} do
      conn = authenticated(conn) |> get("/api/sites")
      assert %{"sites" => sites} = json_response(conn, 200)
      wynberg = Enum.find(sites, &(&1["slug"] == "wynberg"))
      assert wynberg["kind"] == "home"
      assert wynberg["host_count"] == 9
      assert wynberg["status"] in ["up", "degraded", "down", "unknown"]
    end

    test "contains no credentials", %{conn: conn} do
      conn = authenticated(conn) |> get("/api/sites")
      refute conn.resp_body =~ "token"
      refute conn.resp_body =~ "api_key"
    end
  end

  describe "GET /api/sites/:slug" do
    test "shows hosts with metrics and guests", %{conn: conn} do
      conn = authenticated(conn) |> get("/api/sites/wynberg")
      assert %{"hosts" => hosts} = json_response(conn, 200)
      ogma = Enum.find(hosts, &(&1["key"] == "ogma"))

      assert ogma["guests"] |> Enum.map(& &1["name"]) |> Enum.sort() == [
               "hud01",
               "pve-media",
               "pve-services"
             ]

      assert is_map_key(ogma, "metrics")
    end

    test "404 for an unknown slug", %{conn: conn} do
      conn = authenticated(conn) |> get("/api/sites/nope")
      assert json_response(conn, 404)["error"] == "not found"
    end
  end

  describe "GET /api/hosts/:key" do
    test "shows guests, hardware, and series", %{conn: conn} do
      conn = authenticated(conn) |> get("/api/hosts/ogma")
      body = json_response(conn, 200)
      assert body["key"] == "ogma"
      assert body["site"] == "wynberg"
      assert is_map_key(body, "series")
      assert Enum.map(body["guests"], & &1["vmid"]) == [101, 201, 202]
    end

    test "404 for an unknown host", %{conn: conn} do
      conn = authenticated(conn) |> get("/api/hosts/nope")
      assert json_response(conn, 404)["error"] == "not found"
    end
  end

  describe "GET /api/guests/:id" do
    test "shows containers and hardware by derived identity", %{conn: conn} do
      conn = authenticated(conn) |> get("/api/guests/201@ogma")
      body = json_response(conn, 200)
      assert body["name"] == "pve-services"
      assert body["id"] == "201@ogma"
      assert is_list_key(body, "containers")
    end

    test "accepts a bare unambiguous vmid", %{conn: conn} do
      conn = authenticated(conn) |> get("/api/guests/201")
      assert json_response(conn, 200)["vmid"] == 201
    end

    test "404 for an unknown guest", %{conn: conn} do
      conn = authenticated(conn) |> get("/api/guests/999@ogma")
      assert json_response(conn, 404)["error"] == "not found"
    end
  end

  describe "read-only method policy" do
    test "405 for POST to an api path", %{conn: conn} do
      conn = authenticated(conn) |> post("/api/sites", %{})
      assert json_response(conn, 405)["error"] == "method not allowed"
    end

    test "405 for DELETE to an api path", %{conn: conn} do
      conn = authenticated(conn) |> delete("/api/sites/wynberg")
      assert json_response(conn, 405)["error"] == "method not allowed"
    end
  end

  defp authenticated(conn) do
    put_req_header(conn, "authorization", "Bearer " <> token())
  end

  defp token do
    Application.fetch_env!(:binnacle, :api_token)
  end

  defp is_list_key(map, key) when is_map(map), do: is_list(map[key])
end
