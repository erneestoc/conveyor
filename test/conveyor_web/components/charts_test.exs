defmodule ConveyorWeb.ChartsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import ConveyorWeb.Charts

  defp render(template), do: rendered_to_string(template)

  test "stacked bars, lines, hbars and legend render with and without data" do
    points =
      for d <- 1..10,
          do: %{
            bucket: DateTime.new!(Date.new!(2026, 9, d), ~T[00:00:00], "Etc/UTC"),
            a: d,
            b: 10 - d,
            p50: if(d == 5, do: nil, else: d * 1000),
            p90: d * 2000
          }

    assigns = %{
      points: points,
      hourly: [%{bucket: ~U[2026-09-01 10:00:00Z], a: 1, b: 0, p50: 5, p90: 6}],
      empty: []
    }

    html =
      render(~H"""
      <.stacked_bars
        id="sb"
        points={@points}
        series={[{:a, "text-emerald-500"}, {:b, "text-rose-500"}]}
      />
      <.stacked_bars id="sb1" points={@hourly} series={[{:a, "text-emerald-500"}]} />
      <.stacked_bars id="sb0" points={@empty} series={[{:a, "x"}]} />
      <.lines
        id="ln"
        points={@points}
        series={[{:p50, "text-sky-500", "p50"}, {:p90, "text-amber-500", "p90"}]}
      />
      <.lines id="ln0" points={@empty} series={[{:p50, "x", "p50"}]} max={100} />
      <.hbars id="hb" items={[{"a", 3}, {"b", 1}]} />
      <.hbars id="hb0" items={[]} />
      <.legend items={[{"a", "text-emerald-500"}]} />
      """)

    assert html =~ ~s(id="sb") and html =~ "<rect" and html =~ "Sep 01"
    assert html =~ "10:00"
    assert html =~ ~s(id="ln") and html =~ "<path"
    assert html =~ "nothing in this window"
    assert html =~ "width: 100%"
  end
end
