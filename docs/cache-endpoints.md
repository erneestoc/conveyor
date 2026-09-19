# Fetching profiles and test outputs from a remote cache

Bazel does not upload `command.profile.gz`, `test.log` or `test.xml` to the BES server. With
`--remote_cache` and `--remote_build_event_upload=minimal` it uploads them to the cache
and puts a locator into the BEP:

    bytestream://cas.example.com/main/blobs/<sha256>/<size>

The URI identifies the blob and nothing else. How Conveyor connects to `cas.example.com`
and how it authenticates is configured per project under Settings → *Remote cache
endpoints*, and only hosts configured there are ever dialled: a URI pointing anywhere
else is reported as "endpoint not configured" (this is the SSRF allow-list, see
`docs/security.md`). Credentials, TLS policy and certificate paths never come from BEP data.

Each endpoint entry is keyed by the URI authority (`host` or `host:port`) and holds:

| Field | Meaning |
|---|---|
| Connect to (override) | `[grpcs://]host[:port]` to dial instead of the URI authority (proxies, internal addresses). Default port 443 with TLS, 80 without. |
| TLS | `system roots` (public certificate), `custom CA` (a PEM file for a private CA), `mTLS` (CA file plus client certificate and key files), or `plaintext`. |
| CA / client cert / client key files | Paths on the Conveyor host, typically mounted secrets (`/etc/conveyor/secrets/...`). Validated at connect time. |
| Header + value | Static gRPC metadata such as `x-buildbuddy-api-key` or `x-api-key`. |
| Bearer token | Sent as `authorization: Bearer <token>` (gateways in front of a cache). |

Examples:

- **NativeLink, private CA, mTLS**: TLS = mTLS, CA file = the server CA, client cert/key =
  a certificate signed by the CA NativeLink's listener trusts. No headers.
- **BuildBuddy**: TLS = system roots, header `x-buildbuddy-api-key` = your key.
- **bazel-remote / a cache on the private network**: TLS = plaintext or custom CA;
  authenticate with mTLS if the gRPC listener requires it (its HTTP basic auth does not
  apply to ByteStream).
- **Conveyor's own CAS sink** (`--remote_cache=grpc://conveyor:1985`): nothing to configure;
  blobs uploaded there are served from the local store.

Lifecycle: when a build finishes, the profile is fetched by a job (retried on transport
errors, marked *unavailable* when the host is not configured or the cache no longer has
it), verified against the digest in the URI, copied into Conveyor's blob store (caches
evict; Conveyor keeps its own copy) and summarized for the timeline. Test logs and XML
reports are fetched on demand from the Tests tab through the same path.
