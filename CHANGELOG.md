# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `cnpg_pooler_enabled` puts a PgBouncer connection pooler in front of the
  CloudNativePG cluster and points n8n at it, with `cnpg_pooler_instances`,
  `cnpg_pooler_mode`, `cnpg_pooler_pool_size` and
  `cnpg_pooler_max_client_conn` to size it. Off by default, so nothing changes
  for existing callers.

  The problem it solves is that pod count, not CPU, is what a queue-mode
  deployment runs out of first. Every n8n pod holds `db_postgresdb_pool_size`
  persistent connections, that number is multiplied by a pod count an
  autoscaler owns, and the CNPG cluster runs `max_connections = 200`. A worker
  tier at 16 beside a webhook-processor tier at 8, at the default pool size of
  10, asks for 250 against roughly 197 usable. Past the limit pods do not slow
  down: a new worker cannot initialise its pool, exits non-zero and CrashLoops,
  and requests already in flight stall until the client gives up. In the
  default transaction mode the connection count is then
  `cnpg_pooler_pool_size x cnpg_pooler_instances` regardless of how far the
  tiers scale. Session mode is offered but does not do this: it holds a server
  connection for the life of each client session, and n8n's TypeORM pool is
  long-lived, so server connections still track pod count.

  `cnpg_pooler_enabled = true` requires `db_postgresdb_ssl_enabled = false`,
  and the module refuses the combination at plan time. The pooler serves its
  clients in plaintext and encrypts its own leg to Postgres.

- `cnpg_max_connections` sets the CNPG cluster's connection limit, default 200,
  which is what the module hardcoded before. It is also the budget
  `cnpg_pooler_pool_size x cnpg_pooler_instances` is validated against, capped
  at three quarters of it, so the pooler cannot be sized past the database it
  sits in front of and the two numbers cannot drift apart.

- `backing_services.postgres_direct_host` names the CNPG rw Service even when
  a pooler is in front, so session-scoped work that transaction pooling cannot
  carry (session advisory locks, `LISTEN`/`NOTIFY`, an interactive `psql`)
  has somewhere to go. Null on the external backend.

- `examples/homelab-pgbouncer`, the base homelab deployment with the pooler
  enabled, including measured throughput and sizing guidance: what one worker
  is worth, how to size a worker tier from a target rate, why per-node CPU and
  not the cluster total is the limit that binds, and how to measure your own
  workflow without the load generator becoming the thing you measured.

- `n8n_binary_data_mode` and `n8n_binary_data_path` move binary payloads off
  Postgres and onto a shared volume. Default `"database"`, which is what n8n
  does in queue mode and what this module has always produced, so nothing
  changes unless you opt in.

  Selecting `"filesystem"` requires a writable `n8n_extra_volume_mounts` entry
  covering the path, checked at plan time. That combination without a shared
  volume is the reason the guard exists: each pod gets its own empty directory,
  and in queue mode the pod that writes a payload is rarely the pod that reads
  it back, so the execution reports success against a reference to a file that
  is not there. Nothing errors and nothing logs.

### Changed

- **Breaking.** `N8N_DEFAULT_BINARY_DATA_MODE` and `N8N_STORAGE_PATH` are
  reserved names again, rejected from `n8n_extra_env` and
  `n8n_extra_env_from_secret` with a message naming `n8n_binary_data_mode` and
  `n8n_binary_data_path` instead.

  **Upgrade note.** If you set either name through `n8n_extra_env` or
  `n8n_extra_env_from_secret`, replace the entries with the two inputs. `n8n_extra_env = [{name =
  "N8N_DEFAULT_BINARY_DATA_MODE", value = "filesystem"}, {name =
  "N8N_STORAGE_PATH", value = "/opt/n8n-shared/storage"}]` becomes
  `n8n_binary_data_mode = "filesystem"` and `n8n_binary_data_path =
  "/opt/n8n-shared"`, with the module appending `storage/` itself. Nothing about
  the rendered environment changes, so no pod restarts on the value.

  They were briefly unreserved because before these inputs there was no other
  way to reach the setting. That left the mode with two doors and only one of
  them checked: filesystem mode set through `extraEnv` skipped the shared-mount
  validation, skipped `N8N_STORAGE_PATH`, and still reported `filesystem` while
  the pods wrote to per-pod local disk, which is the silent loss the validation
  exists to prevent.

- **Breaking.** `n8n_extra_helm_values` no longer accepts an overlay that sets
  `config.extraEnv`. Helm replaces lists rather than merging them, so such an
  overlay substituted the module's whole environment list: `N8N_ENCRYPTION_KEY`,
  every database and queue connection variable and the binary data mode
  disappeared, the release installed anyway, and the pods came up misconfigured
  with nothing reporting it. The input's description has warned about this since
  it existed; a warning in prose is not a check. Everything else the overlay
  reaches is unchanged. Use `n8n_extra_env` and `n8n_extra_env_from_secret`,
  which append to the list rather than replacing it.

### Fixed

- The capacity diagnostic no longer counts a `NoExecute`-tainted node as
  schedulable supply. `NoExecute` blocks new scheduling the same way
  `NoSchedule` does and additionally evicts what is already running, so a node
  held by one (`node.kubernetes.io/out-of-service`, say) inflated the
  apparent capacity and could suppress the very warning the check exists to
  raise - the one direction the model documents it will not be wrong in.
  `PreferNoSchedule` nodes stay counted, since that taint is a preference
  rather than a bar. The taints read is also guarded against a provider
  returning `null` instead of an empty list, which was a hard plan error
  outside any check block.

- The module's `n8n-secrets` Secret no longer carries a `WEBHOOK_URL` key. The
  chart reads exactly four keys from it (`N8N_ENCRYPTION_KEY`, `N8N_HOST`,
  `N8N_PORT`, `N8N_PROTOCOL`); the fifth was never referenced by anything, and
  it computed the URL from `n8n_domain` alone, so whenever `k8s_ingress_host`
  named a different host the Secret showed a different WEBHOOK_URL than the
  one the pods actually run. Dead and wrong is the worst combination for a
  value people read while debugging webhook delivery. Removing it is an
  in-place Secret update; the pods' environment is untouched.

- `redis_key_prefix` now reaches all three of its consumers. The variable
  description has always said it moves n8n's key prefix
  (`N8N_REDIS_KEY_PREFIX`), Bull's (`QUEUE_BULL_PREFIX` via the chart's
  `redis.prefix`) and the KEDA `listName` together; the code only ever moved
  the KEDA half. Setting it therefore repointed the scaler at
  `<prefix>:jobs:wait` while Bull kept writing under `bull`, freezing worker
  autoscaling at its floor, and delivered none of the per-deployment isolation
  that is the input's whole purpose: two deployments sharing one Redis kept
  crossing pub/sub channels exactly as if the input did not exist. All three
  now derive from the one input, and leaving it null still renders neither env
  var so n8n's `n8n` and Bull's `bull` defaults keep applying.

- The KEDA worker trigger now consumes an external Redis endpoint the same way
  n8n does, which the variable descriptions have promised all along. Four
  defects in one trigger block: the address hardcoded `:6379`, so any other
  `redis_port` had n8n executing against one address and KEDA scaling on one
  that answers nothing; `redis_transit_encryption_enabled` never set
  `enableTLS`, so the scaler dialled a TLS listener in plaintext;
  `redis_username` never reached the trigger, so an ACL-authenticated endpoint
  had KEDA authenticating as `default`, which usually cannot `LLEN` the bull
  lists; and `passwordFromEnv` was rendered unconditionally (its gate compared
  a never-null local against null), naming an env var that does not exist on
  the no-auth path. In every case the workload ran fine while queue-depth
  autoscaling silently froze at the floor. The trigger now shares the resolved
  host/port with the workload and gates all three auth fields on the same
  conditions the chart values use.

- An external Redis without an AUTH token no longer breaks every pod.
  `redis.passwordSecret` was rendered unconditionally, and on the no-auth
  external path it named `n8n-redis-secret`, a Secret the module only creates
  when `redis_auth_token` is set (with `redis_auth_token_secret_ref` the
  reference points at the caller's own Secret instead). The chart
  then gave every main, worker and webhook-processor container a secretKeyRef
  to a Secret that does not exist, and the whole deployment sat in
  `CreateContainerConfigError`. The key is now rendered only when there is a
  credential behind it: always on the valkey path, and on the external path
  exactly when one of the two auth inputs is set.

- `n8n_execution_timeout`, `n8n_execution_timeout_max`,
  `n8n_execution_concurrency_limit` and `n8n_pruning_max_count` now actually
  reach the pods. They were rendered under `config.executions`, a key the chart
  never reads: the chart's executions settings live in a top-level `executions`
  block, and only pruning `enabled`/`maxAge` happened to also be rendered
  there. So the four inputs were accepted, validated, documented and silently
  discarded, and every deployment ran the chart's own defaults instead:
  no execution timeout (`-1`) rather than the documented 7200, a 3600
  `timeoutMax` rather than 7200, no concurrency limit rather than 100, and
  pruning maxCount 10000, which only matched the module default by
  coincidence. The values now merge into the top-level block, so deployments
  that never set these inputs will see a plan updating the release values and
  should expect the documented defaults to start applying, most visibly
  `EXECUTIONS_TIMEOUT=7200` and `N8N_CONCURRENCY_PRODUCTION_LIMIT=100`. To
  keep the previous effective behaviour, set `n8n_execution_timeout` and
  `n8n_execution_concurrency_limit` to `-1`, `n8n_execution_timeout_max` to
  `3600`, and leave `n8n_pruning_max_count` at its default (10000, which is
  also what the chart was applying). The contract
  test asserting these inputs was itself asserting the dead subtree, which is
  how this survived: it now asserts against the merged values tree and that
  `config.executions` stays unrendered.

- Five bugs in the examples, all present since they were written and all in the
  copies every example shares.

  The shared-storage claim waited to bind, which deadlocks against a
  `WaitForFirstConsumer` `StorageClass`: nothing can consume the claim until the
  Helm release exists, and the release is downstream of the claim. It ended as a
  five minute timeout blaming the claim. `wait_until_bound = false` now.

  The namespace changed owner when `shared_storage_class` went from unset to
  set, moving between the module's resource address and the example's in one
  apply. Terraform had no reason to sequence that safely, so it either failed
  `AlreadyExists` or destroyed the module-owned namespace first, taking n8n,
  CloudNativePG, Valkey and every PVC with it, with nothing in the plan reading
  as "this deletes your database". The examples own the namespace
  unconditionally now. **Every existing deployment needs one
  `terraform state mv` before the next apply.** Which one depends on the
  address that is actually in state, not on how the variable is set: run
  `terraform state list | grep kubernetes_namespace.n8n` and move whichever of
  `module.n8n.kubernetes_namespace.n8n[0]` or `kubernetes_namespace.n8n[0]`
  exists to `kubernetes_namespace.n8n`. Removing the `count` dropped the index
  on the second. Both commands are in `storage.tf`. Without the move the next
  apply plans that same destroy.

  `kubeconfig_path` accepted a trailing backslash, which escapes the closing
  quote of the generated `kubectl_config_command` and leaves the export
  unterminated. It also accepted the empty string, which resolved to the
  example directory and made the smoke test export a directory as
  `KUBECONFIG`. Both rejected now.

  A relative `kubeconfig_path` resolved against the root module for Terraform
  and against the invoking shell for `smoke-test.sh`, which the documented
  `TERRAFORM_DIR=examples/...` form runs from the repository root, so the two
  named different files. Resolved to absolute, and only when genuinely
  relative: `abspath` prepends a drive to an absolute POSIX path on Windows,
  which would make the output depend on where Terraform ran.

  Windows separators are normalised to forward slashes on the way into that
  double-quoted shell string, and only there: on POSIX a backslash is an
  ordinary filename character, so `/tmp/kube\config` used to reach the
  providers intact and the smoke test as `/tmp/kube/config`. A drive letter is
  the marker. Which also means a drive-relative path like `C:config` is
  resolved rather than passed through, having named a path against the current
  directory of drive C rather than against its root all along.

- `backing_services.binary_storage` reported the constant `"filesystem"` on
  every path, including the default one where binary data goes to Postgres. It
  now reports the effective mode, following an `n8n_extra_env` override where
  one is set. Wrong since the initial release; see issue #18.

### Changed

- `backing_services.postgres_host` resolves to the pooler Service when
  `cnpg_pooler_enabled` is true. It is what n8n connects to, so anything
  reading it to reach the database follows n8n. Unchanged when the pooler is
  off.

## [0.2.0], The task-runner round

Two fixes, two description corrections and one new input, all in the
task-runner and metrics surface. Both fixes are inputs that silently did
nothing, which is why this is a minor bump rather than a patch: the values you
set start taking effect.

`n8n_task_runner_auto_shutdown_timeout` reached the wrong containers, so the
runner sidecar stayed on the chart's 15 seconds whatever you asked for. If you
set that input, the sidecar's environment changes on the next apply and the
main and worker pods restart. Leaving it at the default plans clean.

`n8n_metrics_enabled` sets three environment variables and only reserved one of
them. Passing either `N8N_METRICS_INCLUDE_QUEUE_METRICS` or
`N8N_METRICS_INCLUDE_CACHE_METRICS` through `n8n_extra_env` or
`n8n_extra_env_from_secret` is now a plan-time error rather than a duplicate
env entry. That is the one upgrade that can fail: delete the entry, since the
module already sets the same value.

`n8n_task_runner_max_concurrency` is new and defaults to null, which changes
nothing until you set it.

### Added

- `n8n_task_runner_max_concurrency` input: the maximum number of tasks a single
  task-runner process will execute at once, wired to
  `N8N_RUNNERS_MAX_CONCURRENCY` through the `env-overrides` block of the
  `n8n-task-runners.json` ConfigMap. The name was already in that file's
  `allowed-env` list for both runners, so only the input was missing. The chart
  has no typed value for it and no hook for adding environment to the sidecar,
  and `config.extraEnv` would put it on containers that never read it, so the
  ConfigMap is the only correct place. Defaults to null, which omits the key and
  leaves each runner on its own default: 10 for JavaScript, 5 for Python. Those
  disagree, so no single number could be a neutral default here.

### Fixed

- `n8n_task_runner_auto_shutdown_timeout` now reaches the task-runner sidecar.
  It was rendered into `config.extraEnv`, which the chart puts on the n8n
  containers only, so the launcher never saw it and the sidecar stayed on the
  chart default of 15 no matter what the caller set. It is now set on
  `taskRunners.launcher.autoShutdownTimeout`, the key the chart renders into
  the sidecar's environment. Callers who set this input and saw no change in
  runner behaviour will see it take effect on the next apply; callers who left
  it at the default get the same 15 seconds as before.

- `N8N_METRICS_INCLUDE_QUEUE_METRICS` and `N8N_METRICS_INCLUDE_CACHE_METRICS`
  are now reserved names. `n8n_metrics_enabled` has always set them alongside
  `N8N_METRICS`, but only `N8N_METRICS` was on the reserved list, so a caller
  could also pass one of them through `n8n_extra_env` and the module rendered
  the same name twice in one container's env list. Kubernetes takes the last
  one silently, which is the override the reserved list exists to prevent.
  Setting either through `n8n_extra_env` or `n8n_extra_env_from_secret` is now
  a plan-time error. The remaining `N8N_METRICS_INCLUDE_*` groups are
  unaffected and stay callable: the module has no opinion about them.

### Changed

- `n8n_metrics_enabled`'s description now lists all three environment
  variables it sets rather than only `N8N_METRICS`, and says that the endpoint
  being on is not the same as the metrics being on, since most of n8n's
  `N8N_METRICS_INCLUDE_*` families default to false. No behaviour change.

- `n8n_task_runner_cpu_limit`'s description now says what it costs to leave at
  the default. On a Python Code-node benchmark, a single worker with KEDA
  pinned, raising the sidecar CPU limit was worth 3.8x on its own and 6.6x
  together with concurrency, which makes it the dominant of the two runner
  throughput levers. The reason is specific to Python: that runner executes
  each task in a forked child process, so it is CPU-hungry in a way a sidecar
  is not assumed to be. No default changed. Worth reading alongside the note
  that runner saturation is invisible to queue-depth autoscaling, since at low
  concurrency the Redis queue stays empty while requests still stall, and KEDA
  sees nothing to scale.

## [0.1.0], First stable release

Same module tree as `0.0.1-beta.5`. Nothing to plan on upgrade, and no input,
output or rendered value changes: this exists so that version constraints work.

Every tag before this one is a semver pre-release, and neither Terraform nor
OpenTofu matches a range constraint against a pre-release. `version = "~> 0.0"`
resolved to nothing at all rather than to `0.0.1-beta.5`, so the only usable
pin was an exact one, and consumers got no patch upgrades without editing the
version by hand. Dropping the suffix fixes that and nothing else.

Still pre-1.0. Under semver a `0.x` minor bump may break the input surface, so
`~> 0.1` is the constraint to use: it takes patches and holds the minor. `1.0.0`
is a promise to make when the variables stop moving.

### Changed

- Documentation now pins `~> 0.1` where it pinned `0.0.1-beta.5` exactly, and
  the pin-exactly rationale is replaced by the range guidance above. The git
  source form is unchanged in mechanism and moves to `?ref=0.1.0`.

## [0.0.1-beta.5]

Closes the one item `0.0.1-beta.4` shipped as known and not fixed: on a split
ingress, connecting a Slack agent returned 404 at the end of the OAuth flow.

Both split-ingress examples now route `/rest/projects` on the webhook hostname
to the main pods. No module input, output or rendered value changes, so
upgrading replans only the two example Ingress objects, and only if you deploy
from those examples. A single-hostname deployment is untouched.

### Fixed

- **Agents chat integrations 404 on a split ingress.** n8n builds the Slack
  app-install URL and the platform event callbacks by appending
  `/rest/projects/<id>/agents/...` onto `getWebhookBaseUrl()`, which is
  `WEBHOOK_URL`, which is the webhook hostname. Those are main-pod routes, and
  the webhook Ingress routed none of them, so the callback 404ed after the user
  had already granted consent, with nothing logged. Upstream n8n's
  construction, unrelated to `N8N_EDITOR_BASE_URL` and not fixable by
  configuration: verified from inside the pods that a webhook-processor serves
  no `/rest` route at all (404 on every one, against 401/200 on a main), so the
  path has to be routed. Both split-ingress examples gained the rule, each
  covered by a test that fails without it.

### Changed

- The webhook hostname in both split-ingress examples now serves
  `/rest/projects` in addition to the webhook prefixes. Scoped to that prefix
  rather than all of `/rest`, because it is the entire surface those
  constructions use: `/rest/login`, `/rest/credentials` and the rest of the
  REST API stay off that hostname. It is a literal prefix, so it needs no regex
  and no controller-specific annotation. The examples' READMEs and variable
  descriptions now describe that surface rather than claiming nothing else is
  routed there, and deleting the block restores the old surface for anyone not
  using Agents chat integrations.

## [0.0.1-beta.4]

The AI Assistant round. Adds an input for secret-backed environment variables
and an output naming the OAuth2 redirect URI, and fixes a split ingress
labelling the editor with the webhook hostname, which broke every OAuth
credential on that topology.

Upgrading from `0.0.1-beta.3` plans clean on a single hostname. On a split
ingress it replans the n8n release: `WEBHOOK_URL` and `N8N_EDITOR_BASE_URL`
move out of the chart's ConfigMap and into `config.extraEnv`, and the second of
those changes value. The pods restart. No data is touched, and every output
that already existed keeps its value on every path; `n8n_oauth_callback_url` is
new, and adding it is the only output-level change.

### Added

- `n8n_oauth_callback_url` output: the redirect URI to register with any OAuth2
  provider a credential will use. n8n builds it from `N8N_EDITOR_BASE_URL`, so
  on a split ingress it sits on the editor hostname and never the webhook one,
  which is not derivable from the other outputs and is the thing that was wrong
  in the release before this one. Re-exported by both split-ingress examples,
  which now assert it lands on `editor_host` and refuse it on `webhook_host` -
  the regression guard that could not exist while nothing exposed the value.

- `n8n_extra_env_from_secret` input: environment variables for the n8n pods
  sourced from keys of existing Kubernetes Secrets, rendered as
  `valueFrom.secretKeyRef` entries. `n8n_extra_env` is typed as name/value
  pairs, so every secret a caller needed to pass had to go through it in
  plaintext, landing in the Helm release and in Terraform state. The documented
  alternative was an `n8n_extra_helm_values` overlay, which does not work for
  this: Helm coalesces maps across values documents but replaces lists, so an
  overlay setting `config.extraEnv` substitutes its own list for the module's
  entire one, dropping `N8N_ENCRYPTION_KEY` and every connection variable. The
  release still installs and the pods come up misconfigured. The new input
  appends instead, and rejects module-managed names and names already set in
  `n8n_extra_env`.

### Fixed

- `N8N_ENDPOINT_*` is now reserved. The module hardcodes the path segments n8n
  serves and then publishes them: `n8n_webhook_path_prefixes` lists `/webhook`,
  `/webhook-waiting`, `/form`, `/form-waiting` and `/mcp`, the examples route
  exactly those five on the webhook Ingress, and `n8n_oauth_callback_url`
  spells `/rest` into the redirect URI. Each of those segments is an
  `N8N_ENDPOINT_` variable, and repointing one through `n8n_extra_env` left the
  Ingress routing the old segment and the outputs advertising it while n8n
  answered on the new one, with the module reporting both as correct.

- `examples/homelab-cloudflare-split-ingress` had no `.terraform-docs.yml`, so
  `terraform-docs --output-check` there printed its help text and exited 0. The
  example was enumerated in the Taskfile and in CI all along; the check simply
  could not fail, so that README was never actually verified against the code.

- `n8n_extra_env_from_secret` accepted Secret names the API server rejects.
  The `secret_name` check matched one `[a-z0-9.-]` character class, which
  admits `a..b` and `a-.b`, so the guard passed exactly the malformed names it
  exists to catch and the pod stuck in `CreateContainerConfigError` long after
  Helm reported success. Now matched label by label, with the 253-character
  limit.

- `N8N_EDITOR_BASE_URL` named the webhook host on a split ingress, breaking
  every OAuth2 credential. Chart 1.10.0 derives that variable from the first
  ingress host and, failing that, from `webhook.url`, on the stated assumption
  that "webhook.url is the domain". With `create_ingress = false` the chart has
  no ingress host to read, so it labelled the editor with the webhook
  hostname. Nothing warned: the editor still loaded, and webhook delivery still
  worked. What broke was every absolute URL n8n builds from
  `getInstanceBaseUrl()`, which prefers `N8N_EDITOR_BASE_URL` over
  `WEBHOOK_URL` - above all the OAuth2 redirect URI,
  `<editor base>/rest/oauth2-credential/callback`. Sent to the webhook host it
  404s twice over: a split ingress routes only the webhook prefixes there, and
  the webhook processor serves no `/rest` routes even when reached. So
  connecting any OAuth credential failed at the provider's callback while
  everything else kept working, which points the search at the wrong half.

  The module now empties the chart's `webhook.url` on that path, which
  suppresses both chart keys and their `configMapKeyRef` entries, and sets
  `WEBHOOK_URL` and `N8N_EDITOR_BASE_URL` from `config.extraEnv` instead.
  Overriding in place was not an option: a second entry of the same name in a
  container's env list fails the strategic merge patch on the next `helm
  upgrade` and leaves the release stuck in `failed`.

  Affects `homelab-split-ingress` and `homelab-cloudflare-split-ingress`.
  Single-host deployments are untouched, and the `n8n_webhook_url` output is
  unchanged on every path.

### Changed

- `n8n_extra_helm_values` description corrected. It claimed `valueFrom`-shaped
  environment entries were its most useful application, which was the one
  thing it could not safely do.

## [0.0.1-beta.3]

Adds a fifth example, an output, and an opt-in shared-storage pattern to every
example. The module's only behavioural change is the new output, so an upgrade
from `0.0.1-beta.2` plans clean unless you opt into shared storage.

### Added

- `n8n_webhook_url` output: the base URL n8n advertises in every production
  webhook, form and MCP URL it generates. The module exposed `n8n_url`, the
  editor address, and nothing carrying `WEBHOOK_URL`, so a caller running the
  split-hostname topology had no way to assert the one value that defines it.
- `examples/homelab-cloudflare-split-ingress`: the split-hostname topology
  behind a Cloudflare Tunnel. One proxied CNAME per hostname, `proxy_hops`
  defaulting to 2 for the extra edge, both DNS and storage opt-in.
- Optional shared `ReadWriteMany` storage in all five examples, off by
  default. Queue mode runs main, worker and webhook-processor pods that share
  no filesystem, and the chart's own `data` volume is an `emptyDir` on main
  only, so anything one pod writes to local disk is invisible to the other
  two. Setting `shared_storage_class` creates one claim, mounts it into all
  three, and moves binary data onto it.
- `proxy_hops` input in both split-ingress examples. `N8N_PROXY_HOPS` was
  hardcoded to `"1"`, which is right behind ingress-nginx alone and wrong
  behind anything in front of it.

### Fixed

- Examples that set `shared_storage_class` could fail their first apply with
  `namespaces "..." not found`. Handing namespace creation to the example left
  the module's Secrets, CNPG `Cluster` and Valkey release with no dependency on
  it, so Terraform was free to schedule them first. The examples now pass the
  namespace resource attribute through `k8s_namespace`.
- `kubectl_config_command` in every example read `current-context` from
  `kubeconfig_path` and then set it in the *default* kubeconfig: a no-op when
  the two matched, and a switch to the wrong cluster when they did not. It now
  exports `KUBECONFIG`, quoted, with a leading `~/` rewritten to `$HOME/`.
- The hostname validation in both split-ingress examples accepted names with an
  empty label or a label ending in a hyphen. Both reach the `Ingress` host
  field and are rejected by the API server, so the failure surfaced on apply
  rather than at plan.
- `k8s_ingress_host` was set in both split-ingress examples where it does
  nothing: every consumer of it is gated on `create_ingress`.
- The README pointed OpenTofu users at the registry address. OpenTofu resolves
  modules against a separate index this module is not published to, so the
  short form fails with `Module not found`. Usage now gives the git source.
- `editor_ingress_extra_annotations` claimed an IP allowlist is meaningful only
  on a path that reaches nginx directly. With `use-forwarded-headers` and
  `compute-full-forwarded-for` it works through a tunnel too.

### Changed

- `openspec/` and `reports/` are no longer tracked. Neither was ever published,
  and the comment claiming release tags excluded them described an exclusion
  nothing implemented.
- `AGENTS.md` states the commit-message convention, aligned with
  `CONTRIBUTING.md`.

## [0.0.1-beta.2]

Documentation only. No inputs, outputs, resources or defaults changed, so an
upgrade from `0.0.1-beta.1` plans clean.

### Fixed

- The Helm cache workaround in `docs/troubleshooting.md` told readers to add a
  chart repository that no longer exists, was never the repository this module
  pulls from, and could not have been added that way regardless: the n8n chart
  is an OCI reference, which resolves directly rather than through an
  `index.yaml`. The step is now keyed on the repository scheme, so it stays
  correct whichever way `n8n_chart_repository` and `valkey_chart_repository`
  are pointed.
- `n8n_chart_repository` suggested mirroring to "an ECR OCI repository in this
  account". There is no cloud account anywhere in this module.
- The smoke-test summary in `tests/scripts/README.md` claimed `/healthz` is
  checked over an ALB. It goes through the `Ingress`.
- The bug-report template asked reporters for a version "e.g. `0.1.0`", a tag
  that belonged to the AWS module this one was forked from and no longer
  exists.

### Changed

- The community-project warning is now the first thing in the README rather
  than half a sentence inside a paragraph about module shape. The module is
  listed on the public registry one search result away from `n8n-io/n8n/aws`,
  under a name built from the same three words, and the registry renders the
  README and nothing else. The warning names that module and points AWS users
  at it.

## [0.0.1-beta.1], First release

Initial public release of `terraform-kubernetes-n8n`: a single resource-bearing
root module that deploys [n8n](https://n8n.io) in queue mode onto a Kubernetes
cluster the caller already runs. The module's shape mirrors its
[`terraform-aws-n8n`](https://github.com/n8n-io/terraform-aws-n8n) sibling:
one root, `versions.tf`/`variables.tf`/`locals.tf`/`outputs.tf` plus one file
per concern, no nested `module` calls in the deployment path.

Where the cloud siblings provision a cluster *and* the workload, this one
cannot: "create a Kubernetes cluster" is not a resource any provider offers
generically. It owns the workload and its backing services, and treats the
cluster, ingress controller, cert-manager, CloudNativePG, KEDA, `StorageClass`
and DNS as caller prerequisites.

### Added

- **A single `terraform apply`** bringing up the namespace, Secrets,
  ServiceAccount, backing services and the n8n Helm release together: no
  separate infrastructure tier, and no cloud provider declared or required.
- **n8n in queue mode**, separate worker and webhook-processor pools, on the
  Community edition throughout, no licence is required or accepted.
- **CloudNativePG** for PostgreSQL (`postgres_backend = "cnpg"`), or an
  external endpoint. The operator generates the credentials into its own
  `<cluster>-app` Secret, so there is no password input on that path.
- **Valkey** for the Bull queue (`redis_backend = "valkey"`), or an external
  endpoint with optional TLS, auth token, username and timeout.
- **Multi-domain `Ingress`** with all five webhook path prefixes routed to the
  webhook processors, cert-manager TLS through a named `ClusterIssuer`, or
  `create_ingress = false` for caller-owned routing with the namespace, Service
  names, port and prefix list exposed as outputs.
- **Worker autoscaling on queue depth** via KEDA when `k8s_keda_installed`
  attests the operator is present, falling back to the chart's CPU HPA, plus
  main and webhook HPAs and an advisory cluster-capacity diagnostic.
- The n8n runtime, execution, lifecycle, task-runner, logging, pruning,
  community-package and external-secrets control surface, plus custom
  image/pull-secret/extra-volume/extra-env support and OpenTelemetry and
  metrics observability.
- **Optional off-cluster access** to the PostgreSQL read-write endpoint and the
  n8n metrics endpoint as `LoadBalancer` Services, off unless an address is
  named. Neither adds authentication.
- `examples/homelab`, `examples/homelab-cloudflare`, `examples/homelab-godaddy`
  and `examples/homelab-split-ingress`.
- `modules/cluster-capacity/` and `modules/tls-letsencrypt/` submodules.
- `docs/operations.md`, `docs/troubleshooting.md`, `docs/post-deployment.md`,
  `docs/upgrading-n8n.md`.

[Unreleased]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/compare/0.2.0...HEAD
[0.2.0]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.2.0
[0.1.0]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.1.0
[0.0.1-beta.5]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.5
[0.0.1-beta.4]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.4
[0.0.1-beta.3]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.3
[0.0.1-beta.2]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.2
[0.0.1-beta.1]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.1
