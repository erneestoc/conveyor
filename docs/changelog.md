# Changelog

## 0.1.0 — 2026-09-19

First release.

- Build Event Service server (gRPC) with committed-before-ack durability, per-invocation
  fencing, deduplication and resume across nodes; API keys per project with per-key limits.
- Web UI: live builds list with a query language and facets, build pages (overview, log,
  timeline, targets, tests, actions, metrics, details, events), dashboard and tests pages.
- Artifacts: profile timeline and test outputs fetched from a remote cache or the built-in
  CAS sink; disk and S3 blob stores.
- Sign-in: open mode with an admin token, or OpenID Connect with group-based admin access;
  audit log; secret scrubbing of command lines and logs.
- Operations: Prometheus metrics, health endpoints, SIGTERM drain, cluster formation
  (Kubernetes, DNS, EC2 tags, static), retention for builds and raw segments, release
  image, Kubernetes manifests, EC2 auto-scaling Terraform, Grafana dashboard.
- Load generator with chaos options and a persistence oracle; measured 1,000 concurrent
  streams at p99 ack 146 ms and zero loss through a killed node (see PLAN.md §21).
- Verified end to end with Bazel 7.6, 8.3 and 9.2.
