defmodule ConveyorWeb.AuthController do
  @moduledoc """
  Sign-in: the admin token form in open mode, and the OpenID Connect flow (authorization
  code with PKCE, `state` and `nonce` kept in the session) in OIDC mode.
  """
  use ConveyorWeb, :controller

  alias Assent.Strategy.OIDC
  alias Conveyor.Accounts
  alias ConveyorWeb.Plugs.Auth, as: AuthPlug

  def login(conn, _params) do
    render(conn, :login,
      mode: Accounts.mode(),
      admin_token?: Accounts.admin_token() != nil,
      page_title: "Sign in"
    )
  end

  def admin(conn, params) do
    token = params["token"] || ""
    expected = Accounts.admin_token()

    if is_binary(expected) and Plug.Crypto.secure_compare(token, expected) do
      {return_to, conn} = pop_return_to(conn, ~p"/settings")

      conn
      |> configure_session(renew: true)
      |> put_session(:admin, true)
      |> put_flash(:info, "Settings unlocked")
      |> redirect(to: return_to)
    else
      conn |> put_flash(:error, "Invalid admin token") |> redirect(to: ~p"/auth/login")
    end
  end

  def oidc(conn, _params) do
    # Assent sends :nonce verbatim and keeps it in session_params for the callback check.
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    case OIDC.authorize_url(Keyword.put(oidc_config(conn), :nonce, nonce)) do
      {:ok, %{url: url, session_params: session_params}} ->
        conn |> put_session(:oidc_params, session_params) |> redirect(external: url)

      {:error, error} ->
        conn
        |> put_flash(:error, "Could not start sign-in: #{describe(error)}")
        |> redirect(to: ~p"/auth/login")
    end
  end

  def callback(conn, params) do
    session_params = get_session(conn, :oidc_params) || %{}
    conn = delete_session(conn, :oidc_params)
    config = Keyword.put(oidc_config(conn), :session_params, session_params)

    with {:ok, _state} <- Map.fetch(session_params, :state) |> in_progress(),
         {:ok, %{user: claims}} <- OIDC.callback(config, params),
         {:ok, user} <- Accounts.upsert_from_claims(claims) do
      {return_to, conn} = pop_return_to(conn, ~p"/")

      conn
      |> configure_session(renew: true)
      |> put_session(:user_id, user.id)
      |> redirect(to: return_to)
    else
      {:error, :domain_not_allowed} -> failed(conn, "your email domain is not allowed")
      {:error, :no_email} -> failed(conn, "the identity provider returned no email address")
      {:error, error} -> failed(conn, describe(error))
    end
  end

  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: if(Accounts.mode() == :oidc, do: ~p"/auth/login", else: ~p"/"))
  end

  defp in_progress({:ok, state}), do: {:ok, state}
  defp in_progress(:error), do: {:error, "no sign-in in progress (session expired?); start again"}

  defp failed(conn, reason) do
    conn |> put_flash(:error, "Sign-in failed: #{reason}") |> redirect(to: ~p"/auth/login")
  end

  defp oidc_config(conn), do: Accounts.oidc_config(url(conn, ~p"/auth/oidc/callback"))

  defp pop_return_to(conn, default) do
    return_to = get_session(conn, :return_to)
    {AuthPlug.safe_return_to(return_to || default), delete_session(conn, :return_to)}
  end

  defp describe(%{message: message}) when is_binary(message), do: message
  defp describe(error) when is_binary(error), do: error
  defp describe(error), do: inspect(error)
end
