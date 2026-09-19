# Conveyor on Kubernetes

Three replicas clustered through a headless service (`CLUSTER_STRATEGY=k8s`), S3 for
blobs (required when clustered), an external PostgreSQL (`DATABASE_URL` in the secret).

    kubectl apply -f namespace.yaml
    kubectl -n conveyor create secret generic conveyor \
      --from-literal=DATABASE_URL=ecto://user:pass@postgres.example/conveyor \
      --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 48)" \
      --from-literal=RELEASE_COOKIE="$(openssl rand -base64 32)" \
      --from-literal=OIDC_CLIENT_SECRET=... --from-literal=METRICS_TOKEN=...
    kubectl apply -f configmap.yaml -f service.yaml -f deployment.yaml -f hpa.yaml -f ingress.yaml

Bazel: `--bes_backend=grpcs://bes.example.com:443 --bes_header=x-api-key=... --bes_results_url=https://conveyor.example.com/invocation/ --build_event_upload_max_retries=10`.

Rolling updates: the readiness probe flips to 503 as soon as a pod starts draining
(SIGTERM), new streams are refused with UNAVAILABLE so Bazel retries on another pod, and
`terminationGracePeriodSeconds` leaves `SHUTDOWN_DRAIN_SECONDS` for open streams.
