defmodule ConveyorWeb.AuthHTML do
  @moduledoc "Sign-in page."
  use ConveyorWeb, :html

  def login(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      projects={[]}
      project={nil}
      current_path="/auth/login"
      wide={false}
    >
      <h1 class="text-lg font-semibold tracking-tight">Sign in</h1>

      <div :if={@mode == :oidc} class="mt-4 rounded-md border border-base-300 p-4">
        <p class="text-sm text-base-content/70">
          Conveyor uses your organization's identity provider.
        </p>
        <a
          href={~p"/auth/oidc"}
          id="oidc-login"
          class="mt-3 inline-block rounded bg-primary px-3 py-1.5 text-sm font-medium text-primary-content hover:opacity-90"
        >
          Continue with single sign-on
        </a>
      </div>

      <div :if={@mode == :open} class="mt-4 rounded-md border border-base-300 p-4">
        <p class="text-sm text-base-content/70">
          This Conveyor runs in open mode: everyone can view builds without signing in.
        </p>
        <form
          :if={@admin_token?}
          action={~p"/auth/admin"}
          method="post"
          id="admin-token-form"
          class="mt-3 flex items-end gap-2"
        >
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <label class="flex flex-col gap-1 text-xs">
            <span class="text-base-content/60">Admin token (ADMIN_TOKEN)</span>
            <input
              type="password"
              name="token"
              class="rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
            />
          </label>
          <button class="rounded bg-primary px-3 py-1.5 text-sm font-medium text-primary-content hover:opacity-90">
            Unlock settings
          </button>
        </form>
        <p :if={!@admin_token?} class="mt-2 text-xs text-base-content/60">
          No <code class="font-mono">ADMIN_TOKEN</code>
          is configured, so Settings are open to everyone.
          Set one, or switch to <code class="font-mono">AUTH_MODE=oidc</code>, before exposing this server.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
