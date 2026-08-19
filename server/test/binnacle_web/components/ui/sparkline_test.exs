defmodule BinnacleWeb.Ui.SparklineTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias BinnacleWeb.Ui.Sparkline

  test "draws a polyline scaled into the viewBox" do
    html =
      render_component(&Sparkline.sparkline/1,
        label: "cpu",
        series: [0, 50, 100],
        warn: 80,
        danger: 95
      )

    assert html =~ "<polyline"
    # 0 → top of the 28px box, 100 → bottom.
    assert html =~ "0.0,28.0"
    assert html =~ "120.0,0.0"
  end

  test "nil readings gap the line instead of interpolating across" do
    html =
      render_component(&Sparkline.sparkline/1,
        label: "cpu",
        series: [10, nil, nil, 90],
        warn: 80,
        danger: 95
      )

    # Two contiguous segments, one per run of known data.
    assert html |> String.split("<polyline") |> Enum.count() == 3
  end

  test "the line takes the status hue only outside nominal" do
    nominal =
      render_component(&Sparkline.sparkline/1,
        label: "cpu",
        series: [10, 20],
        warn: 80,
        danger: 95
      )

    hot =
      render_component(&Sparkline.sparkline/1,
        label: "cpu",
        series: [10, 96],
        warn: 80,
        danger: 95
      )

    assert nominal =~ "text-line-bright"
    assert hot =~ "text-danger"
  end

  test "aria-label carries the reading, not just the name" do
    html =
      render_component(&Sparkline.sparkline/1,
        label: "cpu",
        series: [10, 42.6],
        warn: 80,
        danger: 95
      )

    assert html =~ ~s(aria-label="cpu trend, latest 42.6")
  end
end
