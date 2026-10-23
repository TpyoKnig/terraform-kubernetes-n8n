# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `tests/scripts/smoke-test.sh`: `SMOKE_RESOLVE_IP` setting that routes every
  request the script makes to a given address while keeping the real `Host`
  header and TLS SNI. Needed when the hostname is a real public record in
  front of the cluster, for example the Cloudflare examples' proxied CNAMEs
  to a tunnel, and the editor Ingress carries an IP allowlist: without it,
  requests reach the allowlist from the tunnel's egress address instead of
  the caller's network and a healthy deployment fails with a plain 403.
  Unset by default, which changes nothing. The `/healthz` and API checks
  also print a hint toward this setting when they see a 403.
- `valkey_helm_timeout` (number, seconds, default `600`): seconds Terraform
  waits for the Valkey Helm release to converge, only used when
  `redis_backend = "valkey"`. The default matches the literal
  `helm_release.valkey` carried before this input existed, so a deployment
  that leaves it unset renders unchanged. Raise it independently of
  `n8n_helm_timeout` on storage where the Valkey PVC binds slowly (a
  `WaitForFirstConsumer` class with no provisioner left the PVC Pending into
  the timeout).
- `n8n_pruning_enabled` (bool, default `true`): whether n8n deletes old
  execution records on a schedule, rendered as the chart's
  `executions.pruning.enabled`. True matches today's hardcoded value, so a
  deployment that leaves it unset renders unchanged. Set `false` to retain
  every execution indefinitely; `n8n_pruning_max_age` and
  `n8n_pruning_max_count` keep rendering so the policy resumes unchanged if
  pruning is switched back on.
- `n8n_pruning_hard_delete_buffer`, `n8n_pruning_hard_delete_interval` and
  `n8n_pruning_soft_delete_interval` (numbers, default `null`): the chart's
  `executions.pruning.hardDeleteBuffer` / `hardDeleteInterval` /
  `softDeleteInterval`, rendered as `EXECUTIONS_DATA_HARD_DELETE_BUFFER` /
  `EXECUTIONS_DATA_PRUNE_HARD_DELETE_INTERVAL` /
  `EXECUTIONS_DATA_PRUNE_SOFT_DELETE_INTERVAL`. Left null (the default), the
  module omits all three keys, so the chart's own defaults
  (1 hour / 15 minutes / 60 minutes) keep applying exactly as they always
  have; the deployment this fills a gap for had never had a way to tune this
  cadence at all. Each is a whole-number-of-at-least-1 validation, matching
  the chart's own truthiness gate: a `0` would silently omit the env var
  rather than mean "no buffer" or "no interval".
- `n8n_payload_size_max` (number, MiB, default `null`): wires
  `N8N_PAYLOAD_SIZE_MAX` on every pod type and, when set, derives the
  Ingress `proxy-body-size` annotation from the same value plus 2 MiB of
  multipart-framing headroom, so n8n's own limit and the proxy's cannot
  disagree. Left null (the default), nothing changes: the env var stays
  omitted and the annotation stays at its original `32m` literal.
- `ingress_proxy_body_size` output: the same derived body-size string, for
  `create_ingress = false` callers to put on their own Ingress instead of a
  literal that can drift from `n8n_payload_size_max`.
- Validation added to `k8s_ingress_host` (FQDN shape), `n8n_chart_repository`
  / `valkey_chart_repository` (reject a trailing slash), `n8n_timezone`
  (IANA shape), `n8n_execution_timeout` / `n8n_execution_timeout_max` /
  `n8n_pruning_max_age` / `n8n_pruning_max_count` /
  `n8n_task_runner_auto_shutdown_timeout` /
  `n8n_task_runner_request_timeout` / `n8n_helm_timeout` /
  `cnpg_instances` / `db_postgresdb_pool_size` /
  `n8n_webhook_hpa_scale_up_stabilization_window_seconds` /
  `n8n_compression_max_decompressed_size_bytes` /
  `n8n_compression_max_zip_entries` (whole-number floors),
  `n8n_binary_data_path` (reject a trailing slash),
  `valkey_chart_version` (exact SemVer), `cnpg_storage_size` /
  `valkey_storage_size` (Kubernetes quantity shape), `cnpg_database_name` /
  `cnpg_database_owner` (unquoted Postgres identifier shape), and
  `n8n_python_stdlib_allow` (rejects the wildcard mixed with named modules,
  which the Python runner's own parser refuses to start on). Every current
  default already satisfies its own new rule, so this only changes when an
  already-broken value fails: at plan time with a clear message instead of
  later, at apply or inside the chart's own JSON-schema validation.

- [`docs/shared-responsibility.md`](./docs/shared-responsibility.md): one
  table collecting every caller-owned piece (cluster, ingress controller,
  cert-manager, the CNPG operator, KEDA, `StorageClass`, metrics-server, DNS,
  secrets and Terraform state, backups, upgrades, monitoring), pulled
  together from `AGENTS.md` and the README.
- [`docs/build-time-decisions.md`](./docs/build-time-decisions.md): inputs
  that can't change, or that change disruptively, after the first apply
  (namespace name, `postgres_backend` / `redis_backend`, CNPG storage size
  and class, the CNPG Postgres major version, the n8n encryption key, binary
  data mode, and the n8n domain), each verified against the resources and
  variable validations that produce the effect.
- [`docs/versioning.md`](./docs/versioning.md): the inventory of every
  pinned version this module carries (Terraform providers, the CI
  toolchain, the n8n and Valkey charts, the n8n application image, the
  CloudNativePG Postgres image), the bump tiers (patch-safe,
  minor-required, verification-required), and what the automated drift
  report can and cannot see. Ported from
  `terraform-aws-n8n/docs/versioning.md`, trimmed to what this module
  actually pins now that it has no cloud account and no cluster of its own.
- `tests/scripts/check-version-drift.sh` (`task version-drift`): reports
  every pin behind upstream as `DRIFT`/`OK`/`ERROR`, reusing
  `tests/scripts/lib/constraints.sh`'s Terraform constraint evaluator.
  Checks the five root Terraform providers plus the two example-only ones
  (`cloudflare`, `godaddy-dns`), the CI toolchain (terraform, tflint,
  terraform-docs, checkov), the n8n Helm chart (ghcr.io's anonymous tag
  list), the Valkey chart (`valkey-io/valkey-helm`'s index.yaml), the n8n
  application version (`n8n_image_tag` against `n8n-io/n8n`'s own
  releases), and `cnpg_postgres_image_tag`'s floating major tag (reported
  as the minor it currently resolves to, not as drift, since it tracks
  upstream automatically). Report-only: never bumps anything, and exits 0
  unless a required tool (curl/jq/python3) is missing. A new weekly
  `.github/workflows/version-drift.yml` runs it and syncs the result to a
  single tracking issue, the same pattern `terraform-aws-n8n` uses.
- `scripts/check-example-parity.sh` (`task example-parity`, local-only):
  diffs the seven homelab examples' declared variable names against
  `examples/homelab` and fails on any undeclared difference, and checks
  that every example declaring `shared_storage_class` documents it with a
  "Shared storage across the pods" README section. Added the missing
  section to `examples/homelab-pgbouncer`, `examples/homelab-ai-assistant`
  and `examples/homelab-cloudflare-split-ingress`, which had the variable
  but no prose explaining it.
- `n8n_extra_ca_pem`, ported from the AWS sibling
  (n8n-io/terraform-aws-n8n#202). PEM-encoded CA certificate(s) the main,
  worker and webhook-processor pods trust for outbound TLS, for a
  TLS-inspecting egress proxy or a private CA. The module stores the PEM in a
  module-managed Secret, mounts it read-only at
  `/etc/n8n-certs/ca-bundle.crt`, and sets `NODE_EXTRA_CA_CERTS`. A private
  key block is rejected at plan time, as is a value with no well-formed PEM
  certificate. Changing the PEM rolls every n8n pod through a
  `checksum/extra-ca` pod annotation. The task runner sidecar is a separate
  container and does not inherit the trust. While set, the volume name
  `"ca-bundle"`, the mount path `/etc/n8n-certs/ca-bundle.crt`, and the env
  name `NODE_EXTRA_CA_CERTS` are reserved against `n8n_extra_volumes`,
  `n8n_extra_volume_mounts`, `n8n_extra_env` and `n8n_extra_env_from_secret`.
  See [`docs/tls-proxy.md`](./docs/tls-proxy.md).
- `db_postgresdb_ssl_reject_unauthorized` and `db_postgresdb_ssl_ca_pem`:
  server-certificate verification for the Postgres TLS connection, on both
  the CNPG and external paths. Defaults preserve existing behavior exactly
  (`db_postgresdb_ssl_reject_unauthorized` defaults to `false`, the value
  this module always hardcoded before). The CA is delivered through the
  chart's `database.ssl.ca` value, the one case this module uses that key;
  `config.extraEnv` still owns `DB_POSTGRESDB_SSL_ENABLED` /
  `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED` on every other path, and a
  chart-version check (the pinned `n8n_chart_version` alone, 1.15.0 or later,
  prereleases excluded, whichever repository serves it) keeps the two from
  ever duplicating a name once a CA is active; a mirror must therefore serve
  the pinned chart unmodified. Two new `check` blocks warn, non-blocking,
  when a CA is set without verification on, or when
  `NODE_TLS_REJECT_UNAUTHORIZED=0` in `n8n_extra_env` would silently defeat
  verification with no CA supplied.
  See [`docs/postgresql-tls.md`](./docs/postgresql-tls.md) (new this
  release) for the CNPG path's per-cluster CA and how to extract it.
- `n8n_node_max_old_space_size_mb`: V8 old-space heap ceiling in MB, emitted
  as `NODE_OPTIONS=--max-old-space-size=<value>` in `config.extraEnv` on
  every n8n container. Null (the default) emits nothing and leaves V8 to size
  the heap itself. `NODE_OPTIONS` is reserved in `n8n_extra_env` only while
  this input is set, so a caller's own unrelated `NODE_OPTIONS` flags stay
  settable with it left null. Ported from this module's AWS sibling.
- `n8n_credentials_overwrite_secret_ref`: mounts one key of an existing,
  caller-managed Kubernetes Secret read-only at
  `/etc/n8n/credentials-overwrite/<key>` on the main, worker and
  webhook-processor pods, and sets `CREDENTIALS_OVERWRITE_DATA_FILE` to that
  path. The module never reads the Secret's contents, so the credential
  overwrite JSON never enters this module's Helm values or Terraform state.
  Reserves the `credentials-overwrite` volume name and
  `/etc/n8n/credentials-overwrite` mount path, and rejects
  `CREDENTIALS_OVERWRITE_DATA`/`CREDENTIALS_OVERWRITE_DATA_FILE` in
  `n8n_extra_env`, while set. Ported from this module's AWS sibling.
- `n8n_dns_config`: pod-level `dnsConfig` (nameservers, search domains,
  `ndots`) applied to the main, worker and webhook-processor pods via the
  chart's top-level `dnsConfig` value. Null (the default) omits the block
  entirely. Chiefly useful for `ndots: 1`, which stops an in-cluster or
  external hostname with fewer than 5 dots from being tried against every
  cluster search domain before being tried as written. Ported from this
  module's AWS sibling.
- `n8n_queue_worker_lock_duration`, `n8n_queue_worker_lock_renew_time` and
  `n8n_queue_worker_stalled_interval`: expose the chart's `redis.worker.lockDuration`,
  `redis.worker.lockRenewTime` and `redis.worker.stalledInterval`
  (`QUEUE_WORKER_LOCK_DURATION`, `QUEUE_WORKER_LOCK_RENEW_TIME` and
  `QUEUE_WORKER_STALLED_INTERVAL` on the pods). All default to `null`, which
  omits the key entirely and leaves the chart's own defaults (60000 / 10000 /
  30000 ms), so this is additive. Ported from terraform-aws-n8n 0.4.0.
  `QUEUE_WORKER_MAX_STALLED_COUNT` is deliberately not exposed: n8n v2 removed
  the environment variable and hardcodes Bull's `maxStalledCount` to 0.
- `n8n_executions_data_save_on_success`, `n8n_executions_data_save_on_error`,
  `n8n_executions_data_save_on_progress` and
  `n8n_executions_data_save_manual_executions`: expose the chart's
  `executions.data.saveOnSuccess` / `saveOnError` / `saveOnProgress` /
  `saveManualExecutions`. All default to n8n's own defaults (`"all"` / `"all"`
  / `false` / `true`), matching what the chart already rendered unconditionally,
  so this is additive: no existing deployment's rendered values change. Ported
  from terraform-aws-n8n 0.4.0. All four names are reserved in
  `local.n8n_managed_env_names`: the chart renders them unconditionally from
  this values path, and a caller also setting one through `n8n_extra_env` would
  duplicate the name in a container's env list, which Kubernetes resolves
  last-wins and which fails the next helm upgrade's strategic merge patch.
- `db_postgresdb_connection_timeout_ms`, `db_ping_timeout_ms` and
  `db_ping_interval_seconds`: expose `DB_POSTGRESDB_CONNECTION_TIMEOUT`,
  `DB_PING_TIMEOUT_MS` and `DB_PING_INTERVAL_SECONDS`. All default to `null`,
  which omits the variable and leaves n8n's own defaults (20000ms / 5000ms /
  2s), so this is additive. Ported from terraform-aws-n8n 0.4.0. Previously
  unsettable by any means: the chart has no values path for them, and `DB_` is
  a module-managed prefix, so `n8n_extra_env` already rejected them at plan
  time with no replacement.
- `postgres_connection_budget_check_enabled`: an opt-in (default `false`)
  advisory `check.postgres_pool_size_fits_known_max_connections`
  (`postgres_cnpg.tf`), comparing `db_postgresdb_pool_size` times the modeled
  main/worker/webhook-processor replica ceiling against `max_connections`.
  Adapted from terraform-google-n8n's
  `postgres_pool_size_fits_known_max_connections` for CNPG: on the `cnpg`
  backend the known value is `cnpg_max_connections`, since the module always
  sets it on the CNPG Cluster's `postgresql.parameters`; on the `external`
  backend, where the module manages nothing on the server, it falls back to
  PostgreSQL's own stock default of 100. Silent behind `cnpg_pooler_enabled`,
  where pod count stops being a term in the connection budget. Advisory only:
  it never fails a plan.

- `n8n_smtp`: SMTP server n8n sends user-management email through (invites,
  password resets, workflow-shared notifications). Null (the default)
  configures no mail, which is n8n's own behavior with no SMTP host set.
  Renders `N8N_EMAIL_MODE=smtp` plus the `N8N_SMTP_*` family on every pod
  type; `port` defaults to `465` and `ssl` to `true` (implicit TLS), `user`
  is optional for unauthenticated relays. The password never passes through
  this input: `password_secret_ref` names an existing Secret and key (key
  defaults to `"password"`) read as a `secretKeyRef`, so it never lands in
  Terraform state or the Helm release values. `N8N_EMAIL_MODE` and the full
  `N8N_SMTP_*` family are reserved against `n8n_extra_env`.
- `n8n_diagnostics_enabled`: the telemetry off switch. Maps to
  `N8N_DIAGNOSTICS_ENABLED`. Null (the default) omits the env var, so n8n's
  own default (`true`, phones home to telemetry.n8n.io and PostHog) stands
  untouched; set `false` to turn it off. Reserved against `n8n_extra_env`
  regardless of whether it is set.

- `examples/homelab-godaddy` documents what a trusted certificate needs.
  cert-manager has no GoDaddy DNS-01 solver, so an issuer scoped to another
  zone leaves the Order pending. The README now lists the three ways out
  (HTTP-01 on a publicly reachable address, a GoDaddy webhook solver, or
  CNAME delegation of `_acme-challenge` to a zone cert-manager can solve) and
  carries the CNAME-delegation recipe, validated live against a GoDaddy
  domain with a real Let's Encrypt certificate.
- `otel_endpoint` in `examples/homelab`, `examples/homelab-cloudflare`,
  `examples/homelab-godaddy` and `examples/homelab-pgbouncer`: the four
  examples switched OTel tracing on unconditionally and aimed it at a
  hardcoded collector address, with no variable to point elsewhere and no
  way to turn it off short of editing `main.tf`. `otel_endpoint` defaults
  to that same address, so no existing caller's rendered configuration
  changes; set it to a different collector or to `null` to disable tracing
  instead. `n8n_otel_enabled`, the exporter service name, sample rate and
  `production_only` all key off whether it is set.

- `valkey_append_only_enabled`: turns on Valkey's append-only file so the
  Bull queue survives a crash. The chart's generated config carries no
  persistence directives at all, so the server ran on its built-in
  defaults, RDB snapshots only, taken as rarely as once an hour under light
  write load; a crash or OOM kill between snapshots silently lost every job
  accepted since the last one, from both ends: the webhook had already
  answered 200 and no worker would ever see the job. Default `false`: this
  module ships the tradeoff off rather than on, since the write
  amplification it costs has no pre-existing promise to keep, unlike a
  module that already documented always-on durability. Set it `true` for
  any deployment where losing an hour of accepted jobs is not acceptable.

- `valkey_password_rotation_roll_enabled`: opt-in `checksum/valkey-password`
  pod annotation on both the n8n and Valkey releases, so a password rotation
  rolls both sides in one apply instead of leaving every pod on the old
  credential until an unrelated restart. See the entry under `### Fixed` for
  why this ships off by default rather than unconditionally.

- A `kubernetes_job_v1.cnpg_ready` readiness barrier, unconditional whenever
  `postgres_backend = "cnpg"`. `kubectl_manifest.cnpg_cluster` applies the
  Cluster custom resource and returns without waiting for it: the
  gavinbunney/kubectl provider's `wait_for_rollout` speaks Deployment,
  StatefulSet and DaemonSet, and a CNPG Cluster is none of those. On a
  brand-new install this raced n8n's own pods against `initdb`, which
  usually self-heals through a CrashLoopBackOff or two but, on a slow
  cluster, can instead expire the Helm release's own wait and roll the whole
  atomic install back with a timeout that never mentions the database. The
  new Job polls the Cluster's `rw` Service with `pg_isready`, reusing the
  same operand image the Cluster runs so no new image needs pulling, and the
  `helm_release.n8n` resource now depends on the Job instead of the Cluster
  manifest directly. Carries no `ttl_seconds_after_finished`: the TTL
  controller deletes the Job object itself, not just its completed pod,
  which previously manufactured a permanent `1 to add` on every plan past
  the TTL window. **On an existing CNPG-backed deployment's first apply
  after taking this change: one new Job object to add, nothing else
  touched.** Where CNPG is already up, `pg_isready` succeeds on its first
  attempt and the Job completes in seconds; no existing resource is
  modified and no pod is restarted.

- `cnpg_cpu_request`/`cnpg_cpu_limit`/`cnpg_memory_request`/`cnpg_memory_limit`,
  the equivalent `cnpg_pooler_*` quartet, and `valkey_cpu_request`/
  `valkey_cpu_limit`/`valkey_memory_request`/`valkey_memory_limit`: size the
  CNPG Cluster, the PgBouncer Pooler (while enabled) and the Valkey release.
  All twelve default `null`, which renders no `resources` key at all, the
  BestEffort scheduling this module has always produced; a caller who sets
  nothing sees no change to any rendered manifest. Counted into `scaling.tf`'s
  peak-CPU demand model (`cnpg_instances` × the Postgres request, the current
  `cnpg_pooler_instances` × the pooler request while the pooler is enabled,
  one Valkey term while the backend is valkey) only while the corresponding
  input is actually set, so an unsized backend contributes nothing to the
  capacity warning either, matching the rendered reality rather than assuming
  a size nobody asked for.

- `k8s_namespace_labels` / `k8s_namespace_annotations` (both `map(string)`,
  default `{}`): stamped on the namespace the module creates, caller labels
  merged last so they win. The main use is Pod Security Admission: the
  `pod-security.kubernetes.io/enforce` label has to sit on the namespace, an
  object the caller could not otherwise reach on the path where this module
  creates it, so the only previous route to a PSS-enforced deployment was
  `create_namespace = false` and owning the namespace outside the module.
  Annotations are a separate input because Kubernetes reads the two
  differently: admission and label selectors read labels, while quota and
  GitOps tooling usually read annotations. At the defaults the namespace
  renders exactly as it did before: one label
  (`app.kubernetes.io/managed-by`) and no annotations.

- `n8n_extra_env` and `n8n_extra_env_from_secret` now carve a fixed list of
  official n8n environment names out of the `DB_` / `QUEUE_` prefix guard
  (`local.n8n_env_carveouts` in `locals.tf`), checked before the prefix rule
  so these exact names pass while everything else under the prefixes stays
  blocked. The guard protected module-written connection settings but also
  caught names n8n reads directly and this module writes nowhere: the
  external-Postgres mutual-TLS client certificate and key
  (`DB_POSTGRESDB_SSL_CERT` / `DB_POSTGRESDB_SSL_KEY`, which n8n's own
  `PostgresSSLConfig` reads with no chart value and no typed input here),
  Postgres client tuning and health-check recovery tuning, query logging,
  the shared-database table prefix, and the Redis client TLS/keep-alive
  names the chart has no values path for. Every name was read directly out
  of n8n 2.44.5's own config source rather than assumed. Deliberately
  excluded: `DB_POSTGRESDB_SSL_CA`, `DB_POSTGRESDB_CONNECTION_TIMEOUT`,
  `DB_PING_TIMEOUT_MS` and `DB_PING_INTERVAL_SECONDS` already have a typed
  input each (`db_postgresdb_ssl_ca_pem` and friends); carving them out too
  would open a second door to the same destination.

- Two advisory `check` blocks (warnings only, never failing a plan):
  `check.cnpg_has_no_backup_configured` fires when `postgres_backend =
  "cnpg"` and neither `cnpg_backup` nor `cnpg_plugins` is set, since the
  deployment's only copy of every workflow, credential and execution is then
  one PVC; silenced by configuring either backup input, or by the new
  `cnpg_backup_acknowledged` input (default `null`, read by nothing, exists
  only so the check can see that the trade was deliberate).
  `check.lan_expose_ip_is_allocator_specific` fires when `metrics_lan_expose.ip`
  or `cnpg_lan_expose.ip` is set with no `annotations` alongside it: that
  field renders exactly one annotation, for whichever LB-IPAM allocator it
  was written against, and every other allocator ignores that key and hands
  out an arbitrary address with nothing reporting the drop. All seven
  examples now set `cnpg_backup_acknowledged = false` with a comment
  explaining why, since a homelab deployment's only copy of the database
  being its PVC is the documented shape there.
- `n8n_redis_timeout_threshold`'s description and a new
  `docs/troubleshooting.md` entry now document a measured failure mode
  specific to this module's default backend: a single-replica Valkey
  (`redis_backend = "valkey"`) has no standby, so at the default (`null`,
  effectively 10 seconds) every n8n pod crashes on Redis loss about 11
  seconds into any Valkey interruption. A live test that deleted the
  Valkey pod measured 31 seconds for it to come back, giving about 45
  seconds of webhook failures before self-recovery. Setting this input to
  `60000` rides out an outage of that length. Documentation only; the
  default stays `null`.
- `cnpg_ready_timeout` (number, seconds, default `600`): seconds the
  readiness barrier (`kubernetes_job_v1.cnpg_ready`) polls the CNPG
  Cluster's `rw` Service with `pg_isready` before failing. The Job's poll
  loop, added earlier in this same Unreleased section, was 300 attempts x a
  2-second sleep; the default of `600`
  reproduces that exact budget, so a deployment that leaves it unset renders
  and behaves unchanged. Independent of `n8n_helm_timeout`: this Job
  completes, one way or the other, before `helm_release.n8n`'s own wait even
  starts, so raising `n8n_helm_timeout` alone could not give a healthy but
  slow bootstrap (large WAL replay, cold storage, a busy cluster) more time
  here. The Job's own Terraform `timeouts.create` now derives from this
  input (`cnpg_ready_timeout + 300s`) instead of a separate hardcoded `15m`,
  so the two budgets cannot drift apart again.

### Changed

- `examples/homelab-cloudflare` and `examples/homelab-cloudflare-split-ingress`
  now require the Cloudflare provider `~> 5.0`, replacing the
  `>= 4.0, < 4.52.7` cap. The cap existed because 4.52.7 was believed to break
  `api_token` sourced from a sensitive Terraform variable, the exact shape
  both examples use; live-tested against a real zone on 2026-10-21, that
  belief did not hold; 4.52.7 through the newest 4.x release all configure
  and apply correctly. Both examples' `cloudflare_record.n8n` is renamed to
  `cloudflare_dns_record.n8n` (the v5 rewrite's resource rename) with a
  `moved` block, so an existing deployment's next `terraform init -upgrade`
  and `apply` carries the record's state across with no destroy/recreate:
  live-verified for both the single-record (`count`) and two-record
  (`for_each`) shape, on Terraform 1.11.4, a newer 1.x Terraform, and
  OpenTofu. The record's `ttl` is now set explicitly to `1` (automatic):
  required in v5, where v4 left it computed.

- **`n8n_execution_concurrency_limit` default `100` -> `-1`.** Breaking
  behavior change. n8n 2.44.5's `worker.ts` reads
  `N8N_CONCURRENCY_PRODUCTION_LIMIT` before the worker's own `--concurrency`
  flag and only falls back to the flag when that env var is `-1`; with the
  old default of `100`, every worker independently ran at its own
  concurrency ceiling of 100 regardless of `n8n_worker_concurrency` (default
  `10`), with no coordination between workers. A high per-worker ceiling let
  whichever worker was already running absorb a burst well before queue
  depth ever crossed the threshold that would make KEDA add useful capacity.
  Confirmed live: a 40-job burst ran entirely on one worker under the old
  default with added replicas receiving zero jobs; with
  `n8n_execution_concurrency_limit = -1` a 1000-job burst spread evenly
  across 6 workers. **Effect on an existing deployment:** on the next
  `apply`, effective per-worker concurrency drops from 100 to
  `n8n_worker_concurrency` (default `10`), and every worker pod rolls once as
  its env changes. Size `n8n_worker_concurrency` and
  `n8n_worker_keda_min_replicas` / `_max_replicas` for the new effective
  ceiling (`replicas x n8n_worker_concurrency`) before applying. Set
  `n8n_execution_concurrency_limit = 100` to keep the previous behavior.
  `n8n_worker_concurrency`'s description now states the same dependency.
  See [`docs/operations.md`](./docs/operations.md#worker-autoscaling) and
  [`docs/upgrading-n8n.md`](./docs/upgrading-n8n.md).

- `n8n_domain` / `n8n_additional_domains`: tightened the fully-qualified
  hostname validation to a per-label grammar (no label may start or end with
  a hyphen, no empty label, so a doubled dot is also rejected) plus explicit
  253-character/63-character-per-label length limits, matching this module's
  AWS sibling. The previous single-character-class regex accepted malformed
  names such as `a--b..com`.

- `n8n_image_tag` default `2.36.2` -> `2.44.5`, the latest stable n8n release
  (2.45.0 is a prerelease and is not used). **This upgrades n8n on the next
  apply and runs database migrations**: back up the database first and read
  `docs/upgrading-n8n.md`. The `n8nio/n8n` and `n8nio/runners` `2.44.5` tags
  are both published.
- `valkey_chart_version` default `0.11.0` -> `0.12.0` (Valkey 9.1.1 -> 9.1.2).
  The chart's `values.yaml` is identical between the two versions.

- `n8n_chart_version` default bumped `1.10.0` -> `1.17.0`
  (`oci://ghcr.io/n8n-io/n8n-helm-chart/n8n`, appVersion 2.44.5).
  `n8n_image_tag` is bumped separately to `2.44.5` (see above).
  Verified by rendering this module's own values through both chart
  versions (`tests/scripts/check-n8n-chart.sh`, new this release):
  - The worker Deployment's `spec.replicas` is now omitted once an
    autoscaler owns the count (chart >= 1.13.0,
    n8n-io/n8n-hosting#201), which this module's worker always
    satisfies. **One-time effect:** the first `helm upgrade` onto this
    chart version drops the live worker replica count to Kubernetes'
    default of 1 until the autoscaler (KEDA or the CPU HPA) restores
    the configured floor. No input change needed; see
    `docs/upgrading-n8n.md`.
  - Main pods no longer carry the task-runner sidecar; it now runs on
    worker pods only, matching this module's always-on queue mode.
  - `n8n_main_pdb_enabled = true` no longer renders a
    `PodDisruptionBudget`: chart 1.16.0 gates it on main running more
    than one replica (n8n-io/n8n-hosting#228), which this module never
    does. The now-moot `main_pdb_blocks_the_main_pod_node_drain` check
    was removed from `n8n.tf`.
  - An unset `n8n_image_tag` now resolves to the chart's own
    appVersion instead of the floating `stable` tag (chart >= 1.12.0).
  - The chart's own webhook Ingress routes `/mcp` directly as of chart
    1.16.0. The supplementary `kubernetes_ingress_v1.n8n_mcp` resource
    this module rendered to cover that gap was removed: an
    unconditionally empty `dynamic "path"` block fails the Kubernetes
    provider's Ingress schema validation, so leaving it dormant was not
    an option. **Resource deletion:** `terraform apply` after this bump
    destroys that Ingress on any deployment with `create_ingress =
    true`.
  - The chart-rendered env var `WEBHOOK_URL` was renamed to
    `N8N_WEBHOOK_URL` (n8n deprecated the old name as of n8n 2.35.0).
    This module's reserved-name list and its split-ingress `extraEnv`
    injection moved to the new name to match.
  - Worker readiness and liveness probes now check real health instead of
    only process existence. Chart 1.17.0 flips `redis.healthCheck.enabled`'s
    own default to `true` (n8n-io/n8n-hosting#233), which this module does
    not override: the worker's readiness probe moves from an always-passing
    `pgrep -f 'n8n worker'` exec check to an `httpGet` probe against
    `/healthz/readiness` (gated on the worker's own DB and Redis
    connection), the liveness probe moves to `httpGet` `/healthz`, and a new
    startup probe (up to 300s) holds off liveness while database migrations
    run. **Effect on an existing deployment:** every worker pod rolls once
    as its probes and the new `QUEUE_HEALTH_CHECK_ACTIVE` env var change;
    see `docs/upgrading-n8n.md`.

- **Provider constraints widened to the v3 line: `hashicorp/kubernetes`
  `~> 2.0` -> `~> 3.0`, `hashicorp/time` `~> 0.12` -> `~> 0.14`** (root, all
  seven examples, and `modules/cluster-capacity`; `modules/tls-letsencrypt`
  declares neither provider). Matches the `~> 3.0` / `~> 0.14` pins the AWS,
  Google and Azure siblings already carry. **BREAKING for any caller whose
  own root module pins `kubernetes` to `~> 2.0`:** `terraform init` cannot
  satisfy both constraints at once, so that caller's own provider
  requirement must move to `~> 3.0` (or an unconstrained/wider range) before
  picking up this version; see `docs/upgrading-n8n.md`. `terraform validate`
  now prints a cosmetic "Deprecated Resource" warning for
  `kubernetes_namespace.n8n` and the four unversioned `kubernetes_secret`
  resources in `n8n.tf` (`n8n`, `n8n_db`, `n8n_redis`, `n8n_ca_bundle`):
  kubernetes provider 3.x deprecates the unversioned resource types in favor
  of their `_v1` equivalents. They are not renamed here: the provider has no
  `moved` support across that rename
  (`hashicorp/terraform-provider-kubernetes` issue #2812), and renaming
  without one would destroy and recreate the namespace, taking every object
  in it with it. A rename to the `_v1` types is tracked as a separate,
  deliberate change behind `moved` blocks once the provider supports them.
  All ten `.terraform.lock.hcl` files (root, seven examples, both
  submodules) regenerated for `linux_amd64`, `linux_arm64` and
  `darwin_arm64`.

- CI's `TF_VERSION` pin (`.github/workflows/terraform-tests.yml`) bumped
  `1.16.6` -> `1.17.0`, the current latest stable release. Read in full
  against this module: no breaking change applies (Terraform Policy going
  GA, provider-requirement variables/locals, and ephemeral-resource
  diagnostics are all features this module does not use). The full
  `terraform test` suite (root, every example, both submodules) passes
  identically on `1.17.0`, the `TF_FLOOR_VERSION` floor (`1.11.4`), and the
  previous pin (`1.16.6`). `TF_FLOOR_VERSION` is unchanged: the floor stays
  the floor.

- `CHECKOV_VERSION` (`.github/workflows/terraform-tests.yml`) bumped
  `3.3.9` -> `3.3.30`, the latest release. No new findings: the tree still
  scans 14 passed, 0 failed, 0 skipped, with and without the `tests/`
  `skip-path` exclusion, matching the baseline `.checkov.yaml` already
  documented. No `checkov:skip` annotation was needed.

### Fixed

- `n8n_chart_repository` set to an `https://` mirror now resolves correctly.
  `helm_release.n8n` built the OCI shape unconditionally regardless of
  scheme; the Helm provider resolves an `https://` repository through its
  index.yaml, which needs the repository and the bare chart name as separate
  arguments (the shape `helm_release.valkey` already used), not a single
  interpolated URL. The `oci://` branch (the default) is unchanged.
- An explicit `null` on `n8n_webhook_cpu_request` / `_cpu_limit` /
  `_memory_request` / `_memory_limit` or `n8n_reinstall_missing_packages` no
  longer aborts the plan with a template error from inside the warn-only
  `check.webhook_resources_sized_for_reinstall_missing_packages`. All five
  now carry `nullable = false`, so an explicit `null` falls back to the
  declared default instead of propagating into the module.
- `valkey_password_rotation_roll_enabled` (new, default **false**): turns on
  a `checksum/valkey-password` podAnnotation on both the n8n release and the
  Valkey release, so rotating the module-generated Valkey password rolls
  both sides in one apply. The password reaches n8n pods through a
  `secretKeyRef` resolved once at start and reaches Valkey as an ACL file
  loaded once at start, so without this a rotation updates the Secret and
  restarts nothing: every pod keeps the old credential until an unrelated
  restart lands on one side first, breaking the queue until the other side
  catches up. **Off by default, not just gated on the backend.** Introducing
  the checksum key into `podAnnotations` for the first time is itself a
  pod-template change, and with `deploymentStrategy = "Recreate"` (below)
  already in place, that first change takes Valkey fully down and back up
  once rather than overlapping, since the standalone PVC is `ReadWriteOnce`.
  A caller who has rotated nothing and asked for nothing should not eat that
  outage as a side effect of taking this module version; turn this on
  deliberately to get rotation-triggered rolls, and expect that one apply to
  interrupt the queue briefly. The external-redis path renders unchanged
  regardless of the toggle, since there is no module-generated credential to
  hash.
- `task_runners_config.tf`'s header now names the coupling between the
  mounted launcher config and the `n8nio/runners` image's own interpreter
  and entrypoint paths: the ConfigMap replaces the image's config wholesale,
  so an image release that moves those paths breaks both runners at once,
  silently. `docs/upgrading-n8n.md` gains a pre-bump step to diff the new
  image's own config against what this file renders before rolling out a
  runner-image change.

- The Valkey release no longer uses the chart's default `RollingUpdate`
  deployment strategy. In standalone mode (`replica.enabled = false`, the
  chart default and this module's only supported shape) the chart renders a
  Deployment against a `ReadWriteOnce` data PVC, so a rolling update starts
  the new pod while the old one still holds the volume: the new pod
  deadlocks on a Multi-Attach error and the rollout hangs until someone
  deletes a pod by hand. `deploymentStrategy = "Recreate"` is now rendered
  unconditionally, since `RollingUpdate` can never work against a
  single-attach volume on this chart; there is no input, because there is
  no working alternative to withhold it for. Latent until the first
  in-place Valkey values change, which `valkey_append_only_enabled` above
  is exactly such a change.
- **`n8n_timezone`, when set away from its default (`"UTC"`), now also
  drives `GENERIC_TIMEZONE`, not only `TZ`.** The chart renders `TZ` (the
  process clock, log timestamps) from `config.timezone`, but no template in
  the pinned chart renders `GENERIC_TIMEZONE`, which is the setting n8n's
  scheduler actually reads for Schedule Triggers; n8n's own default for it
  is `America/New_York`, not `UTC`. Any deployment that set `n8n_timezone`
  to a non-UTC value has therefore been firing scheduled workflows on US
  Eastern time regardless of that setting, while the log timestamps made the
  configuration look honored. **Effect on an existing deployment:** a
  deployment at the default `"UTC"` (set or unset) renders identically, no
  pod rolls. A deployment with a non-UTC `n8n_timezone` rolls once on the
  next `apply` as the new env var is added, and every Schedule Trigger
  starts firing at the time `n8n_timezone` actually names instead of US
  Eastern. If such a workflow's schedule was tuned, even unknowingly, to
  land at the right wall-clock time under the old US-Eastern behavior, that
  workflow's effective firing time moves on this upgrade; review schedules
  before applying if timing is load-bearing and `n8n_timezone` is not
  `"UTC"`.

- The `shared_storage_class` validation in all seven examples is now written
  `x == null ? true : (...)` instead of `x == null || (...)`. On Terraform
  1.11.4, the module's declared floor, the `||` form evaluates its right side
  even when `x` is null, so `length(null)` and `trimspace(null)` raised
  "argument must not be null" and every example's `terraform test` failed
  before its first run. Terraform short-circuits `&&`/`||` from 1.12 onward,
  which is why CI (which pins a newer version) never saw it. No behavior
  change on any version that worked before. Found by running the whole suite
  on 1.11.4.

- `examples/homelab-cloudflare` now exposes `proxy_hops`, defaulting to `2`,
  and passes it to `n8n_proxy_hops`. It had no such input and so inherited
  the module default of `1`, which is right behind ingress-nginx alone and one
  short behind the Cloudflare edge and `cloudflared`, the same chain
  `examples/homelab-cloudflare-split-ingress` already counts as `2`. With the
  count one too low n8n treats a proxy address as the client, which collapses
  every rate limit and IP restriction keyed on the client address onto one
  source, with no error. Found in a live test (`N8N_PROXY_HOPS=1` observed on
  all three pod types). An existing deployment of this example gets
  `N8N_PROXY_HOPS=2` on its next apply, which rolls the n8n pods once; set
  `proxy_hops = 1` to keep the old value.

- `n8n_compression_max_decompressed_size_bytes` and
  `n8n_compression_max_zip_entries` now render the environment variable
  names n8n actually reads: `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES`
  and `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES`. The module previously emitted
  both names without the `NODE_` infix, which n8n does not recognize, so a
  workflow unzipping an archive larger than the configured limit was never
  actually bounded, and a smaller limit intended as hardening was never
  applied. The two previously-reserved correct names were also free for a
  caller to set through `n8n_extra_env`, which would have produced a
  duplicate environment entry and failed the next `helm upgrade`, once the
  rendered names were aligned to match. Neither input's default changed
  (both remain `null`); this only affects a deployment that already sets
  one of them.

- `n8n_webhook_hpa_scale_up_stabilization_window_seconds` now governs the
  supplementary webhook HPA this module renders itself
  (`kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook_processor`) whenever
  `k8s_keda_installed = true`. That autoscaler exists because the chart
  renders no webhook HPA of its own while KEDA is enabled, and it previously
  hardcoded `stabilization_window_seconds = 0`, so the input worked on the
  chart's own HPA path only. Following `docs/troubleshooting.md`'s own
  advice to raise this value and fix a scale-up-on-every-rollout loop had no
  effect at all on a cluster with KEDA attested. The input's default (`0`)
  is unchanged, so this only affects a deployment that already sets a
  non-zero value with KEDA attested.
- `n8n_task_runner_cpu_request`, `_cpu_limit`, `_memory_request` and
  `_memory_limit` now reach the task-runner sidecar container. The chart
  reads the sidecar's resources exclusively from `taskRunners.resources`
  (`_helpers.tpl`'s `n8n.taskRunnerContainer` helper); this module rendered
  them under `resources.taskRunner` instead, a key the top-level `resources`
  block does not define and no template reads, so every sidecar ran on the
  chart's own `100m`/`256Mi` defaults regardless of these four inputs'
  values. **Effect on an existing deployment:** on the next `apply`, the
  task-runner sidecar's actual CPU/memory requests and limits move from the
  chart's defaults to whatever these four inputs are set to (`200m`/`1`
  CPU, `512Mi`/`1Gi` at this module's own defaults), which rolls the worker
  pod (queue mode always runs the sidecar on worker, not main). No input's
  default changed; this restores the resource sizing the variables'
  descriptions have always documented.

- `n8n_domain` and `k8s_ingress_host_effective` (the local `k8s_ingress_host`
  falls back to) are now lower-cased once at their single definition, rather
  than only where `k8s_ingress_hosts` built the chart's own Ingress host
  list. A mixed-case hostname passes both inputs' FQDN validations (DNS is
  case-insensitive), but it previously reached `N8N_HOST`, the editor base
  URL, the webhook URL fallback, the `n8n_url` output and the derived TLS
  Secret name verbatim, in whatever case the caller typed, while only the
  routed Ingress host was normalized. A Kubernetes Secret name is a
  lowercase-only RFC 1123 subdomain, so a mixed-case `k8s_ingress_host`
  previously failed the apply on a generated internal name with an error
  that never mentioned casing; the URL mismatches were silent, since DNS and
  most OAuth providers tolerate case but a byte-for-byte comparison (e.g. a
  split-ingress mode decision keyed on whether two URLs are equal) does not.
  No deployment with an already-lowercase `n8n_domain`/`k8s_ingress_host`
  (the overwhelming majority, since a mixed-case `k8s_ingress_host` could not
  previously deploy at all) sees any rendered value change.

- `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS` and
  `N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL` are no longer reserved names. Both
  sat in `n8n_managed_env_names` under a comment implying the module sets
  them; neither was ever rendered anywhere, so the reservation only blocked
  a caller from setting either through `n8n_extra_env`. Both are now
  settable there.
- The KEDA worker `ScaledObject`'s Redis triggers no longer carry an
  `authenticationRef = { name = "" }` key. `passwordFromEnv` already
  resolves the queue password from the worker container directly, so there
  was no `TriggerAuthentication` object for the empty name to reference.
  KEDA has tolerated the empty value in practice; this removes a rendered
  value that named a nonexistent object before a future KEDA version
  starts validating it.
- Two `coalesce()` calls in `metrics_lan.tf` and `postgres_lan.tf` guarded
  `var.*_lan_expose.enabled` against `null`, but that attribute is declared
  `optional(bool, false)`, so Terraform substitutes the default for an
  absent or null value before `coalesce()` ever runs. Read directly now;
  no behavior change.
- `kubernetes_secret.n8n`'s `N8N_PORT` value now derives from
  `local.n8n_service_port` instead of a second, independent hardcoded
  `"5678"` literal. Renders the same value today; the two could previously
  drift independently.
- `examples/homelab-cloudflare`, `examples/homelab-cloudflare-split-ingress`
  and `examples/homelab-godaddy` now plan with no DNS credentials in the
  environment. Each example's DNS provider block was configured
  unconditionally, and a provider block cannot be made conditional, so the
  plugin initialized and rejected an empty credential on every plan, even
  on the documented no-DNS path where the zone/domain variable is left
  `null` because records are managed elsewhere: `must provide exactly one
  of "api_key", "api_token" or "api_user_service_key"`. Each provider now
  takes a placeholder credential only on that path; `dns.tf` creates no
  record without the gating variable, so the placeholder is never sent
  anywhere. The `GODADDY_API_KEY`/`GODADDY_API_SECRET` stub requirement
  for `terraform test`/`terraform plan` on the default path is gone with
  it; dropped from `Taskfile.yml`, the CI workflow, `AGENTS.md` and
  `CONTRIBUTING.md`. A real `apply` against GoDaddy still needs real
  credentials, unchanged.

- `examples/homelab-split-ingress` and
  `examples/homelab-cloudflare-split-ingress` now set their own Ingress's
  `nginx.ingress.kubernetes.io/proxy-body-size` annotation from
  `module.n8n.ingress_proxy_body_size` instead of a hardcoded `"32m"`
  literal, so the example and the module's own derivation cannot drift
  apart. The output defaults to the same `"32m"` while
  `n8n_payload_size_max` is left null, so both examples render identically
  until a caller sets that input.
- `check.cnpg_resource_request_not_above_limit` now fires only when
  `postgres_backend = "cnpg"`. The four inputs it compares
  (`cnpg_cpu_request`/`_limit`, `cnpg_memory_request`/`_limit`,
  `cnpg_pooler_cpu_request`/`_limit`, `cnpg_pooler_memory_request`/`_limit`)
  are each documented as only used on the CNPG path, but the check itself
  ran unconditionally: a caller on `postgres_backend = "external"` with one
  of these set above its own limit got an apply-time error over values that
  reach no Cluster or Pooler at all, matching the gating every other CNPG
  check in `postgres_cnpg.tf` already uses.
- `examples/homelab-godaddy`'s `godaddy-dns` provider block no longer
  substitutes a placeholder credential for a typed `godaddy_api_key` /
  `godaddy_api_secret` that is merely unset while its *other* typed
  counterpart is explicitly set. The placeholder gate previously evaluated
  each credential only against `godaddy_domain`, so a caller who set one
  typed credential explicitly and left the other to its
  `GODADDY_API_KEY`/`GODADDY_API_SECRET` environment variable got that
  variable's half silently overwritten by a placeholder on the destroy path
  (`godaddy_domain` turned `null` while a prior record is still in state),
  and GoDaddy rejected the delete with the record stranded in state. The
  gate now also requires the other typed credential to be unset, so a
  partially-typed credential pair keeps falling back to its environment
  variable on that path, same as before this bug, and placeholders apply
  only on the genuine both-unset no-DNS path they were meant for.

### Removed

- `N8N_RUNNERS_ENABLED` and the `n8n_runners_enabled` input 0.3.1 added. The
  variable is deprecated in n8n 2.x and inert: setting it logs a deprecation
  warning and nothing else. `n8n_task_runners_enabled` renders the sidecar and
  the request timeout, as it did in 0.3.0.

### Added (tooling)

- `tests/scripts/chart-values-diff.sh`: diffs the pinned and a candidate
  n8n chart version's `values.yaml`. `task chart-diff CANDIDATE=<version>`.
- `tests/scripts/check-n8n-chart.sh`: renders this module's own values
  tree through the pinned chart offline and asserts the chart-render
  behaviors above, so a future chart bump catches regressions in any of
  them before `n8n_chart_version`'s default moves. `task chart-check`.
- `tests/scripts/check-helm-chart-coverage.sh`: fails when
  `docs/helm-chart-coverage.md`'s version line goes stale, or the chart
  grows a top-level key the doc never mentions. `task chart-coverage`.
- `tests/scripts/lib/tf-defaults.sh`: shared helper the three scripts
  above use to read a variable's default out of `variables.tf`.
- `tests/scripts/check-n8n-chart.sh` gained a Postgres TLS CA scenario:
  proves against the real pinned chart that exactly one
  `DB_POSTGRESDB_SSL_ENABLED` and one `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED`
  reach the main Deployment's env once `db_postgresdb_ssl_ca_pem` is active,
  alongside `DB_POSTGRESDB_SSL_CA` itself.

## [0.3.1], The AI Assistant example and the broker that never started

The `homelab-ai-assistant` example (n8n's AI Assistant and Agents module
wired to an in-cluster `n8n-sandbox-service`, the `runner.isolation:
privileged` path that works on Talos and other immutable-rootfs
distributions), a rewrite of `docs/ai-assistant.md`'s stale Sandbox
section, and one production fix: `n8n_task_runners_enabled` rendered the
runner sidecar without emitting `N8N_RUNNERS_ENABLED`, so the task
broker never started and Code nodes silently ran in n8n's own process.
Upgrading a deployment with task runners enabled rolls main, worker and
webhook-processor (the env list changes), and code execution moves into
the sidecar - where it was documented to be all along.

### Added

- `n8n_runners_enabled` starts n8n's task broker without the sidecar, for
  n8n's internal launcher (a child process of n8n, JavaScript only) or for
  task runners operated outside this module. Default false: the sidecar path
  does not need it, because `n8n_task_runners_enabled` implies the broker (see
  Fixed below), so on a default deployment this toggle adds nothing and stays
  off until broker-without-sidecar is a deliberate choice. Either toggle is
  the only door to the variable - the `N8N_RUNNERS_` prefix reservation on
  `n8n_extra_env` and `n8n_extra_env_from_secret` rejects
  `N8N_RUNNERS_ENABLED` at plan time, now pinned by tests for both inputs.

- `examples/homelab-ai-assistant`, the base deployment with n8n's AI Assistant
  and Agents module turned on and wired to a `n8n-sandbox-service` code
  sandbox. Documents (and tests) the n8n-side wiring only; the sandbox itself
  is a caller prerequisite, same as the ingress controller or the CNPG
  operator, because its Helm chart is not published to a chart repository yet.
  The README walks through standing it up with `runner.isolation: privileged`,
  the config verified end to end on Talos and the other immutable-rootfs
  distributions that cannot install the chart's default sysbox isolation. The
  install command pins `fullnameOverride=sandbox`: the example builds
  `N8N_SANDBOX_SERVICE_URL` as `<release>-api`, and without the override the
  chart's fullname helper concatenates release and chart name, so the Service
  renders as `sandbox-n8n-sandbox-service-api` and n8n points at a name that
  does not exist.

### Fixed

- `n8n_task_runners_enabled` now emits `N8N_RUNNERS_ENABLED=true` into
  `config.extraEnv`. The chart's `taskRunners.enabled` renders the
  `n8nio/runners` sidecar, its auth-token Secret, `N8N_RUNNERS_MODE` and the
  broker listen address, but no template in 1.10.0 or 1.11.0 emits
  `N8N_RUNNERS_ENABLED`, and n8n's own default is false. The broker therefore
  never listened on 5679, the sidecar sat on "Waiting for task broker to be
  ready..." with zero registrations, and Code nodes ran inside n8n's own
  process. Observed live: executions succeed, the pod is 2/2 Ready, and the
  isolation the sidecar exists for is silently absent. The sidecar toggle now
  implies the broker (an OR with `n8n_runners_enabled`, not a second knob to
  forget), a test pins the emission, and the existing disabled-path test
  proves both toggles off emits nothing.

### Changed

- `docs/ai-assistant.md`'s Sandbox section replaced: it previously pointed
  Talos readers at a hand-rolled Docker-in-Docker translation of the sandbox's
  `compose.yaml` topology. That path is superseded by `n8n-sandbox-service`
  chart 0.4.0's own `runner.isolation: privileged`, upstream as of
  [n8n-io/n8n-sandbox-service#126](https://github.com/n8n-io/n8n-sandbox-service/pull/126)
  and verified working on the same cluster the hand-rolled version was.

## [0.3.0], The single-main rollout and the backup story

Single-main rollouts made real (`n8n_main_strategy`, Recreate by default),
node drains unblocked (both PodDisruptionBudgets off where they could only
refuse), a backup story for CNPG (`cnpg_backup`, `cnpg_plugins`,
PostgreSQL 18), the chart's NetworkPolicy as a typed input, and a fix sweep
(#35-#53) for inputs that never reached the chart. Minor rather than patch,
because the defaults moved: the n8n image tag is now pinned, the main rolls
by Recreate, and a fresh CNPG cluster runs PostgreSQL 18 — each a change an
existing deployment must read about before taking. Every headline claim in
this release has since been validated live against a real cluster; the
comments and descriptions cite what was observed.

### Added

- `cnpg_plugins` writes the CloudNativePG Cluster's `spec.plugins`, the CNPG-I
  declaration list the Barman Cloud Plugin is configured through. Null by
  default. A verbatim passthrough for the same reason `cnpg_backup` is one:
  this is the surface CNPG's backup story is actively moving onto, and a typed
  input would freeze one snapshot of it. The plugin's own installation and its
  `ObjectStore` resource stay with the caller; `docs/operations.md` has the
  worked example of both. Needs CloudNativePG 1.26 or newer for the Barman
  Cloud Plugin; an operator too old to know `spec.plugins` prunes the field
  silently, the same failure shape `cnpg_pdb_enabled` documents.
  `check.cnpg_plugins_need_the_cnpg_backend` warns when it is set on the
  external path, where nothing renders a Cluster to carry it.

- `check.cnpg_backup_needs_barman_in_the_image` warns when a `cnpg_backup`
  carrying `barmanObjectStore` is paired with a `minimal` or `standard` image.
  That path archives WAL by running barman-cloud binaries inside the operand
  image, and upstream ships those only in the deprecated bare-tag `system`
  images, so on any qualified tag, the new default included, archiving fails
  on every attempt and reports it only in the Cluster's status conditions.
  The tag string is the one plan-time signal there is. A backup stanza
  carrying only volumeSnapshot settings runs no barman-cloud and draws no
  warning on any image.

- `check.cnpg_backup_and_a_wal_archiving_plugin_conflict` warns when
  `cnpg_backup` carries `barmanObjectStore` while a `cnpg_plugins` entry
  declares `isWALArchiver = true`: both claim the WAL archive command, and
  which one the operator ends up running is not a choice the caller gets to
  make.

- `check.an_ingress_in_front_means_at_least_one_proxy_hop` warns when
  `n8n_proxy_hops = 0` while an Ingress is being rendered. Zero is a valid
  answer only when nothing proxies to the pods; behind an Ingress the
  connecting address is always the controller's, so trusting no
  `X-Forwarded-For` entry makes every request look like it came from one host
  and quietly defeats IP allowlists and anything else keyed on the client
  address — invisibly, since n8n logs no per-request source IP.

  The check reads whether an Ingress is really rendered rather than
  `create_ingress` alone, because `n8n_extra_helm_values` is merged last and
  can add the Ingress the module did not create or remove the one it did. An
  explicit null there is a deletion, which leaves chart 1.10.0's own
  `ingress.enabled` of false, so a deleted key means no Ingress just as an
  explicit false does.

- `n8n_main_strategy` sets the main Deployment's rollout strategy, and
  **defaults to `Recreate`, which changes how the main Deployment rolls.** The
  worker and webhook-processor Deployments are untouched and keep rolling as
  they did; they are horizontally scaled and have no single-instance
  constraint to protect.

  The chart ships `strategy: {}` behind a `with`, so it rendered nothing and
  the Deployment took Kubernetes' own default: RollingUpdate at maxSurge 25%.
  Twenty-five percent of one replica rounds up to one, so on every single
  rollout the new main went Ready while the old one was still serving, and the
  old one then had its preStop sleep plus its graceful shutdown budget to exit.

  For that window, two n8n mains shared one Redis and one Postgres. Leader
  election among mains is the licensed multi-main feature this module
  deliberately does not carry, so both pods held the schedule triggers and both
  registered on the pub/sub command channel: cron workflows fired twice, and
  nothing recorded that a second main had ever existed. On a version bump the
  incoming main also ran its one-way startup migrations while the outgoing one
  was still querying the old schema.

  Everything else the module does to guarantee a single main
  (`replicaCount = 1`, `hpa.main.enabled = false`) held except during the
  rollout that changed it. `RollingUpdate` is also accepted and is rendered
  with `maxSurge = 0`, because RollingUpdate without that key is the surging
  default under a different name.

  The visible cost: the editor and the schedulers are down for the length of a
  main restart on every apply that changes the main pod, where previously they
  appeared not to be. They were not really up, they were doubled.

- `cnpg_pdb_enabled` controls the CloudNativePG Cluster's `spec.enablePDB`, and
  **defaults to off for a single-instance cluster**, which is this module's
  default.

  CloudNativePG creates its own PodDisruptionBudget over the Postgres primary
  unless told not to. At `cnpg_instances = 1` that object is `minAvailable: 1`
  over a single pod, so allowed disruptions is 0 and the node hosting Postgres
  can never be drained, exactly the failure `n8n_main_pdb_enabled` addresses
  one layer up. Disabling the chart's PDB and leaving this one still leaves a
  node that a Talos upgrade stalls on.

  Found by deploying to a real cluster, not by reading values: the object is
  created by the operator in response to the Cluster CR, so nothing in the
  module's rendered output mentions it.

  Needs CloudNativePG 1.23 or later, where `spec.enablePDB` was added. Older
  operators prune it as an unknown field and keep creating the budget, with
  nothing reporting that the setting went nowhere.

  The default follows the instance count rather than being a flat false,
  because the two cases differ. With replicas the budget does what a budget is
  for, stopping a second Postgres node from being drained while the first is
  still catching up, and CNPG still permits evicting replicas. With one
  instance there is no second copy to protect, so it can only withhold
  availability, never preserve it.

  `check.cnpg_pdb_blocks_the_postgres_node_drain` warns when the input is
  forced true at a single instance, matching
  `check.main_pdb_blocks_the_main_pod_node_drain` one layer up.

- `n8n_main_pdb_enabled` governs whether the chart renders its
  PodDisruptionBudget over the main pod, and **defaults to false, which
  overrides the chart's own default of true.**

  The chart's PDB is `minAvailable: 1` and covers the main Deployment only,
  which this module pins to `replicaCount = 1`. That combination is allowed
  disruptions of zero for the life of the deployment: `kubectl drain` on
  whichever node holds the main pod never completes, and a Talos node upgrade
  of that node stalls in drain rather than failing, so it reads as a hung
  upgrade rather than as a policy decision anyone made. Nothing in the module
  rendered this object; it arrived as a chart default and had never been
  overridden.

  A PDB exists to keep N replicas up while a node is taken away. With one
  replica there is no N to keep, so it cannot protect anything and can only
  refuse. The main restarting briefly during a drain is the accepted cost of
  single-main Community mode. A `check` block warns at plan time for anyone
  who sets it back to true.

- `n8n_network_policy_enabled` renders the chart's `NetworkPolicy` over the n8n
  pods. Off by default, matching the chart, and exposed rather than decided
  here because what it costs depends on what a caller's workflows call.

  The module previously offered no lever at all. n8n makes arbitrary outbound
  HTTP by design, so a workflow or an SSRF-prone node can reach whatever the
  pod network can, which on a Talos cluster includes the Talos API on port
  50000.

  `docs/operations.md` documents what the chart's policy is and is not: every
  egress rule targets all destinations and differs only by port, so it is a
  port allowlist (DNS, the database port, the Redis port, 443) rather than
  segmentation. Every port in that list stays open to every destination, which
  includes anything on 443 and any host answering on the configured database or
  Redis port. It is also not something to layer under a destination-scoped
  policy of your own: Kubernetes unions the policies selecting a pod and none
  of them can subtract, so a tighter rule cannot take back a port this one has
  opened. The docs list what turning it on breaks, chiefly workflows calling
  plaintext `http://` endpoints.

  A `check` block warns when the policy is rendered alongside an OTLP collector
  the policy would cut off, because n8n does not error on a failed span export:
  the traces simply stop. It compares the endpoint's effective port against the
  allowlist as configured rather than against 443 alone, so a collector on the
  database or Redis port, an explicit loopback sidecar address, and an
  `https://` URL with a bracketed IPv6 host all pass without a warning.

- `cnpg_backup` writes the CloudNativePG Cluster's `spec.backup`, turning on
  continuous WAL archiving to an object store. Null by default, which is what
  the Cluster has always been: a database whose only copy is its PVC.

  Passed through verbatim rather than typed, which is a deliberate exception to
  how every other input here works: the field's own shape has changed under
  CloudNativePG and a typed surface would have frozen one version of it.

  It reaches the in-tree path only. CloudNativePG deprecated
  `spec.backup.barmanObjectStore` in 1.26 in favour of the Barman Cloud Plugin,
  which is configured through the Cluster's `spec.plugins` and a separate
  `ObjectStore` resource, neither of which this module renders. The in-tree
  form still works on 1.26 and later, so nothing breaks, but a cluster that has
  moved to the plugin cannot be configured through this input.
  `docs/operations.md` carries a worked example, a `ScheduledBackup` (WAL
  archiving alone is not a backup) with a note about the `method` the plugin
  path needs, and a note that restore means standing up a second Cluster.

  `check.cnpg_backup_needs_the_cnpg_backend` warns when the input is set on the
  external backend, where it reaches nothing: the destination and credentials
  Secret are written, the configuration reads as done, and no archiving
  happens.

  `prevent_destroy` was considered and is not offered: Terraform requires a
  literal in a `lifecycle` block, so it cannot be made conditional, and
  hardcoding it would make `terraform destroy` impossible for every consumer.
  The `StorageClass` reclaim policy is the lever that works, and the docs now
  say so.

- `n8n_proxy_hops` sets `N8N_PROXY_HOPS` on every pod type, replacing a
  hardcoded literal that only existed on one routing path.

  The module wrote `N8N_PROXY_HOPS = 1` when it owned the Ingress and nothing
  at all when `create_ingress = false`. A caller running their own routing is
  behind a proxy just the same, so on that path n8n trusted no
  `X-Forwarded-For` entry and attributed every request to the ingress
  controller's own address, which quietly flattens every rate limit and
  IP-based restriction keyed on the client address to a single source. Both split-ingress examples
  had worked around it by setting the name through `n8n_extra_env`, which is
  the escape hatch doing a typed input's job.

  The name is now reserved against `n8n_extra_env` and
  `n8n_extra_env_from_secret`, because the module writes it: two entries of one
  name in a container's env list is the duplicate that fails every later helm
  upgrade's strategic merge patch, rollback included.

  **Migration:** if you set `N8N_PROXY_HOPS` through `n8n_extra_env`, that is
  now rejected at plan time. Move the value to `n8n_proxy_hops`. Both
  split-ingress examples are updated. Deployments with `create_ingress = false`
  that set nothing will start sending `N8N_PROXY_HOPS = 1`, which is almost
  certainly the correction they wanted; set it explicitly if your chain is
  longer or shorter.

### Changed

- **`cnpg_postgres_image_tag` now defaults to `18-minimal-trixie`**, replacing
  the bare `16`. Two moves in one, both deliberate. The spelling moves off the
  deprecated bare rolling tags, which upstream removes when the bullseye
  images reach end of life, onto the supported `MM-TYPE-OS` form; the rolling
  behaviour within the major is unchanged. And the major moves to
  PostgreSQL 18, the major current n8n supports.

  **Existing clusters on the old default must pin before taking this module
  version.** Set `cnpg_postgres_image_tag = "16"` (or whatever you run) first,
  then plan the major upgrade as its own change. Letting the new default reach
  a running cluster is not a spelling fix: a major bump is an offline in-place
  `pg_upgrade` under current CloudNativePG, and this one also crosses from
  bullseye to trixie, which the in-place path does not support, as well as
  from the `system` image type to `minimal`, which drops the barman-cloud
  binaries the in-tree `cnpg_backup` path needs. The blue/green route (a
  second Cluster, dump/restore or logical replication) is the safe one for
  that combination; either way, take a backup first.

- `n8n_worker_keda_min_replicas` now requires at least 1. **Breaking for a
  configuration that was already producing no workers.**

  It accepted 0, documented as safe because "KEDA scales a ScaledObject to zero
  natively". KEDA does, but this input never reaches KEDA on its own: it is
  also `queueMode.workerReplicaCount`, and chart 1.10.0 gates
  `templates/deployment-worker.yaml` and `templates/scaledobject-worker.yaml`
  on the same `gt (int workerReplicaCount) 0`.

  So 0 did not park the pool at zero. It rendered no worker Deployment, no
  ScaledObject and no HPA, leaving nothing that could scale a worker back up
  when jobs arrived. The editor worked, the webhook processors answered, the
  queue filled, and no execution ever ran. Attesting KEDA did not help, since
  the ScaledObject the reasoning rested on is gated on the same number.

  True scale-to-zero would need the Deployment to exist alongside a ScaledObject
  floor of 0, which one value cannot express, so it is documented as out of
  reach rather than implied.

- `n8n_image_tag` now defaults to `"2.36.2"` instead of `null`. **This changes
  the n8n version an existing deployment runs on the next apply.**

  Null meant the chart's own default applied, which is the floating `stable`
  tag. Combined with the chart's `IfNotPresent` pull policy, that made the
  running version a property of when each node last pulled the layer rather
  than of the configuration: a main pod rescheduled onto a node with no cached
  image could land on a newer n8n than the workers beside it, run the one-way
  migrations that version brings on startup, and leave the rest of the
  deployment querying a schema it was not built for. No plan showed it,
  because nothing in the configuration had changed.

  A pinned default puts the version back in the plan, on the same policy the
  four chart version pins already follow: bumping it is a module change with
  its own entry here.

  **Before upgrading**, check what your pods are actually running
  (`kubectl exec -n <ns> <pod> -c <container> -- n8n --version`). Check a
  worker as well as a main: under the floating default they had no reason to
  agree, and if they disagree, reconcile on the higher of the two first, since
  that is the version the database schema has already been migrated to.

  Then compare that version with 2.36.2. **Behind it**, this apply is an n8n
  upgrade and runs database migrations, so read `docs/upgrading-n8n.md` and
  take a backup first. **Ahead of it**, this apply is a downgrade, and n8n's
  migrations do not run backwards: set `n8n_image_tag` to the version you are
  on before applying, because rolling an n8n version back means restoring the
  database from a backup taken before the upgrade, not changing this tag.

  To keep the old floating behaviour, set `n8n_image_tag = null` explicitly,
  which remains supported.

### Fixed

- `n8n_encryption_key_secret_ref` now reaches the chart. Setting it always
  gated the module-owned `n8n-secrets` Secret to zero, exactly as documented,
  but `secretRefs.existingSecret` stayed hardcoded to `"n8n-secrets"` instead
  of following the caller's Secret name, so the chart was pointed at a Secret
  nothing created: unless the caller's Secret happened to be named
  `n8n-secrets` itself, every pod sat in `CreateContainerConfigError`, and the
  Secret the caller actually wrote was never read. The input had no test on
  either path; three runs now cover the wiring, the default, and the
  renamed-key rejection.

- Narrowed the `gavinbunney/kubectl` constraint from `>= 1.14` to `~> 1.14` in
  every root, the only unbounded provider constraint in the repo. It applies
  every custom resource the module applies itself (the CNPG `Cluster` and
  `Pooler`, and the `ClusterIssuer` in `modules/tls-letsencrypt`), so a future
  2.0 arriving on an unrelated apply is not a risk worth carrying. The worker
  `ScaledObject` is a custom resource too, but the chart renders it, so the
  Helm release owns that one and this constraint has no bearing on it. Lock
  files refreshed.

- `cnpg_postgres_image_tag` gains a validation, which accepts the qualified
  upstream tags (`16.10-minimal-trixie` and the like) as well as the bare
  `16` and `16.10`, and rejects an empty string, a leading `v`, a tag carrying
  a registry or digest, a dot that does not sit between two alphanumerics, and
  anything past the 128 characters the reference grammar allows a tag. Before
  this validation, each of those rendered an `imageName` that failed on the
  pod, as a pull error or, past the length limit, as a reference the runtime
  cannot parse at all; they are now plan errors instead. The dot rule is narrower than the reference grammar, which
  would accept those spellings and leave them to 404; the tags upstream
  publishes are a known set, so the typo is worth catching at plan. The description now says what the default
  rolling tag actually does: a newly created instance pulls whatever minor the
  tag points at, but a running cluster does not roll, because the tag string
  does not change and CloudNativePG has no new image reference to act on. To
  take a minor deliberately, bump the tag or drive it from an ImageCatalog. Nor
  is even a recreated instance guaranteed to move: a rolling tag resolves at
  pull time and the default pull policy for a non-latest tag is IfNotPresent,
  so an instance recreated on a node that already cached this tag keeps the
  minor that node cached. It also records that the bare spellings are
  deprecated upstream in favour of the ones naming the image type and
  distribution, and that CNPG's in-place major upgrade is supported only
  between images on the same operating system distribution.

- Corrected comments and descriptions that misdescribed the code: the values
  assembly banner claimed the chart 1.11.0 schema while the pin is 1.10.0;
  `postgres_cnpg.tf` cited `existing_eks_cluster_prerequisites_confirmed`, an
  input belonging to this module's AWS sibling that has never existed here; the
  `n8n_additional_domains` ceiling was justified by an ACM quota on a platform
  with no ACM; `metrics_lan_expose` was described as exposing `/metrics`
  when a Service selects a port, so it publishes the editor and REST API on
  5678 alongside it, in `docs/operations.md` as well as in the input's own
  description; and `k8s_keda_installed` said that attesting KEDA it does not
  have leaves the `ScaledObject` unreconciled, which holds only where the CRDs
  outlived the operator - with the CRDs gone the Helm release fails on an
  unknown kind. `kubernetes_secret.n8n` now says why three of its four
  keys are not secret, and why that does not make the object safe to read.
  The "Out of scope" list in the README classified the same failure on the
  wrong axis, and named three of the six prerequisites it lists.

- Removed `random_password.task_runner_token`, which was generated once when
  the resource was first created, persisted in state from then on, and
  referenced by nothing. Its comment described it
  as the shared secret between the task broker and the runner sidecars, which
  sent anyone debugging a runner authentication problem to a value that had
  never reached a pod. The chart mints that token itself and looks up the
  existing Secret first, so it survives an upgrade rather than rotating, and
  the broker and runner are containers in the same pod and cannot skew.

- Raised the namespace delete timeout from 2 minutes to 10. Deleting a
  namespace blocks until everything inside it finalizes, and this one holds a
  CloudNativePG Cluster tearing down plus PVCs whose provisioner has to detach
  and reclaim real volumes. On a five-node Talos cluster with Longhorn that
  took several minutes, so `terraform destroy` reported "context deadline
  exceeded" for a deletion that completed on its own shortly afterwards. The
  namespace stayed in state, leaving a destroy that looked broken against a
  cluster that was already clean, recoverable only by running it again and
  watching it succeed against a namespace that no longer existed.

- `helm_release.valkey` now sets `atomic` and `cleanup_on_fail`, which
  `helm_release.n8n` has carried since a timed-out install stranded it.

  `atomic` is the one that fixes the stranding. Without it a Valkey install
  that exceeds its timeout stays in the cluster while Terraform records no
  state for it, and every later apply fails with "cannot re-use a name that is
  still in use" until someone runs `helm uninstall` by hand. The failure at
  least carries Valkey's name throughout: `helm_release.n8n` sits behind an
  explicit `depends_on` on this release, so the stranding apply reports the
  Valkey timeout itself and every later one fails on the occupied release name
  before the n8n release is attempted. What the stranding costs is that no
  apply can proceed at all until the manual uninstall.

  `cleanup_on_fail` is upgrade-only ("allow deletion of new resources created
  in this upgrade when upgrade fails"); Helm's install action has no such
  option. It does nothing for the failure above and is set so that a failed
  upgrade does not leave behind objects belonging to a revision that was then
  rolled back.

  `atomic` also changes how a failed *upgrade* behaves: it is rolled back to
  the previous revision rather than left half-applied. That is a trade rather
  than a cure. A rollback that itself fails or times out is recorded by Helm
  as a failed revision: `helm history` shows the sequence and a manual
  `helm rollback` recovers it. The stuck `pending-rollback` state, whose later
  applies fail with "another operation (install/upgrade/rollback) is in
  progress", arises only when the process is killed mid-rollback, not from
  the timeout. `helm_release.n8n` has had that exposure since it
  got the pair, so this is the same failure on a second release rather than a
  new one.

- `n8n_webhook_hpa_enabled = false` now removes the webhook processor's
  autoscaler on the KEDA path as well. The input's documented purpose is to let
  a caller attach their own policy, and off the KEDA path it worked, because
  the value feeds the chart's `hpa.webhookProcessor.enabled` and the chart
  honours it. With KEDA attested the chart ignores that value (its template is
  gated on `not keda.enabled`) and the module's supplementary HPA was gated on
  the KEDA attestation alone, so turning the input off removed nothing. A
  caller who disabled it and attached a VPA or a custom-metrics HPA got theirs
  fighting the module's over the same Deployment, which is the dual ownership
  the KEDA branch is otherwise careful to avoid.

- `n8n_prestop_sleep` now sets the drain delay it describes. It was rendered as
  an `N8N_PRESTOP_SLEEP` environment variable on every container, which nothing
  reads: chart 1.10.0 references the name in no template, and n8n declares no
  such variable (its deployment reference lists `N8N_GRACEFUL_SHUTDOWN_TIMEOUT`
  and not this one). The drain delay is a pod lifecycle hook, so the real
  window stayed on the chart's hardcoded `sleep 10` regardless of the input.

  An operator who raised it to survive a slow endpoint removal got the value
  they asked for in `kubectl describe pod` and the old behaviour in the
  cluster. It is now the chart's `lifecycle.*.preStop.command` on all three pod
  families, and the dead environment variable is no longer rendered.

- `n8n_termination_grace_period` now sets the pod's own
  `terminationGracePeriodSeconds`, not only n8n's internal shutdown budget.

  It reached `N8N_GRACEFUL_SHUTDOWN_TIMEOUT`, through the chart's
  `redis.worker.timeout`, and stopped there. The pod-level grace period, which
  is what decides when the kubelet gives up and sends SIGKILL, stayed on the
  chart's 60 whatever the input said.

  The two clocks do not start together. Kubernetes begins the grace period when
  the pod is marked for deletion, runs the preStop hook, and sends SIGTERM only
  once that hook returns, so n8n's budget starts one drain sleep late. At the
  defaults that is a 10 second sleep inside a 60 second grace period against a
  60 second budget: n8n was killed at 50 of the 60 seconds it had been told it
  had, mid-execution.

  Raising the input bought nothing and said nothing. Asking for 300 seconds of
  drain still got a pod killed at 60, so the ceiling stayed at roughly 50
  seconds of usable shutdown no matter what the input said. Executions that
  finished inside that window were fine either way; the long-running ones the
  raised budget was meant to protect were exactly the ones it did not, and a
  worker scale-down or a node drain killed them with nothing reporting why.
  The pod period is now the drain sleep plus the budget, on main, worker and
  webhook processor alike, which is what makes the variable's description true.

- `n8n_image_pull_secrets` now actually reaches the pods. It was a no-op: the
  input created a ServiceAccount, attached the registry credentials to it, and
  then no pod ever ran as it.

  The design was right and half-built. `local.n8n_manages_service_account` and
  `local.n8n_service_account_name` worked out that the module should take the
  account over and under which name, `kubernetes_service_account_v1.n8n`
  created it, and a comment explained the two-name scheme that makes enabling
  it on a live deployment safe. The rendered chart values ignored all of it and
  passed `serviceAccount.create = true, name = "n8n"` unconditionally, so the
  chart's helper went on resolving its own account.

  The symptom was a private `n8n_image_repository` failing as ImagePullBackOff
  with the credentials sitting right there, inside an atomic release that waits
  for readiness and then rolls back with nothing in the output naming the
  ServiceAccount. Nothing asserted the `serviceAccount` values, which is how it
  survived the suite.

  With the default empty pull-secret list the rendered values are byte-for-byte
  what they were, so nothing changes for deployments that do not use the input.

- `helm_release.n8n` now depends on `kubernetes_service_account_v1.n8n`. The
  ordering was described in `locals.tf` as the reason the two-name scheme
  works, and nothing enforced it: the release consumes only the account's
  name, which is a local, so no implicit edge existed. On the apply that first
  enables `n8n_image_pull_secrets` the pods could be admitted against an
  account Terraform had not created yet.

- `check.custom_image_tag_needs_a_task_runner_tag` no longer warns on a
  private mirror of the stock image. It used "the caller set a tag" as its
  proxy for "this tag may not exist upstream", which stopped being one the
  moment `n8n_image_tag` carried a default: a caller who set only
  `n8n_image_repository` inherited the module's own published-version default
  and got told to set `n8n_task_runner_image_tag` anyway. It now tests the
  tag's shape, which is what actually decides whether the chart's runner
  fallback resolves.

## [0.2.1], The pooler and the wiring audit

A PgBouncer pooler for the CNPG backend, binary data onto a shared volume, and
a bug-fix sweep (#23-#32) for inputs that were documented, validated and then
silently discarded before they reached the chart. Patch rather than minor,
deliberately: this module tracks behind its AWS sibling's versioning, and the
headline here is wiring that now does what the docs always said it did.

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

- The `tls-letsencrypt` submodule validates its `name` input as a Kubernetes
  object name at plan time. An invalid name previously failed only mid-apply,
  and the derived `"<name>-account-key"` Secret name bypassed the shape check
  the explicit `private_key_secret_name` input already carried; the new
  validation covers both, capped so the derived name stays inside the
  253-character limit.

- A sweep of documentation and comments that contradicted the code. The most
  load-bearing: `n8n_templates_enabled` / `n8n_personalization_enabled`
  claimed that setting `true` emits no env var (both are rendered explicitly
  either way); README and ROADMAP said binary data "stays on filesystem mode"
  (the default is Postgres, `n8n_binary_data_mode`); `docs/operations.md`
  said WEBHOOK_URL travels via `config.extraEnv` (it is the chart's
  `webhook.url` except on a split ingress) and showed a capacity warning with
  a `main 3 ×` line the code cannot produce; two autoscaling descriptions
  cited AWS-sibling inputs (`node_max`, `node_instance_type`,
  `n8n_main_hpa_max_replicas`) and a README section that do not exist here;
  `docs/helm-chart-coverage.md` called `replicaCount` "exposed" (pinned, no
  input) and `taskRunners.launcher` "not exposed" (its `autoShutdownTimeout`
  is a headline 0.2.0 input); `docs/module-contract.md` counted four examples
  and 7 roots (six and 9); a comment pointed at a `refactoring.tf` that never
  existed in this repo; four comments still justified guard-style ternaries
  by a Terraform 1.9 floor (the floor is 1.11, which short-circuits - the
  style stays as a consistency rule); one comment claimed the chart has no
  `redis.tls` key (it does; the env route is kept deliberately); and the
  `n8n_domain` local's comment described lowercasing that happens elsewhere.
  The Unreleased section also carried two `### Changed` headings.

- The examples' commented AI-Assistant recipe in `homelab-cloudflare` and
  `homelab-godaddy` was two revisions stale and actively harmful: it told the
  reader to `concat()` onto an `n8n_extra_env` assignment that no longer
  exists, and to pass the secret-backed API key through
  `n8n_extra_helm_values` `config.extraEnv` - the exact overlay the module now
  rejects, because Helm replaces that list wholesale and the deployment's own
  environment silently disappears with it. Both now carry the current recipe
  (`n8n_extra_env_from_secret`), matching the other examples. Also in the
  examples: a bare `~/` kubeconfig path is rejected (it resolves to the home
  directory - the same directory-as-KUBECONFIG failure an empty path was
  already rejected for), the `kubeconfig_path` description names all three
  providers that read it, the Cloudflare record comment no longer attributes
  itself to `examples/homelab`, and four test runs that existed in some
  examples but had been dropped from their siblings (shared-storage
  binary-data wiring, DNS gating, namespace ownership) are restored so the six
  suites assert the same contracts again.

- Three classes of shell bug in `tests/scripts/smoke-test.sh`, each hiding the
  exact failure its check exists to report. Under `set -euo pipefail`, an
  unrouted webhook prefix made the ingress check's `grep` pipeline abort the
  whole script instead of printing the `fail` line, and a missing catch-all
  `/` rule did the same to its `warn`. The ScaledObject lookup read `$?` on
  the line after a plain assignment, which `set -e` never reaches, so the
  "kubectl failed" branch was unreachable. And four `curl ... || echo "000"`
  fallbacks doubled the `000` curl itself writes on a connection failure,
  producing `000000` and skipping the "connection failed" branch - the same
  bug the healthz check already documents and fixes for itself.

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
  now reports `n8n_binary_data_mode` directly, and an override from the two
  env inputs is impossible: both names are reserved again (see Changed above).
  Wrong since the initial release; see issue #18.

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
runner sidecar stayed on the chart's 15 seconds whatever you asked for. Fixing
it moved the value out of `config.extraEnv` and onto
`taskRunners.launcher.autoShutdownTimeout`, and both halves of that move change
the rendered chart values. So if `n8n_task_runners_enabled` is true, this
upgrade rolls your pods whatever you set the timeout to, including leaving it
at the default: `config.extraEnv` loses an entry every n8n container carries,
which is main, worker **and** webhook-processor. Only callers with task runners
disabled plan clean. If you had set the input, the sidecar's environment also
changes and the runners start honouring the value for the first time.

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

[Unreleased]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/compare/0.3.1...HEAD
[0.3.1]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.3.1
[0.3.0]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.3.0
[0.2.1]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.2.1
[0.2.0]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.2.0
[0.1.0]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.1.0
[0.0.1-beta.5]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.5
[0.0.1-beta.4]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.4
[0.0.1-beta.3]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.3
[0.0.1-beta.2]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.2
[0.0.1-beta.1]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.1
