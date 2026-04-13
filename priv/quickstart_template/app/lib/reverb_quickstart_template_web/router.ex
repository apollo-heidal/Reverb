defmodule ReverbQuickstartTemplateWeb.Router do
  use ReverbQuickstartTemplateWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReverbQuickstartTemplateWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  scope "/", ReverbQuickstartTemplateWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes do
      # in each liveview, add one of the following at the top of the module:
      #
      # If an authenticated user must be present:
      # on_mount {ReverbQuickstartTemplateWeb.LiveUserAuth, :live_user_required}
      #
      # If an authenticated user *may* be present:
      # on_mount {ReverbQuickstartTemplateWeb.LiveUserAuth, :live_user_optional}
      #
      # If an authenticated user must *not* be present:
      # on_mount {ReverbQuickstartTemplateWeb.LiveUserAuth, :live_no_user}
    end
  end

  scope "/", ReverbQuickstartTemplateWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/captain", CaptainController, :index
    post "/captain", CaptainController, :create
    auth_routes AuthController, ReverbQuickstartTemplate.Accounts.User, path: "/auth"
    sign_out_route AuthController

    # Remove these if you'd like to use your own authentication views
    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [{ReverbQuickstartTemplateWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    ReverbQuickstartTemplateWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                  ]

    # Remove this if you do not want to use the reset password feature
    reset_route auth_routes_prefix: "/auth",
                overrides: [
                  ReverbQuickstartTemplateWeb.AuthOverrides,
                  Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                ]

    # Remove this if you do not use the confirmation strategy
    confirm_route ReverbQuickstartTemplate.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      overrides: [ReverbQuickstartTemplateWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI]

    # Remove this if you do not use the magic link strategy.
    magic_sign_in_route(ReverbQuickstartTemplate.Accounts.User, :magic_link,
      auth_routes_prefix: "/auth",
      overrides: [ReverbQuickstartTemplateWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI]
    )
  end

  # Other scopes may use custom stacks.
  # scope "/api", ReverbQuickstartTemplateWeb do
  #   pipe_through :api
  # end
end
