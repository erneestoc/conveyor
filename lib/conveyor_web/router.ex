defmodule ConveyorWeb.Router do
  use ConveyorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConveyorWeb.Layouts, :root}
    plug :protect_from_forgery
    # Baseline policy; ConveyorWeb.Plugs.SecurityHeaders replaces it with the per-request
    # nonce policy right after.
    plug :put_secure_browser_headers, %{"content-security-policy" => "default-src 'self'"}
    plug ConveyorWeb.Plugs.SecurityHeaders
    plug ConveyorWeb.Plugs.Auth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/auth", ConveyorWeb do
    pipe_through :browser

    get "/login", AuthController, :login
    post "/admin", AuthController, :admin
    get "/oidc", AuthController, :oidc
    get "/oidc/callback", AuthController, :callback
    delete "/logout", AuthController, :logout
  end

  scope "/", ConveyorWeb do
    pipe_through :browser

    live_session :default, on_mount: [{ConveyorWeb.Auth, :default}] do
      live "/", BuildsLive, :all
      live "/dashboard", DashboardLive, :all
      live "/tests", TestsLive, :all
      live "/p/:slug", BuildsLive, :project
      live "/p/:slug/dashboard", DashboardLive, :project
      live "/p/:slug/tests", TestsLive, :project
      live "/invocation/:id", InvocationLive, :overview
      live "/invocation/:id/:tab", InvocationLive, :tab
    end

    live_session :admin, on_mount: [{ConveyorWeb.Auth, :default}, {ConveyorWeb.Auth, :admin}] do
      live "/settings", SettingsLive, :index
    end

    get "/invocation/:id/download/:kind", DownloadController, :show
    get "/invocation/:id/artifact/:name", DownloadController, :artifact
  end

  # The scrape endpoint reads the session (admin check when no METRICS_TOKEN is set).
  pipeline :metrics do
    plug :fetch_session
    plug :protect_from_forgery
  end

  scope "/", ConveyorWeb do
    pipe_through [:api, :metrics]
    get "/metrics", MetricsController, :index
  end

  scope "/", ConveyorWeb do
    pipe_through :api
    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready
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
