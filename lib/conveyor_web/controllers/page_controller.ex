defmodule ConveyorWeb.PageController do
  use ConveyorWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
