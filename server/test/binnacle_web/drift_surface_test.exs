defmodule BinnacleWeb.DriftSurfaceTest do
  # Governing: ADR-0002 (fleet taxonomy), SPEC-0001 REQ "Discovery Does Not
  # Invent Topology" — "Entities observed outside configured topology MUST be
  # surfaced as config drift."
  #
  # Computing drift and never showing it is the bug #55 was filed about, so
  # the wire and the screen are the surfaces that actually close it. Both are
  # driven against the running Fleet, which is why this file is async: false.
  #
  # @joestump 08/21/2026 - Added while reviewing #66: site_json.ex and
  #   fleet_live.ex both gained a drift path with no test behind either.

  use BinnacleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # kitt: on wynberg, declares no guests, and no other test asserts its
  # readings — so driving the shared Fleet through it takes nothing away.
  @host "kitt"
  @site "wynberg"

  defp report_nodes(nodes) do
    send(Binnacle.Fleet, {:proxmox, @host, {:ok, %{guests: [], sample: nil, nodes: nodes}}})
    # The Fleet is a GenServer; a call flushes the cast ahead of it.
    _ = Binnacle.Fleet.drift()
    :ok
  end

  setup do
    on_exit(fn ->
      # Put the shared fleet back the way the async tests expect it: clear the
      # drift, then tick so the sample this host's polls blanked comes back.
      send(Binnacle.Fleet, {:proxmox, @host, {:ok, %{guests: [], sample: nil, nodes: [@host]}}})
      _ = Binnacle.Fleet.drift()
      send(Binnacle.Fleet, :tick)
      _ = Binnacle.Fleet.snapshot()
    end)

    :ok
  end

  defp authenticated(conn) do
    put_req_header(
      conn,
      "authorization",
      "Bearer " <> Application.fetch_env!(:binnacle, :api_token)
    )
  end

  describe "GET /api/sites" do
    test "carries an empty drift array when nothing has drifted", %{conn: conn} do
      report_nodes([@host])

      body = authenticated(conn) |> get("/api/sites") |> json_response(200)
      site = Enum.find(body["sites"], &(&1["slug"] == @site))

      assert site["drift"] == []
    end

    test "carries the drift entry once a node nobody declared shows up", %{conn: conn} do
      report_nodes([@host, "ghost"])

      body = authenticated(conn) |> get("/api/sites") |> json_response(200)
      site = Enum.find(body["sites"], &(&1["slug"] == @site))

      assert [entry] = site["drift"]
      assert entry["kind"] == "unknown_proxmox_node"
      assert entry["observed"] == "ghost"
      assert entry["site"] == @site
      assert entry["detail"] =~ "ghost"
    end
  end

  describe "GET /api/sites/:slug" do
    test "carries the same drift entry as the collection", %{conn: conn} do
      report_nodes([@host, "ghost"])

      body = authenticated(conn) |> get("/api/sites/#{@site}") |> json_response(200)

      assert [entry] = body["drift"]
      assert entry["observed"] == "ghost"
    end

    test "a site that has not drifted carries an empty array, never a null", %{conn: conn} do
      report_nodes([@host])

      body = authenticated(conn) |> get("/api/sites/#{@site}") |> json_response(200)

      assert body["drift"] == []
    end
  end

  describe "the overview" do
    test "renders the drift panel with the detail a human has to act on", %{conn: conn} do
      report_nodes([@host, "ghost"])

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "config drift"
      assert html =~ "ghost"
    end

    test "shows no drift panel when nothing has drifted", %{conn: conn} do
      report_nodes([@host])

      {:ok, _view, html} = live(conn, "/")

      refute html =~ "config drift"
    end
  end

  describe "a Site nobody grafted drift onto" do
    # build_snapshot/1 always sets :drift, so every path exercised above has
    # the key. The renderers still must not depend on that: a %Site{} built
    # anywhere else — a fixture, a future controller — used to be missing the
    # key entirely, and `site.drift` on a map without the key is a KeyError at
    # render time rather than the nil the callers were written to handle.
    #
    # Writing this test turned up the same defect already sitting on :status,
    # which build_snapshot/1 has always merged in the same way. Both fields are
    # now declared on the struct, so this is structurally true rather than
    # incidentally true.
    #
    # @joestump 08/21/2026 - Added while reviewing #66.

    test "still renders, because :drift is a declared field defaulting to []" do
      site = %Binnacle.Fleet.Model.Site{
        slug: "dub",
        kind: :home,
        name: "Dublin",
        hosts: [],
        network: nil
      }

      assert site.drift == []
      assert site.status == :unknown
      assert %{drift: [], status: :unknown} = BinnacleWeb.SiteJSON.show(%{site: site})
    end
  end
end
