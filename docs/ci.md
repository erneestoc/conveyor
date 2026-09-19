# Conveyor in CI

Give CI its own API key (Settings → API keys, or on a server node:
`bin/conveyor eval 'IO.puts(elem(Conveyor.Projects.create_api_key(Conveyor.Projects.ensure_default_project!(), %{name: "ci"}), 2))'`)
and keep it in the CI secret store. Tags carry the context you will filter by later.

## GitHub Actions

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: bazelbuild/setup-bazelisk@v3
      - name: bazel test
        env:
          CONVEYOR_API_KEY: ${{ secrets.CONVEYOR_API_KEY }}
        run: |
          bazel test //... \
            --bes_backend=grpcs://conveyor.example.com:1985 \
            --bes_results_url=https://conveyor.example.com/invocation/ \
            --bes_header=x-api-key=$CONVEYOR_API_KEY \
            --bes_upload_mode=wait_for_upload_complete --bes_timeout=120s \
            --build_event_upload_max_retries=10 \
            --build_metadata=CI=true \
            --build_metadata=BRANCH=${GITHUB_REF_NAME} \
            --build_metadata=COMMIT=${GITHUB_SHA} \
            --build_metadata=PR=${{ github.event.number }} \
            --build_metadata=JOB_URL=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}
```

Bazel prints the `--bes_results_url` link at the start of the build, so it appears in the
job log. Never pass the key on the command line of a public log; `--bes_header` values
are redacted from the stored command line by Conveyor, but the CI runner's own log is not.

## Buildkite

```yaml
steps:
  - label: ":bazel: test"
    env:
      CONVEYOR_API_KEY: "${CONVEYOR_API_KEY}"   # from the pipeline's secret store
    command: |
      bazel test //... \
        --bes_backend=grpcs://conveyor.example.com:1985 \
        --bes_results_url=https://conveyor.example.com/invocation/ \
        --bes_header=x-api-key=$$CONVEYOR_API_KEY \
        --bes_upload_mode=wait_for_upload_complete --bes_timeout=120s \
        --build_event_upload_max_retries=10 \
        --build_metadata=CI=true \
        --build_metadata=BRANCH=$$BUILDKITE_BRANCH \
        --build_metadata=COMMIT=$$BUILDKITE_COMMIT \
        --build_metadata=JOB_URL=$$BUILDKITE_BUILD_URL
```

## What to look at

- Dashboard → segment **CI** for success rate, p50/p90/p99 duration and cache hit rate
  over time; the query box accepts the same language as the builds list
  (`branch:main ci:true status:failed started>-7d`).
- Tests → flaky and failing tests across CI builds, with the last build that ran them.
- A failed build's Overview shows the failing targets and test output first.
