# Sign-in and access

`AUTH_MODE` selects how people sign in to the web UI. Bazel clients authenticate with API
keys regardless of this setting (`BES_INGEST_AUTH=api_key`, the production default).

## `AUTH_MODE=open` (default)

Everyone who can reach the UI can read builds. Settings (projects, API keys, cache
endpoints, audit log) require `ADMIN_TOKEN`, entered once on the login page. Use it behind
a VPN or for a trial.

## `AUTH_MODE=oidc`

Any OpenID Connect provider (Okta, Google, Entra ID, Keycloak, Auth0). Register a web
application with the callback `https://conveyor.example.com/oidc/callback` and set:

| Variable | Meaning |
|---|---|
| `OIDC_ISSUER` | Issuer URL; discovery at `<issuer>/.well-known/openid-configuration` |
| `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | The registered application |
| `OIDC_SCOPES` | Default `openid email profile`; add `groups` if your provider needs it for the claim |
| `OIDC_GROUPS_CLAIM` | Claim holding group names (default `groups`) |
| `OIDC_ADMIN_GROUPS` | Comma-separated groups that get Settings access |
| `ADMIN_EMAILS` | Comma-separated emails that get Settings access (no groups needed) |
| `ALLOWED_EMAIL_DOMAINS` | Comma-separated domains allowed to sign in (empty = any account the provider returns) |

The root page lists the projects the viewer may see (with their last seven days and links
to builds, dashboard, tests and, for their admins, settings); the cross-project builds list
is at `/builds`. Allowed groups per project are managed in Settings, and so are **admin
groups**: members
administer that project at `/p/<slug>/settings` (API keys, retention and blob prefix,
remote cache endpoints, dashboard segments, the project's audit trail) without seeing the
global Settings page or other projects. Who may see or administer a project stays with the
global admins (`ADMIN_EMAILS` / `OIDC_ADMIN_GROUPS`). The project is the hard boundary:
every read (builds list and facets, invocation pages, downloads and artifacts, dashboards
and test health, execution-log comparisons, API uploads) is restricted in the query itself
to the projects the viewer may see, so another project's ids and slugs are simply not found
(`test/conveyor_web/project_boundary_test.exs` walks every route to prove it). Sessions are cookie-based and expire
with the browser session; every admin action is written to the audit log (Settings →
Audit).

Provider notes:

- **Okta**: create an OIDC Web app; add the `groups` claim to the ID token (Security → API
  → Authorization Servers → Claims) or set `OIDC_SCOPES=openid email profile groups`.
- **Google Workspace**: no group claim; use `ADMIN_EMAILS` and `ALLOWED_EMAIL_DOMAINS`.
- **Keycloak**: add a "Group Membership" mapper to the client with full path off.

See [security.md](security.md) for the threat model, key handling and accepted advisories.
