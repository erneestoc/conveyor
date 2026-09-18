defmodule ConveyorWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias ConveyorWeb.Layouts

  test "app layout wraps content and shows flashes" do
    assigns = %{flash: %{"info" => "Hi", "error" => "No"}}

    html =
      rendered_to_string(~H"""
      <Layouts.app flash={@flash}>
        <p>content</p>
      </Layouts.app>
      """)

    assert html =~ "content" and html =~ "Hi" and html =~ "No"
    assert html =~ "client-error" and html =~ "server-error"
  end

  test "theme toggle renders the three modes" do
    assigns = %{}
    html = rendered_to_string(~H"<Layouts.theme_toggle />")
    assert html =~ "system" and html =~ "light" and html =~ "dark"
  end
end
