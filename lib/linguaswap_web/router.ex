defmodule LinguaswapWeb.Router do
  use LinguaswapWeb, :router

  import LinguaswapWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LinguaswapWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_current_scope_for_user
  end

  pipeline :api_auth do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :fetch_current_scope_for_user
    plug :require_authenticated_user
  end

  scope "/api/v1", LinguaswapWeb do
    pipe_through :api

    post "/auth/login", ApiController, :login
  end

  scope "/api/v1", LinguaswapWeb do
    pipe_through :api_auth

    get "/words", ApiController, :get_words
    post "/words/reveal", ApiController, :record_reveal
    post "/words/replace", ApiController, :record_replacement
    post "/pagevisit", ApiController, :record_page_visit
    get "/stats", ApiController, :get_stats
    get "/settings", ApiController, :get_settings
    put "/settings", ApiController, :update_settings
  end

  scope "/", LinguaswapWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", LinguaswapWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:linguaswap, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LinguaswapWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", LinguaswapWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/email/register", UserRegistrationController, :new
    post "/email/register", UserRegistrationController, :create
  end

  scope "/", LinguaswapWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/email/settings", UserSettingsController, :edit
    put "/email/settings", UserSettingsController, :update
    get "/email/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  live_session :require_authenticated_user,
    on_mount: [{LinguaswapWeb.UserAuth, :require_authenticated}] do
    scope "/", LinguaswapWeb do
      pipe_through :browser

      live "/dashboard", DashboardLive
    end
  end

  scope "/", LinguaswapWeb do
    pipe_through [:browser]

    get "/email/log-in", UserSessionController, :new
    get "/email/log-in/:token", UserSessionController, :confirm
    post "/email/log-in", UserSessionController, :create
    delete "/email/log-out", UserSessionController, :delete
  end
end
