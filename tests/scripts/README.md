# Scripts

Two manual verification scripts, plus three offline chart-bump tools.

## Offline, no cluster needed

| Script | Use it when |
|---|---|
| [`chart-values-diff.sh`](#chart-values-diff) | Considering a candidate `n8n_chart_version`. Diffs the pinned and candidate `values.yaml` text. |
| [`check-n8n-chart.sh`](#chart-render-check) | After temporarily moving `n8n_chart_version`'s default to the candidate. Renders this module's own values through the real chart and asserts the behaviors the module's code depends on; it has no candidate argument of its own, so it only ever sees whatever the default currently is. |
| [`check-helm-chart-coverage.sh`](#chart-coverage-check) | After moving `n8n_chart_version`'s default. Fails if `docs/helm-chart-coverage.md` still claims the old version, or if the chart grew a top-level key the doc never mentions. |

All three need only `helm` (the render check also needs `terraform`, `jq`, and `openssl`); none touches a cluster or credentials. `Taskfile.yml` wraps them as `task chart-diff CANDIDATE=<version>`, `task chart-check` and `task chart-coverage`.

### Chart values diff

```bash
tests/scripts/chart-values-diff.sh 1.18.0
```

Prints a text diff of `values.yaml` between the pinned `n8n_chart_version` and the candidate, via `helm show values`. Read it to decide whether a key this module sets moved, was renamed, or changed its default; it does not inspect this module's own values or templates, only the chart's documented defaults.

### Chart render check

```bash
task chart-check
# or: terraform init -backend=false && tests/scripts/check-n8n-chart.sh
```

`tests/defaults.tftest.hcl` runs against the mocked providers, so it can pin the *shape* of `local.k8s_values_final` at plan time, but `helm_release.values` is unknown under plan-time mocks (AGENTS.md) and the mocked suite never calls Helm. This script does: it reads this module's real chart pin and values tree via `terraform console` against an empty throwaway state, pulls that exact chart version, and runs `helm template` against it to check things only a real render can answer, for example:

- whether `n8n_main_pdb_enabled = true` actually renders a `PodDisruptionBudget` against this module's single-replica main (chart 1.16.0 stopped doing that; earlier versions did);
- which pods carry the task-runner sidecar in this module's always-on queue mode;
- whether the worker Deployment's `spec.replicas` is still rendered once an autoscaler owns the count;
- what an unset `n8n_image_tag` actually resolves to;
- whether the chart's own webhook Ingress still routes every prefix this module advertises (`/mcp` included).

Run it after temporarily moving `n8n_chart_version`'s default to the candidate being evaluated: it has no candidate argument of its own and always reads whatever the default currently is, so it cannot see a candidate until the default points at one. Commit or revert that temporary move based on the result. It is not in CI: like the checkov task, it needs tools CI does not guarantee (`helm`, network egress to pull the chart), and unlike `terraform test` it is not deterministic across chart releases by design, since its whole purpose is to catch when a chart release changes one of these behaviors.
It exits non-zero if any assertion fails, after printing every `PASS`/`FAIL` line rather than stopping at the first one, so one run tells you everything a bump needs to look at.

### Chart coverage check

```bash
tests/scripts/check-helm-chart-coverage.sh
```

A stale-doc tripwire for `docs/helm-chart-coverage.md`, not a content auditor. It checks two things only: the doc's "Measured against chart **X**" line matches `n8n_chart_version`'s default, and every top-level key in that chart version's `values.yaml` appears somewhere in the doc's coverage table or its "Not currently configurable" list. It cannot tell you a row's *description* is still accurate, only that the version claim isn't stale and that the chart hasn't grown a whole new section nobody has looked at yet.

## Two manual, post-deployment scripts

Neither runs in CI: both need a live cluster, which a pull request check cannot provide.

| Script | Use it when |
|---|---|
| [`smoke-test.sh`](#smoke-test) | Always, after any deploy. Checks the deployment is healthy end to end. |
| [`verify-custom-image.sh`](#custom-image-verification) | The deployment sets `n8n_image_repository` and `n8n_custom_extensions_path` to bake community packages into the image. |

## Smoke test

Post-deployment smoke test for `terraform-kubernetes-n8n`. Verifies the deployment is healthy end to end: pod health, queue mode, KEDA, HTTPS, API, and a full webhook → worker execution.

### What it covers

| Check | What it verifies |
|---|---|
| kubectl cluster connectivity | kubectl can reach the cluster |
| Namespace exists | The configured namespace is present |
| Main / worker / webhook-processor pod health | Each deployment is at the expected ready replica count |
| Task runner sidecar (workers) | Runner sidecar is present on worker pods and connected to the broker |
| Single-main topology | one `n8n-main` replica, no `N8N_MULTI_MAIN_*` or `N8N_LICENSE_*` in the pod environment |
| Autoscalers | KEDA `ScaledObject` (workers, queue-depth) and HPAs (main, webhook-processor) |
| Redis connectivity | Worker pods see `QUEUE_BULL_REDIS_HOST` and queue-related log activity |
| HTTPS reachability | `/healthz` returns HTTP 200 over the Ingress hostname |
| HTTP → HTTPS redirect | Port 80 redirects to HTTPS |
| API connectivity (if API key set) | `/api/v1/workflows` responds with 200 |
| Workflow execution (if API key set) | Creates a webhook → set workflow, fires it, confirms success, deletes it |
| Worker scaling (opt-in) | Queues CPU-burning executions and confirms workers scale up |

### Quick start

The script reads `namespace`, `n8n_url`, and `kubectl_config_command` automatically from `terraform output`.

```bash
cd examples/homelab              # or wherever your terraform.tfstate lives
../../tests/scripts/smoke-test.sh
```

The script automatically:

1. Reads `namespace` and `n8n_url` from Terraform state
2. Runs the `kubectl_config_command` output to point kubectl at the right cluster
3. Runs all checks and prints a pass / fail / warn / skip summary

> **Note:** Run the script from the directory that holds `terraform.tfstate` (e.g. `examples/homelab/`), not from `tests/scripts/`. The script calls `terraform output` against the current working directory by default.

### API key (required for API and execution tests)

The API connectivity and workflow execution checks need an n8n API key. Without one, those checks are skipped with a warning.

1. Open your n8n instance in a browser.
2. Go to **Settings → API → Create API Key**.
3. Copy the key.

Set it before running the script:

```bash
N8N_API_KEY=your-key-here ../../tests/scripts/smoke-test.sh
```

Or persist it in a `.env` file. The script looks for `.env` next to itself first, then in the current working directory:

```bash
cp ../../tests/scripts/.env.example ../../tests/scripts/.env
# edit .env, set N8N_API_KEY, then:
../../tests/scripts/smoke-test.sh
```

### Configuration

All settings can be overridden via environment variables or a `.env` file.

| Variable | Default | Description |
|---|---|---|
| `TERRAFORM_DIR` | `$(pwd)` | Path to Terraform directory to read state from |
| `N8N_URL` | *(from `terraform output`)* | Base URL of the n8n deployment |
| `NAMESPACE` | *(from `terraform output`)* | Kubernetes namespace |
| `N8N_API_KEY` | - | API key for API and workflow execution tests |
| `DEPLOY_MODE` | *(auto-detect)* | Force `multi` (or `single`) and skip detection |
| `LOAD_TEST` | `false` | Set to `true` to run the worker scaling test |
| `LOAD_REQUESTS` | `100` | Webhook executions to fire during the load test |
| `LOAD_CONCURRENCY` | `20` | Concurrent in-flight webhook calls |
| `LOAD_SEED_JOBS` | `20` | Jobs queued in phase 1 to trigger the autoscaler |
| `LOAD_JOB_DURATION_SECS` | `10` | CPU burn per worker job (seconds) |
| `SCALE_WAIT_SECS` | `180` | Seconds to wait for the autoscaler to react |

**Priority:** `.env` values → environment variables → Terraform outputs → built-in defaults.

### Worker scaling test (opt-in)

The scaling test creates real load and is therefore opt-in:

```bash
LOAD_TEST=true N8N_API_KEY=your-key ../../tests/scripts/smoke-test.sh
```

What it does:

1. Pre-checks the autoscaler - KEDA `ScaledObject` (preferred for workers) or CPU-based HPA. Skips if neither is found, or if HPA metrics are `<unknown>` (metrics-server not ready).
2. Creates a temporary n8n workflow with a Code node that burns CPU for `LOAD_JOB_DURATION_SECS` seconds per execution.
3. Activates it and queues `LOAD_SEED_JOBS` webhook calls in phase 1 to trigger the autoscaler.
4. Polls every 15 seconds for up to `SCALE_WAIT_SECS` seconds, watching worker replicas climb.
5. Once scale-up is detected, queues the remaining `LOAD_REQUESTS - LOAD_SEED_JOBS` calls (phase 2) so the new workers visibly pick up jobs.
6. Deactivates and deletes the test workflow (cleanup runs even on failure).

If workers don't scale within the wait window, the script warns and suggests increasing `LOAD_REQUESTS` or `LOAD_JOB_DURATION_SECS`.

### Running against a remote deployment

You can run without local Terraform state, for example against a cluster managed by someone else, by setting everything explicitly:

```bash
NAMESPACE=n8n \
N8N_URL=https://n8n.example.com \
N8N_API_KEY=your-key \
./tests/scripts/smoke-test.sh
```

You're responsible for pointing kubectl at the right cluster yourself in that case (the script only switches contexts when it can read `kubectl_config_command` from Terraform).

## Custom image verification

`verify-custom-image.sh` covers what `smoke-test.sh` cannot: a deployment can be perfectly healthy and still have its baked nodes silently unloaded. The specific failure it exists to catch is **asymmetric loading**, where a node type resolves on main pods but not on workers. That looks correct in the editor and fails only when a production execution reaches the node.

```bash
cd examples/homelab
../../tests/scripts/verify-custom-image.sh
```

### What it covers

| Check | What it verifies |
|---|---|
| Image consistency | Every Running pod, every replica, runs the same image, so a half-finished rollout is not mistaken for a loading bug. A pod whose image cannot be read fails rather than being skipped |
| Task runner sidecar | The runner image resolves and nothing is stuck in `ImagePullBackOff`, the symptom of a custom `n8n_image_tag` with no `n8n_task_runner_image_tag` |
| Extensions path | `N8N_CUSTOM_EXTENSIONS` is set, and set *identically*, on main, worker, and webhook-processor |
| Shadowed directory | The path is outside `/home/node/.n8n`, which the chart mounts over on main pods only |
| Baked files on disk | At least one `*.node.js` exists under the path, on every pod type |
| Loaded node types | n8n's generated type list contains at least one `CUSTOM.*` type. This is the difference between present on disk and actually loaded |
| Boot-time installs | Warns if `N8N_REINSTALL_MISSING_PACKAGES=true`, which reintroduces the per-pod npm install that baking exists to remove |
| Execution (opt-in) | Runs a workflow using a baked node through the queue, proving a *worker* resolved the type |

### The execution check

Everything above proves main loaded the nodes. None of it proves a worker did, because workers serve no type list. Only executing a workflow that uses a baked node settles that, and it needs a workflow specific to whichever node you baked, so you supply one:

```bash
CUSTOM_NODE_WORKFLOW=./my-node-test.json \
  ../../tests/scripts/verify-custom-image.sh
```

The file is a workflow JSON with two requirements: a webhook trigger, which is what routes the execution to a worker instead of the main process, and at least one node whose `type` starts with `CUSTOM.`. The script rewrites the webhook path to a unique value and its method to `POST` (it copies the workflow before sending it, so your file is not modified), creates and activates the workflow, fires it, waits for the execution, then deactivates and deletes it.

```json
{
  "nodes": [
    { "id": "a", "name": "Webhook", "type": "n8n-nodes-base.webhook", "typeVersion": 2,
      "position": [0, 0],
      "parameters": { "httpMethod": "POST", "path": "placeholder", "responseMode": "lastNode" } },
    { "id": "b", "name": "Baked", "type": "CUSTOM.myNode", "typeVersion": 1,
      "position": [220, 0], "parameters": {} }
  ],
  "connections": { "Webhook": { "main": [[{ "node": "Baked", "type": "main", "index": 0 }]] } },
  "settings": { "executionOrder": "v1" }
}
```

Use the type name *as n8n loaded it*. A package installed from npm as `n8n-nodes-example.myNode` becomes `CUSTOM.myNode` once baked, because the custom directory loader registers everything under the package name `CUSTOM`. Run the script once without a workflow and it lists the loaded `CUSTOM.*` types.

A workflow with no `CUSTOM.*` node is rejected rather than run. It would execute and report success while proving nothing, which is worse than not running it at all.

### Settings

| Variable | Effect |
|---|---|
| `CUSTOM_NODE_WORKFLOW` | Path to the workflow JSON above. Enables the execution check (also needs `N8N_URL` and `N8N_API_KEY`) |
| `EXPECT_IMAGE_REPOSITORY` | Assert the deployed repository matches this exactly |
| `EXPECT_EXTENSIONS_PATH` | Assert `N8N_CUSTOM_EXTENSIONS` matches this exactly |

Against a deployment that sets no custom extensions path, the script warns and exits 0 rather than failing, so it is safe to run anywhere.

## Exit codes

Both scripts share these.

| Code | Meaning |
|---|---|
| `0` | All checks passed (warnings are non-fatal) |
| `1` | One or more checks failed |

The summary line always prints the counts: `Passed: X  Failed: Y  Warnings: Z  Skipped: W`.
