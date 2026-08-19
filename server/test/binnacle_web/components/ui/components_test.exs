defmodule BinnacleWeb.Ui.ComponentRenderTest do
  use BinnacleWeb.ConnCase, async: true

  use Phoenix.Component

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias BinnacleWeb.Ui.{Badge, Feedback, Icon, Meter, Panel, Table, Terminal}

  defp to_html(heex) do
    Phoenix.LiveViewTest.rendered_to_string(heex)
  end

  test "Badge.status renders glyph, label, and hue together" do
    html = render_component(&Badge.status/1, status: :degraded)
    assert html =~ "▲"
    assert html =~ "degraded"
    assert html =~ "text-warn"
  end

  test "Badge.count and eyebrow" do
    assert render_component(&Badge.count/1, count: 14, noun: "containers") =~ "14 containers"
    assert render_component(&Badge.eyebrow/1, text: "FLEET") =~ "// FLEET"
  end

  test "Meter sets aria values from the same numbers that draw the bar" do
    html = render_component(&Meter.view/1, label: "cpu", value: 93.5, thresholds: Meter.cpu())
    assert html =~ ~s(aria-valuenow="93.5")
    assert html =~ ~s(aria-valuemax="100")
    assert html =~ ~s(width: 93.5%)
  end

  test "Meter fill goes flat in the alert hue once a threshold is crossed" do
    nominal = render_component(&Meter.view/1, label: "cpu", value: 40, thresholds: Meter.cpu())
    alerting = render_component(&Meter.view/1, label: "cpu", value: 96, thresholds: Meter.cpu())
    assert nominal =~ "--grad-neon-bar"
    assert alerting =~ "bg-danger"
  end

  test "Panel renders optional eyebrow, title, and accent rail" do
    assigns = %{}

    html =
      to_html(~H"""
      <Panel.view title="ogma" eyebrow="host" accent="warn">meters live here</Panel.view>
      """)

    assert html =~ "// host"
    assert html =~ "ogma"
    assert html =~ "bg-warn"
  end

  test "Panel omits the header entirely when neither title nor eyebrow is given" do
    assigns = %{}

    html =
      to_html(~H"""
      <Panel.view>just the framed box</Panel.view>
      """)

    refute html =~ "border-b border-line-dim"
  end

  test "Terminal is pinned night and renders log lines without reflow" do
    html =
      render_component(&Terminal.view/1,
        title: "caddy · ie01",
        mode: :following,
        lines: ["2026-08-15T09:14:02Z  INF  serving initial configuration"]
      )

    assert html =~ ~s(data-theme="night")
    assert html =~ "whitespace-pre"
    assert html =~ "FOLLOWING"
  end

  test "Icon emits the Lucide frame with currentColor" do
    html = render_component(&Icon.icon/1, name: :host, class: "size-4 text-ok")
    assert html =~ ~s(viewBox="0 0 24 24")
    assert html =~ ~s(stroke="currentColor")
    assert html =~ ~s(aria-hidden="true")
  end

  test "Feedback spinner frame wraps with the tick" do
    assert Feedback.spinner_frame(Feedback.braille(), 8) == "⣾"
    assert Feedback.spinner_frame([], 3) == "⠿"
  end

  test "Table renders the empty state when there are no rows" do
    assigns = %{}

    html =
      to_html(~H"""
      <Table.view
        id="t"
        rows={[]}
        row_id={& &1}
        empty="no hosts discovered"
      >
        <:col label="host">{""}</:col>
      </Table.view>
      """)

    assert html =~ "no hosts discovered"
  end

  test "Table numeric columns are right-aligned and tabular; selection rails the row" do
    rows = [%{name: "ie01", cpu: 34.2}, %{name: "ogma", cpu: 88.4}]
    assigns = %{rows: rows}

    html =
      to_html(~H"""
      <Table.view id="t" rows={@rows} row_id={& &1.name} selected="ogma" on_select="select-host">
        <:col :let={host} label="host">{host.name}</:col>
        <:col :let={host} label="cpu" numeric>{Meter.format_value(host.cpu)}%</:col>
      </Table.view>
      """)

    assert html =~ "text-right tabular-nums"
    assert html =~ "tint-primary rail-active"
    assert html =~ ~s(phx-click="select-host")
    refute html =~ "no hosts discovered"
  end
end
