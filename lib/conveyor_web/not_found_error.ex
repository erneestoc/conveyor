defmodule ConveyorWeb.NotFoundError do
  @moduledoc "Raised by LiveViews and controllers for unknown records; rendered as a 404."
  defexception [:message, plug_status: 404]
end
