# n8n Helm chart value coverage

What this module exposes from the n8n Helm chart, what it sets for you, and
what it leaves alone. Written so you can tell before you start whether the knob
you need is a typed input, a chart default, or something you have to reach
through the escape hatch.

Measured against chart **1.10.0** (`oci://ghcr.io/n8n-io/n8n-helm-chart/n8n`,
source at [n8n-io/n8n-hosting](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n)),
which is the version `n8n_chart_version` pins by default. The chart offers 43
top-level keys. This module writes 21 of them.

Everything below was measured, not recalled: the values tree was rendered with
`terraform console` and diffed against the chart's own `values.yaml` at tag
`v1.10.0`. An earlier draft of this file was written from a render taken at
defaults, which reported every null-defaulted input as unexposed and was wrong
about four of them.

## What is pinned, and what floats

| | Input | Default | Pinned? |
| --- | --- | --- | --- |
| Chart version | `n8n_chart_version` | `1.10.0` | Yes, and it must be an exact version. The Helm provider resolves it literally, not as a constraint. |
| Chart repository | `n8n_chart_repository` | `oci://ghcr.io/n8n-io/n8n-helm-chart` | Yes. Repoint it at a private mirror if the cluster has no egress to ghcr.io. |
| n8n application version | `n8n_image_tag` | `"2.36.2"` | Yes. Bumping it is a module change with a CHANGELOG entry, on the same policy as the two rows above. Set it to null to hand the choice back to the chart, which ships `appVersion: stable`. |

**Out of the box this module pins the chart and the application**, so the
deployment is reproducible and an upgrade is a one-line diff your CI can raise,
review and roll back, which is the whole point. The module is validated against
the version it defaults to:

```hcl
n8n_chart_version = "1.10.0"    # the chart
n8n_image_tag     = "2.36.2"    # the application, and the module's default
```

Pin a different version whenever you want to move on your own schedule;
`docs/upgrading-n8n.md` covers the order that upgrade has to follow.

The one row to read twice is what `null` costs, because it is still supported
and was the default before 0.3.0. `stable` resolves to whatever is latest at
the moment a node *pulls* the image, and the chart hardcodes an `IfNotPresent`
pull policy, so a node holding a cached layer keeps serving whatever it pulled
whenever that was. Two pods rescheduled a month apart can come up on different
n8n versions, and an unplanned reschedule onto a node with no cached layer can
carry you across a major boundary such as the n8n 2.0 breaking changes, run the
one-way startup migrations, and leave the rest of the deployment querying the
new schema on the old code. None of that appears in a plan.

## Coverage by chart section

| Chart key(s) | Module coverage |
| --- | --- |
| `image.tag` | Exposed as `n8n_image_tag`, which defaults to a pinned version. Omitted when explicitly set to null, so the chart default applies. |
| `image.pullPolicy` | **Hardcoded** `IfNotPresent`. Not exposed. |
| `image.repository` | Exposed as `n8n_image_repository`. Omitted when null, so the chart's `docker.n8n.io/n8nio/n8n` applies. `n8n_image_pull_secrets` covers a private registry. |
| `queueMode.*` | Hardcoded `enabled = true`. Queue mode is the module's premise, not an option. Worker count and concurrency are exposed as `n8n_worker_*`. |
| `replicaCount` | Pinned to 1 for the main pool with no input: a second main needs leader election, which n8n gates behind a licence. |
| `webhookProcessor.*` | Exposed. Separate pool, replica count, and `disableProductionWebhooksOnMainProcess` hardcoded true. |
| `webhook.url` | Exposed as `n8n_webhook_url`. |
| `hpa.main`, `hpa.worker`, `hpa.webhookProcessor` | Exposed through the `n8n_*_hpa_*` inputs. |
| `keda.enabled`, `keda.worker` | Rendered only when `k8s_keda_installed = true`. Bounded by the `n8n_worker_keda_*` inputs. |
| `keda.webhookProcessor` | Not exposed. Queue-depth scaling applies to workers, which are what consume the queue. |
| `database.*` | Exposed. `postgres_backend` selects `cnpg` or `external`; the `db_*` inputs carry the external endpoint. |
| `database.ssl` | **Deliberately not set.** Postgres TLS is wired through environment variables instead, so the setting has one source rather than two that can disagree. `db_postgresdb_ssl_enabled` is the input. |
| `redis.*` | Exposed. `redis_backend` selects `valkey` or `external`; the `redis_*` inputs carry the external endpoint. |
| `redis.tls` | **Deliberately not set**, same reasoning as `database.ssl`: `redis_transit_encryption_enabled` wires QUEUE_BULL_REDIS_TLS through the environment instead. |
| `redis.prefix` | Exposed as `redis_key_prefix` (renders QUEUE_BULL_PREFIX). Omitted when null so Bull's own `bull` default applies; the same input also sets N8N_REDIS_KEY_PREFIX and the KEDA listName. |
| `config.extraEnv` | Exposed as `n8n_extra_env`, applied to every n8n pod. Reserved names are rejected at plan time. |
| `config.timezone` | Exposed as `n8n_timezone`. |
| `executions.*` | Exposed: `n8n_execution_timeout` / `_timeout_max` (timeout, timeoutMax), `n8n_execution_concurrency_limit` (concurrency.productionLimit), `n8n_pruning_max_age` / `_max_count` (pruning). The chart reads these top-level only; there is no `config.executions`. |
| `taskRunners.*` | Exposed: enabled, mode, native Python runner, and the launcher config through the allowlist inputs. |
| `taskRunners.image.tag` | Exposed as `n8n_task_runner_image_tag`. Omitted when null, so the chart falls back to the application image tag. |
| `taskRunners.image.repository`, `.resources`, `.broker` | Not exposed. `taskRunners.launcher.autoShutdownTimeout` is set from `n8n_task_runner_auto_shutdown_timeout`; the rest of `.launcher` is not exposed. |
| `ingress.*` | Exposed when `create_ingress = true`: class, hosts, TLS, annotations, sticky sessions, and the webhook-processor Ingress. |
| `resources.*` | Exposed for all four pools: main, worker, webhookProcessor, taskRunner. |
| `serviceAccount.create`, `.name` | Exposed. |
| `serviceAccount.annotations` | Not exposed. There is no cloud IAM binding on this platform. |
| `secretRefs.existingSecret` | Set by the module. It wires its own Secrets and does not hand that over. |
| `extraVolumes`, `extraVolumeMounts` | Exposed, for shared storage across the pools. |
| `extraContainers`, `extraInitContainers` | Exposed as `n8n_extra_containers` and `n8n_extra_init_containers`. Omitted entirely when empty. |
| `s3.*` | `enabled` is hardcoded false. The module provisions no bucket; see the out-of-scope section in the README. |
| `license`, `multiMain` | **Never set, by design.** Both are licence-gated. The module deploys Community edition only and renders no licence key. |
| `persistence.*` | Not set, chart defaults apply. |

## Not currently configurable

These 22 chart keys get no typed input and are left at chart defaults:

`affinity`, `commonAnnotations`, `commonLabels`, `dnsConfig`, `dnsPolicy`,
`fullnameOverride`, `license`,
`lifecycle`, `multiMain`, `nameOverride`, `networkPolicy`, `nodePlacement`,
`nodeSelector`, `pdb`, `persistence`, `podLabels`, `probes`, `rbac`,
`securityContext`, `service`, `strategy`, `tolerations`.

Two of those, `license` and `multiMain`, are deliberate and permanent. The rest
are simply not surfaced yet. If you need one as a first-class input, open an
issue saying which and what for, and it is a small change.

## Custom images, community nodes and sidecars

Baking community nodes into your own image is a first-class path, and it takes
three inputs that work together:

```hcl
n8n_image_repository       = "ghcr.io/you/n8n-with-nodes"
n8n_image_tag              = "2.36.2-mynodes"
n8n_task_runner_image_tag  = "2.36.2"            # the n8n version underneath
n8n_custom_extensions_path = "/opt/n8n-nodes"    # where n8n scans, N8N_CUSTOM_EXTENSIONS
```

The module refuses the incoherent combinations at plan time rather than letting
you find them in a CrashLoopBackOff. A custom repository with no explicit tag is
rejected, because a custom repository almost never publishes one called
`stable`. A custom image with task runners on and no runner tag is rejected,
because the chart would otherwise resolve the runner tag from the application
tag, and `n8nio/runners` has never published `2.36.2-mynodes`. A
`n8n_custom_extensions_path` that no volume mount or custom image provides is
rejected too.

If you only need extra community nodes and not a custom image, n8n can install
them at runtime instead, which needs no image build at all. Set
`N8N_COMMUNITY_PACKAGES_ENABLED` through `n8n_extra_env`, and consider
`n8n_reinstall_missing_packages` so a rescheduled pod repairs its own node set.
That one raises the webhook processor's resource floor and the module enforces
the floor, because the default sizing is what failed when npm install ran inside
the pod.

**Sidecars are exposed**, as `n8n_extra_containers` and
`n8n_extra_init_containers`. A sidecar shares the pod's network namespace, so it
reaches n8n on `localhost:5678` with no service in between:

```hcl
n8n_extra_containers = [{
  name          = "log-shipper"
  image         = "ghcr.io/you/shipper:1.0.0"
  args          = ["--target", "loki:3100"]
  ports         = [{ name = "metrics", container_port = 9100 }]
  volume_mounts = [{ name = "logs", mount_path = "/var/log/n8n" }]
  resources     = { cpu_request = "50m", memory_limit = "128Mi" }
}]
```

Both are typed to the fields a sidecar actually uses rather than to the whole
Kubernetes container schema, the same trade `n8n_extra_volumes` makes by
exposing three volume sources out of a dozen. Probes, lifecycle hooks and
securityContext are not covered; a sidecar needing those still goes through
`n8n_extra_helm_values`. The module translates snake_case to Kubernetes
spelling (`container_port` to `containerPort`, `mount_path` to `mountPath`) and
renders only the resource corners you set, because a null request is rejected by
the API server where an absent one inherits the namespace default.

## Escape hatches

Unlike the AWS sibling, this module does have a generic raw-values passthrough,
so nothing in the chart is actually out of reach.

**`n8n_extra_env`** takes a typed list of name/value pairs and applies them to
every n8n pod. Reserved names that would fight the module's own wiring are
rejected at plan time.

**`n8n_extra_helm_values`** takes raw YAML and is merged on top of everything
the module renders, so it wins on conflict. Use it for any chart key without a
typed input, and for `valueFrom`-shaped environment entries that `n8n_extra_env`
cannot express because it is typed as plain name/value pairs.

The trade is the usual one. Anything set through `n8n_extra_helm_values` is
invisible to the module's validation and to its tests, so a key you misspell
fails in the cluster rather than at plan time. Prefer a typed input where one
exists, and open an issue when one should.
