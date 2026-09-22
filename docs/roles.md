# Roles and the project boundary

Who can see and do what, in one table. The project is the unit of separation: every
build, key, blob and setting belongs to exactly one project.

| | Viewer | Project admin | Global admin |
|---|---|---|---|
| Who | signed-in user (OIDC), or anyone in open mode | member of a project's **admin groups** | `ADMIN_EMAILS` / `OIDC_ADMIN_GROUPS`, or the admin token in open mode |
| Sees | projects with no allowed groups, plus those whose **allowed groups** include one of theirs | the same, plus the projects they administer | every project, archived ones included |
| Builds, dashboards, tests, downloads, artifacts | of visible projects only (restricted in SQL; other ids are 404) | same | all |
| `/p/<slug>/settings`: API keys, retention and blob prefix, cache endpoints, segments, the project's audit trail | no | yes, for their projects | yes |
| `/settings`: create and archive projects, allowed groups, admin groups, every project's keys, the global audit log | no | no | yes |
| `/metrics` | with `METRICS_TOKEN` | with `METRICS_TOKEN` | also with a session when no token is set |

API keys are per project and carry scopes: `ingest` (Bazel's `--bes_header`), `upload`
(the HTTP artifact API). A key of project A cannot read, upload to or finish an invocation
of project B; the server answers "not found". Keys can carry default tags, expire, be
rotated with a grace period and revoked; each has its own stream and event-rate limits.

Every mutation on a project authorizes against the project taken from the record being
changed, never from the form alone. The guarantee is tested for every route: a user of
project A gets 404 on project B's ids and slugs (`test/conveyor_web/project_boundary_test.exs`).

Blobs (profiles, test outputs, cache uploads) follow the same rule: keyed by project and
stored under the project's own prefix, so operators can apply bucket policies, lifecycle
rules or deletion per project. See [Sign-in and access](auth.md) for the identity provider
setup and [Security model](security.md) for the threat model.
