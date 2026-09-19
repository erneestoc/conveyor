defmodule ConveyorWeb.Router do
  use ConveyorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConveyorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ConveyorWeb do
    pipe_through :browser

    live "/", BuildsLive, :all
    live "/dashboard", DashboardLive, :all
    live "/tests", TestsLive, :all
    live "/settings", SettingsLive, :index
    live "/p/:slug", BuildsLive, :project
    live "/p/:slug/dashboard", DashboardLive, :project
    live "/p/:slug/tests", TestsLive, :project
    live "/invocation/:id", InvocationLive, :overview
    live "/invocation/:id/:tab", InvocationLive, :tab
    get "/invocation/:id/download/:kind", DownloadController, :show
    get "/invocation/:id/artifact/:name", DownloadController, :artifact
  end

  pipeline :api_upload do
    plug ConveyorWeb.Plugs.ApiAuth, scope: "upload"
  end

  scope "/api/v1", ConveyorWeb do
    pipe_through [:api, :api_upload]

    put "/invocations/:id/artifacts/:name", UploadController, :artifact
    put "/invocations/:id/bep", UploadController, :bep
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:conveyor, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ConveyorWeb.Telemetry
    end
  end
end
