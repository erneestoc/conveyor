defmodule ConveyorWebTest do
  use ExUnit.Case, async: true

  # Compiling modules through every `use ConveyorWeb, :kind` variant exercises the
  # macro bodies and catches missing imports early.
  defmodule Channel do
    use ConveyorWeb, :channel
    def join(_topic, _payload, socket), do: {:ok, socket}
  end

  defmodule Live do
    use ConveyorWeb, :live_view
    def render(assigns), do: ~H"<p>live</p>"
  end

  defmodule Component do
    use ConveyorWeb, :live_component
    def render(assigns), do: ~H"<p>component</p>"
  end

  defmodule Html do
    use ConveyorWeb, :html
    def hello(assigns), do: ~H"<p>html</p>"
  end

  test "static paths" do
    assert "assets" in ConveyorWeb.static_paths()
  end

  test "html helpers render" do
    assert Phoenix.LiveViewTest.rendered_to_string(Html.hello(%{})) =~ "html"
  end
end
