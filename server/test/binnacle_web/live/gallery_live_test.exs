defmodule BinnacleWeb.GalleryLiveTest do
  use BinnacleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the gallery mounts and renders every component family", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/gallery")

    # Header + eyebrow + cursor
    assert html =~ "// design stack"
    assert html =~ "binnacle"

    # Status chips: one of every state on screen at once
    for state <- ~w(up degraded down unknown) do
      assert html =~ state
    end

    # Meters in the summary panels
    assert html =~ "cpu"
    assert html =~ "memory"
    assert html =~ "package temp"

    # The fleet table with its numeric columns
    assert html =~ "hosts"
    assert html =~ "wynberg"
    assert html =~ "dtw"
    assert html =~ "88.4%"

    # The terminal frame — real log output only
    assert html =~ "caddy"

    # The help footer
    assert html =~ "↑/↓"
  end

  test "toggling the theme flips the data-theme attribute", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/gallery")

    assert view |> element("#gallery") |> render() =~ ~s(data-theme="night")

    view
    |> render_click("toggle-theme")

    assert view |> element("#gallery") |> render() =~ ~s(data-theme="day")
  end

  test "clicking a host selects it; clicking the selected host clears it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/gallery")

    # ogma starts selected.
    assert has_element?(view, "#hosts-ogma.rail-active")

    view
    |> element("#hosts-lir")
    |> render_click()

    assert has_element?(view, "#hosts-lir.rail-active")
    refute has_element?(view, "#hosts-ogma.rail-active")

    # Clicking the selected row clears it.
    view
    |> element("#hosts-lir")
    |> render_click()

    refute has_element?(view, "#hosts-lir.rail-active")
  end
end
