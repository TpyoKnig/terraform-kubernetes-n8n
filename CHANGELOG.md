# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `check.an_ingress_in_front_means_at_least_one_proxy_hop` warns when
  `n8n_proxy_hops = 0` while an Ingress is being rendered. Zero is a valid
  answer only when nothing proxies to the pods; behind an Ingress the
  connecting address is always the controller's, so trusting no
  `X-Forwarded-For` entry makes every request look like it came from one host
  and quietly defeats IP allowlists, rate limits and audit logging.

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

- `n8n_proxy_hops` sets `N8N_PROXY_HOPS` on every pod type, replacing a
  hardcoded literal that only existed on one routing path.

  The module wrote `N8N_PROXY_HOPS = 1` when it owned the Ingress and nothing
  at all when `create_ingress = false`. A caller running their own routing is
  behind a proxy just the same, so on that path n8n trusted no
  `X-Forwarded-For` entry and attributed every request to the ingress
  controller's own address, which quietly flattens every rate limit, audit log
  line and IP-based restriction to a single source. Both split-ingress examples
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
  still in use" until someone runs `helm uninstall` by hand. It is the more
  awkward half to diagnose, because the n8n release then waits on a queue that
  never arrives and reports its own timeout rather than anything naming
  Valkey.

  `cleanup_on_fail` is upgrade-only ("allow deletion of new resources created
  in this upgrade when upgrade fails"); Helm's install action has no such
  option. It does nothing for the failure above and is set so that a failed
  upgrade does not leave behind objects belonging to a revision that was then
  rolled back.

  `atomic` also changes how a failed *upgrade* behaves: it is rolled back to
  the previous revision rather than left half-applied. That is a trade rather
  than a cure. A rollback that does not itself finish inside the timeout leaves
  the release in `pending-rollback`, and later applies fail with "another
  operation (install/upgrade/rollback) is in progress" until someone runs
  `helm rollback` by hand. `helm_release.n8n` has had that exposure since it
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

[Unreleased]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/compare/0.2.1...HEAD
[0.2.1]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.2.1
[0.2.0]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.2.0
[0.1.0]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.1.0
[0.0.1-beta.5]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.5
[0.0.1-beta.4]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.4
[0.0.1-beta.3]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.3
[0.0.1-beta.2]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.2
[0.0.1-beta.1]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.1
