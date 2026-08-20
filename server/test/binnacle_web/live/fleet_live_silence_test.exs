defmodule BinnacleWeb.FleetLiveSilenceTest do
  # Governing: ADR-0005 (hardware-metrics zen overview), SPEC-0001 REQ
  # "Proxmox Discovery" ("an unreachable host MUST be surfaced ... never
  # silently dropped").
  #
  # The overview has three silences and they mean different things to whoever
  # is reading the screen at 2am: a host we cannot reach (act), a host we have
  # no way to measure (a gap in coverage, not an outage), and a host that has
  # simply not reported yet. Rendering all three as "no signal" — and the
  # first two identically — is how a fleet monitor sends someone to check a
  # machine that was never being watched.
  #
  # Not async: it drives the application-wide Binnacle.Fleet, which the
  # LiveView reads.
  use BinnacleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Binnacle.Fleet

  setup do
    previous = Application.get_env(:binnacle, :synthetic_metrics)

    on_exit(fn ->
      Application.put_env(:binnacle, :synthetic_metrics, previous)
      # Put the shared fleet back the way the async tests expect it.
      send(Fleet, :tick)
      _ = Fleet.snapshot()
    end)

    :ok
  end

  test "a host with no telemetry source says so, rather than 'no signal'", %{conn: conn} do
    Application.put_env(:binnacle, :synthetic_metrics, false)
    send(Fleet, :tick)
    _ = Fleet.snapshot()

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "no telemetry source"
  end

  test "a site with no gateway configured says so, rather than showing nothing",
       %{conn: conn} do
    # The shipped fixture baseline declares no UniFi block, so every site is
    # in this state. Blank space would read as "fine"; it is "not watched".
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "no gateway configured"
  end

  test "a site whose gateway stops answering reads as unreachable", %{conn: conn} do
    site = Fleet.snapshot() |> List.first()
    send(Fleet, {:unifi, site.slug, {:error, "connection refused"}})
    _ = Fleet.snapshot()

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "gateway unreachable"
  end

  test "a polled host that stops answering reads as unreachable", %{conn: conn} do
    for _ <- 1..3, do: send(Fleet, {:proxmox, "lir", {:error, "connection refused"}})
    _ = Fleet.snapshot()

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "unreachable"
  end
end
