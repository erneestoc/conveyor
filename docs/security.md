# Conveyor security model

This document describes what Conveyor trusts, what it protects, and which controls exist.
It is kept current with the code; every control named here has a test.

## Assets

- **Build events and logs** — command lines, environment (`--client_env`), stdout/stderr,
  target names, test logs. These routinely contain secrets by accident.
- **Artifacts** — JSON profiles, test logs and reports, files uploaded through the CAS
  sink or the HTTP API.
- **API keys** — grant ingest, upload and (later) read access to a project.
- **The settings surface** — projects, keys, cache endpoint credentials, access groups.
- **Availability** — a BES outage slows or fails every Bazel invocation pointed at it
  (Bazel's default retry budget is short; see `--build_event_upload_max_retries`).

## Trust boundaries

| Boundary | Who is on the other side | Controls |
|---|---|---|
| gRPC `:1985` (BES, ByteStream, CAS) | Bazel clients on CI and laptops | API keys (`BES_INGEST_AUTH=api_key`), scopes (`ingest` for BES; `ingest` or `upload` for the CAS sink), per-key limits, secret scrubbing |
| HTTP `/api/v1` | Scripts (`tools/bes-upload-profile`), CI | API keys with the `upload` scope, size limits, project ownership checks, audit log |
| HTTP UI | Engineers | `AUTH_MODE=oidc` (OIDC + PKCE + state + nonce, RS256 ID tokens), roles, per-project allowed and admin groups; or `AUTH_MODE=open` with `ADMIN_TOKEN` gating Settings |
| Any read | Everyone | The viewer's project set is a SQL restriction on every query (see below) |
| Outbound to remote caches | Operator-configured caches | Only hosts listed as a project's cache endpoints are ever dialled (SSRF allow-list); TLS with the system trust store |
| PostgreSQL, blob store | Operator infrastructure | Out of scope: protect with network policy, disk encryption, IAM for S3 |

## Threats and mitigations

### Secrets leaking through build events
Bazel copies the client environment into the command line and progress output may echo
tokens. `Conveyor.Ingest.Scrub` rewrites `--bes_header`/`--remote_header` values, URL
credentials, `token=` parameters and `Bearer` tokens before anything reaches disk; the
fixtures are scrubbed and tests assert that header values never appear in stored
frames. Scrubbing is best-effort: treat build logs as sensitive and restrict who can view
a project (groups) rather than relying on redaction alone.

### Stolen or leaked API keys
Keys are random (`conveyor_<id>_<43 chars>`), only `sha256(secret)` is stored, keys are
shown once, can expire, be rotated with a grace period and revoked immediately (cache
invalidation across nodes via PubSub). Scopes limit blast radius: an `upload` key cannot
publish build events. Every key use updates `last_used_at`/`last_used_ip`; uploads and
key changes are audited.

### Abusive or runaway clients (availability)
`Conveyor.Limits`: concurrent streams per key (`RESOURCE_EXHAUSTED`), events per second
per key (senders are slowed, never failed, because a failed stream makes Bazel resend
everything), build log bytes per invocation (truncated with a marker). gRPC bodies are
capped (`max_body_size`), CAS batches at 4 MB, artifacts at `ARTIFACT_MAX_MB`, uploads are
spooled to disk while hashing so memory stays bounded. Postgres pool overload turns into
latency, not errors (`queue_target`/`queue_interval`).

### Server-side request forgery through `bytestream://` URIs
BEP files carry arbitrary URIs. Conveyor only connects to hosts an admin configured as a
cache endpoint for that project; anything else is reported as "endpoint not configured".
The URI is a locator only: where to connect (endpoint override), TLS policy (system
roots, custom CA, mTLS from mounted secret files) and request authentication (headers,
bearer token) come exclusively from the project's configuration (`docs/cache-endpoints.md`).
Blobs already present locally are served without any network access.

### The project boundary

Visibility is not a filter applied in the page. `Conveyor.Accounts.Scope.project_ids/1`
(all projects for global admins, otherwise the projects the viewer may see) is passed into
every read: the builds list and its facets, invocation lookups (and with them the build
pages, downloads and artifacts), dashboards and test health, and execution-log
comparisons, which stay inside the project and branch. Uploads with an API key treat an
invocation of another project as not found, never as a conflict. `/metrics` without
`METRICS_TOKEN` needs an admin session. Project admins (admin groups) manage keys,
storage, cache endpoints and segments of their project; every mutation authorizes against
the project taken from the record, so a hidden form field pointing at another project is
a 404. `test/conveyor_web/project_boundary_test.exs` walks every route with a
project-bound parameter as a user of project A and asserts 404 on project B's ids and
slugs; a new route without an entry fails the test.

### Path traversal and content confusion in the blob store
Blob keys are validated SHA-256 hex digests before any path or object key is built;
content is hashed while written and refused when it does not match the declared digest.
Artifact content types supplied by clients are sanitized (never HTML/SVG/JavaScript) and
served as attachments with `nosniff`.

### Hostile XML/JSON
JUnit reports are parsed with OTP's SAX parser with external entities disabled. Profiles
are scanned object by object without loading the whole file; malformed input cancels the
job.

### Web attacks
Per-request nonce CSP (`script-src 'self' 'nonce-…'`, `worker-src 'self'`,
`frame-ancestors 'none'`, `form-action 'self'`), `X-Frame-Options: DENY`,
`Referrer-Policy`, `Permissions-Policy`, `X-Content-Type-Options`, CSRF tokens on forms,
`SameSite=Lax` signed session cookies (marked `Secure` behind HTTPS; `FORCE_SSL=true`
adds HTTPS redirects and HSTS). Sessions are renewed on login and dropped on logout.
`return_to` after login accepts local paths only.

### Sign-in
OIDC authorization code flow with PKCE, `state` and `nonce` bound to the session, ID
tokens verified against the provider's JWKS (RS256), users upserted per login so role and
group changes at the provider take effect at the next sign-in. Optional
`ALLOWED_EMAIL_DOMAINS`. Admins from `ADMIN_EMAILS` / `OIDC_ADMIN_GROUPS`. In open mode,
`ADMIN_TOKEN` (compared in constant time) unlocks Settings; without it, Settings are open
— do not expose an open-mode server beyond a trusted network.

### Audit
`audit_log` records sign-ins (and failures), admin unlocks, sign-outs, project and key
changes, cache endpoint and group changes, and API uploads, with actor, subject, IP and
metadata. The latest entries are shown in Settings.

## Tooling

`mix precommit` runs `sobelow --exit` (config in `.sobelow-conf`; the ignored
`Traversal.FileModule` and `SQL.Query` findings are on digest-validated paths and
date-derived partition names) and `mix deps.audit`. CI also runs `mix hex.audit`.

### Accepted advisories
- `cowlib` EEF-CVE-2026-43969 (cookie encoder header injection): Conveyor's gRPC path
  never sets cookies through cowlib; the web endpoint runs on Bandit. Re-evaluate when a
  fixed cowlib is released.

## Reporting
Please report vulnerabilities privately to the maintainers before opening an issue.
