defmodule BinnacleWeb.Ui.StatusTest do
  use ExUnit.Case, async: true

  alias BinnacleWeb.Ui.Status

  test "every status has a glyph, label, and the three class utilities" do
    for status <- Status.all() do
      assert String.length(Status.glyph(status)) == 1
      assert Status.label(status) == String.downcase(Status.label(status))
      assert Status.text_class(status) =~ "text-"
      assert Status.dot_class(status) =~ "bg-"
      assert Status.tint_class(status) =~ "/10"
    end
  end

  test "from_string parses known values and rejects unknown ones" do
    assert {:ok, :up} = Status.from_string("up")
    assert {:ok, :unknown} = Status.from_string("unknown")
    assert :error = Status.from_string("on fire")
  end

  test "unknown is dim, not danger — a monitoring gap is not an outage" do
    refute Status.text_class(:unknown) == Status.text_class(:down)
  end
end

defmodule BinnacleWeb.Ui.ThemeTest do
  use ExUnit.Case, async: true

  alias BinnacleWeb.Ui.Theme

  test "toggle is total" do
    assert Enum.all?(Theme.all(), &(Theme.toggle(Theme.toggle(&1)) == &1))
  end

  test "from_string keeps 'no choice' distinguishable from 'night'" do
    assert :error = Theme.from_string("")
    assert {:ok, :night} = Theme.from_string("night")
  end

  test "storage key is app-scoped, not the design system's own" do
    refute Theme.storage_key() == "btds-theme"
  end
end

defmodule BinnacleWeb.Ui.MeterTest do
  use ExUnit.Case, async: true

  alias BinnacleWeb.Ui.Meter

  test "thresholds are per-metric and explicit" do
    # 78% is already memory pressure but a host merely working on CPU.
    assert Meter.status_for(Meter.memory(), 78) == :degraded
    assert Meter.status_for(Meter.cpu(), 78) == :up
    # 96% CPU is deep in it; 96% memory is the OOM killer's doorstep.
    assert Meter.status_for(Meter.cpu(), 96) == :down
    assert Meter.status_for(Meter.memory(), 96) == :down
    # 80 °C is the throttling neighbourhood; 80% memory is unremarkable.
    assert Meter.status_for(Meter.temperature(), 80) == :degraded
    assert Meter.status_for(Meter.memory(), 80) == :degraded
  end

  test "fraction clamps to the track" do
    assert Meter.fraction(150, 100) == 1.0
    assert Meter.fraction(-5, 100) == 0.0
    assert Meter.fraction(50, 0) == 0.0
  end

  test "format_value drops the trailing .0" do
    assert Meter.format_value(93.5) == "93.5"
    assert Meter.format_value(7.0) == "7"
  end
end
