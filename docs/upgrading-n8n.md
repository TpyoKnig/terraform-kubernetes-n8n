# Upgrading n8n

This covers bumping the deployed n8n version on an existing deployment. It does not cover upgrading this module or its providers; see [Stability and versioning](../README.md#stability-and-versioning).

## `kubernetes` provider requirement `~> 2.0` -> `~> 3.0`

Not an n8n version change, but something an existing deployment's own root
module needs to account for on its next `terraform init`. This module's
`required_providers` constraint on `hashicorp/kubernetes` changed to
`~> 3.0` (alongside `hashicorp/time`'s to `~> 0.14`), matching the AWS,
Google and Azure siblings.

**Effect on an existing deployment:** if your own root module also declares
a `kubernetes` provider requirement, for example at `~> 2.0`, and that range
does not admit `~> 3.0`, `terraform init` fails with a version constraint
conflict. Widen your own constraint to `~> 3.0` (or an unconstrained range)
before picking up this module version. If you never declared your own
`kubernetes` requirement and only relied on this module's, nothing to do
beyond letting `terraform init -upgrade` resolve the new provider version.

The next `terraform plan`/`apply` prints a cosmetic "Deprecated Resource"
warning for four `kubernetes_secret` resources (`n8n`, `n8n_db`, `n8n_redis`,
`n8n_ca_bundle`): kubernetes provider 3.x deprecates the unversioned
resource types in favor of their `_v1` equivalents. No plan diff and no
object changes follow from the warning alone. The module does not rename the
Secrets: the provider has no `moved` support for that rename
(`hashicorp/terraform-provider-kubernetes` issue #2812), and renaming
without one would destroy and recreate them.

## `kubernetes_namespace` renamed to `kubernetes_namespace_v1`, provider `~> 3.3`

The namespace the module creates (`create_namespace = true`) and the
namespace each example's `storage.tf` owns are now `kubernetes_namespace_v1.n8n`,
each behind a `moved` block. The module's `kubernetes` constraint is
`~> 3.3`: 3.3.0 is the first release where the `_v1` namespace supports
`moved` from the unversioned type. Older 3.x releases fail the plan with
`Move Resource State Not Supported`.

**Effect on an existing deployment:** `terraform init -upgrade`, then plan.
The namespace appears as moved, with no destroy. Confirm that before
applying: a plan that destroys a namespace is never routine. A one-time
in-place update for explicitly empty `metadata` maps is expected and safe.

If an example-owned namespace still sits at the address the `storage.tf`
comment tells you to `terraform state mv` from, run that `state mv` before
upgrading. `state mv` cannot change a resource's type, so it targets the
old `kubernetes_namespace.n8n` address and the `moved` block finishes the
rename on the next apply.

## Version inputs

| Variable | Controls | Default |
| --- | --- | --- |
| `n8n_chart_version` | The [n8n Helm chart](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n) version, which determines the chart's templates, defaults, and which values it accepts. | `"1.17.0"`, pinned |
| `n8n_image_tag` | The n8n application image tag actually running inside the pods. | `"2.44.5"`, pinned |
| `n8n_task_runner_image_tag` | Task runner image tag; keep aligned with the underlying n8n version when using a custom application tag. | `null`, meaning the application image tag |

Bumping the image tag alone gets you a new n8n version without changing the chart's templates or value schema. Bumping the chart version can also change what values the chart accepts, so treat it as the larger-blast-radius change of the two.

The image tag is pinned rather than left to the chart, and setting `n8n_image_tag = null` hands it back. Do that only if you have a reason to: before chart 1.12.0 the chart's own default was the floating `stable` tag, resolved per node at pull time under `IfNotPresent`, so a node holding a cached layer could keep serving whatever it pulled whenever that was. From chart 1.12.0 on, an unset tag resolves to the pinned chart's own appVersion instead (2.44.5 for chart 1.17.0) - a fixed version, but still not one this module's own CHANGELOG controls, so a chart bump with the tag left null moves the running n8n version silently along with it.

### Before bumping the runners image

`task_runners_config.tf`'s `kubernetes_config_map_v1.task_runners_config`
mounts a launcher config (`n8n-task-runners.json`) that replaces the
`n8nio/runners` image's own config entirely, including the interpreter and
entrypoint paths (`/usr/local/bin/node`,
`/opt/runners/task-runner-python/.venv/bin/python`) that belong to that
image. A runners-image release that moves any of those paths breaks both
the JavaScript and Python runners at once, with nothing pointing at this
file as the reason, because the mounted config silently wins over the
image's own. Before bumping `n8n_task_runner_image_tag` (or `n8n_image_tag`
when it also moves the runner, see above), pull the new image and extract
its own copy of the launcher config to diff against what this file renders:

```bash
docker create --name n8n-runners-check n8nio/runners:<new-tag>
docker cp n8n-runners-check:/etc/n8n-task-runners.json ./new-runners-config.json
docker rm n8n-runners-check
diff \
  <(jq -S 'del(.. | .["allowed-env"]?, .["env-overrides"]?)' ./new-runners-config.json) \
  <(jq -S 'del(.. | .["allowed-env"]?, .["env-overrides"]?)' <<< "$(kubectl get configmap -n <namespace> <release>-task-runners -o jsonpath='{.data.n8n-task-runners\.json}')")
```

This filters out `allowed-env` and `env-overrides` before diffing: this
module's rendered config always carries those two keys, by design (see
`task_runners_config.tf`), while the stock image's own shipped config does
not, so an unfiltered diff can never be clean regardless of whether
`command`, `args` or any path field actually changed. A clean filtered diff
means the bump is safe; a difference means this module's rendered config
needs updating alongside the tag.

## Valkey restarts during the upgrade

On an existing deployment that uses the in-cluster Valkey, expect the Valkey
pod to be replaced once in the same apply: the chart bump from `0.11.0` to
`0.12.0` changes its image, and this module renders the Valkey Deployment with
the `Recreate` strategy (a rolling update cannot work against the single
`ReadWriteOnce` volume), so the old pod stops before the new one starts.

Measured upgrading a deployment from the last public release (`0.3.1`) to this
version: the Valkey replacement took 32 to 37 seconds to become ready, the main
and both worker pods crashed once on Redis loss and restarted, and the webhook
host returned errors for about 59 seconds (50 of 94 requests sent once a
second). An earlier run that also changed other settings in the same apply saw
21 seconds and 37 seconds, so treat these as the order of magnitude, not a
promise.

n8n gives up on Redis after `n8n_redis_timeout_threshold`, which is about 11
seconds of outage at its default, and then exits and restarts. The same upgrade
also rolls every n8n pod for the chart bump.

To avoid it, upgrade in a quiet window. To soften it, raise
`n8n_redis_timeout_threshold` (60000 rode out a 48 second outage in this
module's measurements, see that input's description) in an apply of its own
before the upgrade, so the n8n pods already tolerate the Valkey restart when it
happens. Jobs that are still waiting in the queue are not lost: they live in
Valkey's data, which survives on its volume, and with
`valkey_append_only_enabled` they survive a crash as well. An execution a
worker had already claimed when the pods went down is different: n8n sets
Bull's `maxStalledCount` to 0, so a claimed job that is interrupted is not
retried.

## `n8n_execution_concurrency_limit` default `100` -> `-1`

Not a chart or image bump, but it changes behavior on the next apply same as
one. n8n 2.44.5's `worker.ts` reads `N8N_CONCURRENCY_PRODUCTION_LIMIT` before
the worker's own `--concurrency` flag, and only falls back to the flag when
that env var is `-1`. With the module's old default of `100`, every worker
independently ran at its own concurrency ceiling of 100 regardless of
`n8n_worker_concurrency`, so an already-running worker could absorb an
entire burst well under 100 jobs by itself before KEDA had scaled anything:
queue depth never crossed `n8n_worker_keda_jobs_per_replica`, and replicas
added afterward found nothing left to pull.

**Effect on the next apply:** effective per-worker concurrency drops from
100 to `n8n_worker_concurrency` (default `10`), and every worker pod rolls
once as its env changes. Before applying, size `n8n_worker_concurrency` and
`n8n_worker_keda_min_replicas` / `_max_replicas` for the new effective
ceiling, `replicas x n8n_worker_concurrency`. Set
`n8n_execution_concurrency_limit = 100` to keep the previous behavior. See
[`docs/operations.md` → Worker autoscaling](./operations.md#how-worker-concurrency-and-scale-out-interact).

## Chart 1.10.0 -> 1.17.0 (this module's current pin)

Behavior that changed on this bump, verified by rendering this module's values through both chart versions (`tests/scripts/check-n8n-chart.sh`):

- **Worker replica count resets once, on the first upgrade.** Chart 1.13.0 stopped rendering `spec.replicas` on the worker Deployment once an autoscaler owns the count (KEDA with real triggers, or the CPU HPA while KEDA is off) - a condition this module's worker always satisfies. Kubernetes defaults an omitted `spec.replicas` to 1 only on create, but the first `helm upgrade` onto this chart version removes the key from the manifest it applies, and the worker pool drops to 1 replica until the autoscaler notices and scales it back to the configured floor. Expect a brief dip in worker capacity right after the upgrade, not a stuck deployment; no input change is needed.
- **Main pods no longer carry the task-runner sidecar.** With `n8n_task_runners_enabled = true`, the sidecar now runs on worker pods only, since this module always runs in queue mode (main offloads execution to workers). This only matters if something outside the module assumed the main pod had one; the module's own wiring (`n8n_task_runner_*` inputs, the task-runner ConfigMap) was already written for the worker-only case.
- **`n8n_main_pdb_enabled = true` no longer creates a PodDisruptionBudget.** Chart 1.16.0 gates `pdb.yaml` on main running more than one replica, which this module never does, so the object this input used to risk (wedging a node drain at `minAvailable = 1` against one replica) simply does not render anymore. The input is unchanged and still false by default.
- **An unset `n8n_image_tag` now resolves to the chart's appVersion, not `stable`.** See the note above the table.
- **The chart's own webhook Ingress now routes `/mcp`.** This module's supplementary `kubernetes_ingress_v1.n8n_mcp` resource, which existed only to cover that gap, was removed: Terraform destroys it on the first apply after this bump for any deployment with `create_ingress = true`. Nothing to configure; this is a one-time, expected resource deletion in the plan.
- **`N8N_WEBHOOK_URL` replaces `WEBHOOK_URL`** as the chart-rendered env var name (n8n deprecated the old one as of n8n 2.35.0). Only relevant if you read it off a running pod directly; the `n8n_webhook_url` output and every workflow-facing behavior are unchanged.
- **Worker readiness and liveness probes now check real health, not just process existence.** Chart 1.17.0 flips `redis.healthCheck.enabled`'s own default to `true` (n8n-io/n8n-hosting#233), which this module does not override, so the worker's readiness probe moves from an always-passing `pgrep -f 'n8n worker'` exec check to an `httpGet` probe against `/healthz/readiness` (gated on the worker's own DB and Redis connection), the liveness probe moves to `httpGet` `/healthz`, and a new startup probe (up to 300s, `failureThreshold: 30` at `periodSeconds: 10`) holds off liveness while database migrations run. **Effect on the next apply:** every worker pod rolls once as its probes and the new `QUEUE_HEALTH_CHECK_ACTIVE` env var change. A worker that was previously marked Ready the instant its process started now waits for its own DB/Redis connection first, which is the intended behavior but means a cold worker can take slightly longer to receive its first job after a rollout or scale-up.

## Before bumping

1. Read the breaking-changes doc for every major version you're crossing, not just the target: [n8n v2.0 breaking changes](https://docs.n8n.io/2-0-breaking-changes/), [n8n v3.0 breaking changes](https://docs.n8n.io/changelog/v30-breaking-changes) (scheduled October 2026). Jumping from, say, 1.x straight to a 3.x tag means both apply.
2. Check whether the target n8n version needs a newer chart version. If the chart's own `values.yaml` schema changed (new keys under `queueMode`, `taskRunners`, etc.), you need `n8n_chart_version` bumped too, not just `n8n_image_tag`. Compare `helm show values oci://ghcr.io/n8n-io/n8n-helm-chart/n8n --version <candidate>` against the version currently pinned.
3. Take and verify a database backup - `kubectl cnpg backup`, a `pg_dump` against the rw Service, or whatever your external Postgres offers. Helm cannot roll back database migrations.

## Bumping

1. Set `n8n_image_tag`, any required `n8n_chart_version`, and, when using a custom application tag, the matching `n8n_task_runner_image_tag`.
2. `terraform plan` and review the diff. `atomic = true` rolls back Kubernetes resources after a failed rollout, not PostgreSQL migrations.
3. `terraform apply`. Watch the main and worker pods through the rollout:

   ```bash
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=main -w
   ```

   ```bash
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=worker -w
   ```

4. Confirm the version actually running matches what you set, on a main pod
   and on every worker pod:

   ```bash
   kubectl exec -n <namespace> <main-pod> -c n8n-main -- n8n --version
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=worker -o name | \
     xargs -I{} kubectl exec -n <namespace> {} -c n8n-worker -- n8n --version
   ```

   A rolling `terraform apply` can leave main and some workers on the new
   tag while other workers are still mid-rollout on the old one. Treat any
   mismatch as a state to finish (wait for the rollout to converge) or
   revert (roll back the tag), not one to leave running: workers on
   different n8n versions can process the same Bull queue with different
   migration and feature assumptions.

## Rolling back

Do not only restore the old tags. If the upgrade ran database migrations, stop n8n and either run `n8n db:revert` on the current version once per reversible migration or restore the pre-upgrade database. Check release notes for irreversible migrations. Then restore the previous chart, application, and task-runner tags and apply. See n8n's [reverting an upgrade](https://docs.n8n.io/deploy/host-n8n/install-options/install-with-npm/#reverting-an-upgrade) guidance.

If the release is stuck in `pending-rollback` from a failed upgrade, you cannot `terraform apply` your way out of it directly; the release must be unstuck first. See [Recovery from a stuck `pending-rollback` release](./troubleshooting.md#recovery-from-a-stuck-pending-rollback-release).
