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

  test "a silent host shows 'no signal', not a fake outage", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "no signal"
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
end
