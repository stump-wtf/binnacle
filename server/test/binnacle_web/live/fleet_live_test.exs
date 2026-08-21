defmodule BinnacleWeb.FleetLiveTest do
  use BinnacleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the overview mounts with every site and host", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "wynberg"
    assert html =~ "dtw"
    assert html =~ "airbnb"
    assert html =~ "ie01"
    assert html =~ "ogma"
    assert html =~ "buoy"
  end

  test "hardware readings and trend lines render on the collapsed rows", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "cpu"
    assert html =~ "mem"
    assert html =~ "temp"
    assert html =~ "<polyline"
  end

  test "expanding a host reveals the hardware panel, devices, and guests", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    refute has_element?(view, "#host-ogma", "package temp")

    view
    |> element("#host-ogma button", "hardware")
    |> render_click()

    assert has_element?(view, "#host-ogma", "package temp")
    assert has_element?(view, "#host-ogma", "WDC WD40EFRX")
    assert has_element?(view, "#host-ogma", "smart: warn")
    assert has_element?(view, "#host-ogma", "pve-services")
    assert has_element?(view, "#host-ogma", "cairn")
  end

  test "root layout carries a nonce on the inline theme script", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(nonce=")
    assert html =~ "binnacle-theme"
    refute html =~ ~s(style="font-family: monospace)
  end
end
