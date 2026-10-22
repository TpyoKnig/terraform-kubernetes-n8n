# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Locals ────────────────────────────────────────────────────────────────────
# Shared values derived from inputs: input aliases, the labels every resource
# merges in, and the Helm values tree the n8n release renders from.

locals {
  # Lowercased once here. n8n_domain's own FQDN validation accepts uppercase
  # (DNS is case-insensitive), but Kubernetes Secret and Ingress host names
  # are not, and this value feeds N8N_HOST, every webhook/editor URL this
  # module builds, and the TLS Secret name derived from
  # k8s_ingress_host_effective below. Normalizing the one value every one of
  # those reads from means a mixed-case n8n_domain cannot make N8N_HOST,
  # the advertised URLs and the routed Ingress host disagree with each
  # other, which is what happened before: only k8s_ingress_hosts lowercased
  # its own copy, so N8N_HOST, the editor/webhook URL fallbacks and the TLS
  # Secret name all kept whatever case the caller typed.
  n8n_domain = lower(var.n8n_domain)

  # Service coordinates the Helm chart creates. Named here so the outputs a
  # bring-your-own Ingress consumes cannot drift from what the chart renders.
  n8n_service_name         = "n8n-main"
  n8n_webhook_service_name = "n8n-webhook-processor"
  n8n_service_port         = 5678

  # Path prefixes that must reach the webhook processors rather than the main
  # pods. The main pods run with production webhooks disabled, so every one of
  # these 404s if it reaches them. All five are routed by the chart's own
  # webhook Ingress (templates/ingress-webhook.yaml) as of chart 1.16.0, which
  # added /mcp/ to the four it already covered; see k8s_webhook_ingress_block
  # below for the history. There used to be a derived
  # "unrouted" subtraction and a supplementary kubernetes_ingress_v1.n8n_mcp
  # resource in n8n.tf to cover /mcp while the chart did not; both were
  # removed when /mcp landed, rather than left dormant, because an
  # unconditionally empty dynamic "path" block fails the Kubernetes provider's
  # schema validation (Ingress requires at least one path per rule) even at
  # count = 0. If the chart ever drops a prefix again, re-add the subtraction
  # and the Ingress rather than resurrecting the dead code from source
  # control.
  n8n_webhook_path_prefixes = [
    "/webhook",
    "/webhook-waiting",
    "/form",
    "/form-waiting",
    "/mcp",
  ]

  # -- Redis connection coordinates --------------------------------------------
  # What n8n and KEDA connect to. The in-cluster Valkey path resolves through
  # local.k8s_redis_host further down; these describe the "external" path, where
  # the caller supplies the endpoint and the module provisions nothing.

  # A declaration from the caller, not something the module verifies: it does
  # not manage the endpoint, so it cannot confirm the endpoint speaks TLS.
  redis_tls_active = var.redis_transit_encryption_enabled

  # Whether there is an AUTH token to wire up at all. A plain presence check:
  # the module cannot generate a credential for infrastructure it does not
  # provision.
  redis_auth_active = var.redis_auth_token != null || var.redis_auth_token_secret_ref != null

  # The credential value that actually reaches the Kubernetes Secret this module
  # writes. null when redis_auth_token_secret_ref is set: the value then lives in
  # the caller's own Secret, which the module never reads, and
  # kubernetes_secret.n8n_redis is not created on that path (n8n.tf).
  redis_auth_token_value = var.redis_auth_token

  redis_username_value = var.redis_username

  # Chart fragment carrying QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD, merged into the
  # redis values rather than set inline. Empty when the input is null, which is
  # the default, so the chart's own 10000 continues to apply.
  redis_timeout_values = (
    var.n8n_redis_timeout_threshold == null
    ? {}
    : { timeout = var.n8n_redis_timeout_threshold }
  )

  # Bull's own default prefix, mirrored here (rather than left as a literal at
  # each KEDA listName call site) so n8n.tf's env var, the chart's redis.prefix
  # value, and KEDA's listName all read from one resolved value.
  redis_key_prefix_value = coalesce(var.redis_key_prefix, "bull")


  # ── n8n service account ────────────────────────────────────────────────────
  # The chart creating its own ServiceAccount is the arrangement we want, with
  # one exception: neither chart 1.10.0 nor 1.11.0 renders imagePullSecrets
  # anywhere, not on the pod spec and not on the ServiceAccount, so a private
  # registry has no way in through chart values. Attaching the secrets to the
  # account the pods already run as is the remaining lever, and the chart
  # supports it: serviceAccount.create = false with an externally managed name
  # is documented in its own values.yaml, naming Terraform as the example.
  #
  # So the module takes the account over, but only when there is something to
  # attach. With the default empty list the chart keeps creating it and nothing
  # about an existing deployment moves.
  n8n_manages_service_account = length(var.n8n_image_pull_secrets) > 0

  # The two owners deliberately use different names, which is not tidiness.
  # helm_release.n8n depends on the ServiceAccount resource, so on the apply
  # that first sets n8n_image_pull_secrets the module creates its account
  # before the upgrade runs. Sharing one name there means creating an object
  # the chart still owns, and the apply stops at "serviceaccounts
  # \"n8n\" already exists" with the release untouched. Reversing
  # the dependency does not help either: with create = false the chart drops
  # its account during the upgrade, and the new pods would fail admission
  # looking for a ServiceAccount that Terraform has not created yet.
  #
  # Two names sidestep both. The new account is created alongside the old one,
  # the upgrade points the pods at it and lets Helm delete the chart's, and the
  # same apply works whether or not the deployment already exists.
  #
  # Whichever name is in play has two consumers that must agree: the chart's
  # serviceAccount.name and the ServiceAccount resource in n8n.tf.
  n8n_service_account_name = local.n8n_manages_service_account ? "n8n-pull" : "n8n"

  # ── Extra volumes, translated for the chart ────────────────────────────────
  # The inputs are snake_case and typed; the chart wants Kubernetes' camelCase.
  # Doing the translation here rather than asking callers to write chart YAML
  # through a Terraform variable is what makes the inputs checkable at plan
  # time, and keeping it in a local rather than inline in the values map is
  # what makes it assertable: helm_release.n8n.values is unknown at plan time,
  # since it carries the database endpoint and the generated Secret names.
  #
  # default_mode arrives as an octal string and is converted with parseint,
  # because Kubernetes wants the integer. A Terraform number literal cannot do
  # this job: 0644 parses as decimal 644, which is octal 1204.
  n8n_extra_volumes = concat(
    [
      for volume in var.n8n_extra_volumes : merge(
        { name = volume.name },
        volume.config_map == null ? {} : {
          configMap = merge(
            { name = volume.config_map.name },
            volume.config_map.default_mode == null ? {} : {
              defaultMode = parseint(volume.config_map.default_mode, 8)
            },
          )
        },
        volume.secret == null ? {} : {
          secret = merge(
            { secretName = volume.secret.secret_name },
            volume.secret.default_mode == null ? {} : {
              defaultMode = parseint(volume.secret.default_mode, 8)
            },
          )
        },
        volume.persistent_volume_claim == null ? {} : {
          persistentVolumeClaim = merge(
            { claimName = volume.persistent_volume_claim.claim_name },
            volume.persistent_volume_claim.read_only == null ? {} : {
              readOnly = volume.persistent_volume_claim.read_only
            },
          )
        },
      )
    ],
    # n8n_extra_ca_pem's own volume, appended here rather than left for the
    # caller to declare: see the "Extra CA bundle" locals below.
    local.n8n_extra_ca_enabled ? [local.n8n_ca_bundle_volume] : [],
    # var.n8n_credentials_overwrite_secret_ref's own volume, kept out of the
    # typed n8n_extra_volumes input so its name and mount path can be reserved
    # (see that variable's validations) rather than left to collide silently.
    var.n8n_credentials_overwrite_secret_ref == null ? [] : [
      {
        name = "credentials-overwrite"
        secret = {
          secretName = var.n8n_credentials_overwrite_secret_ref.name
          items = [
            {
              key  = var.n8n_credentials_overwrite_secret_ref.key
              path = var.n8n_credentials_overwrite_secret_ref.key
            },
          ]
        }
      },
    ],
  )

  n8n_extra_volume_mounts = concat(
    [
      for mount in var.n8n_extra_volume_mounts : merge(
        {
          name      = mount.name
          mountPath = mount.mount_path
          readOnly  = mount.read_only
        },
        mount.sub_path == null ? {} : { subPath = mount.sub_path },
      )
    ],
    local.n8n_extra_ca_enabled ? [local.n8n_ca_bundle_mount] : [],
    var.n8n_credentials_overwrite_secret_ref == null ? [] : [
      {
        name      = "credentials-overwrite"
        mountPath = "/etc/n8n/credentials-overwrite"
        readOnly  = true
      },
    ],
  )

  # ── Extra CA bundle (n8n_extra_ca_pem) ──────────────────────────────────────
  # Node reads one NODE_EXTRA_CA_CERTS file. The PEM lives in a module-managed
  # Secret (public certificates only; the variable rejects private keys),
  # created in n8n.tf and mounted read-only at one fixed path on main, worker
  # and webhook-processor pods via the volume/mount appended above. The task
  # runner sidecar is a separate container that neither of those two lists
  # reaches, so it does not inherit the trust.
  n8n_extra_ca_enabled = var.n8n_extra_ca_pem != null
  n8n_ca_bundle_pem    = local.n8n_extra_ca_enabled ? "${trimspace(var.n8n_extra_ca_pem)}\n" : null

  n8n_ca_bundle_volume = local.n8n_extra_ca_enabled ? {
    name = "ca-bundle"
    secret = {
      secretName = "n8n-ca-bundle-secret"
      items      = [{ key = "ca.crt", path = "ca.crt" }]
    }
  } : null

  n8n_ca_bundle_mount = local.n8n_extra_ca_enabled ? {
    name      = "ca-bundle"
    mountPath = "/etc/n8n-certs/ca-bundle.crt"
    subPath   = "ca.crt"
    readOnly  = true
  } : null

  n8n_ca_bundle_env = local.n8n_extra_ca_enabled ? [
    { name = "NODE_EXTRA_CA_CERTS", value = "/etc/n8n-certs/ca-bundle.crt" },
  ] : []

  # The config.extraEnv entry for CREDENTIALS_OVERWRITE_DATA_FILE, extracted
  # like the volume/mount pair above so tests/defaults.tftest.hcl can assert
  # the rendered entry directly.
  n8n_credentials_overwrite_env = var.n8n_credentials_overwrite_secret_ref == null ? [] : [
    {
      name  = "CREDENTIALS_OVERWRITE_DATA_FILE"
      value = "/etc/n8n/credentials-overwrite/${var.n8n_credentials_overwrite_secret_ref.key}"
    },
  ]

  # ── n8n_extra_env collision guard ──────────────────────────────────────────
  # config.extraEnv is appended LAST in every n8n container's env list (see the
  # n8n Helm chart's deployment-*.yaml templates), and Kubernetes resolves
  # duplicate env names last-wins. So any name a caller passes via
  # var.n8n_extra_env overrides the value the module or chart set for it. These
  # two lists are the reserved surface the escape hatch must not touch:
  # connection, identity, storage, and topology vars whose override
  # would silently break or hijack the deployment.
  #
  # Exact names: set by the module in config.extraEnv / the n8n secret, plus the
  # chart-rendered identity/topology/storage vars not covered by a prefix below.
  # Keep in sync with the extraEnv block in n8n.tf and the chart values the
  # module sets (database/redis/s3/secretRefs).
  n8n_managed_env_names = concat([
    # Set by the module in config.extraEnv or the n8n secret.
    "N8N_ENCRYPTION_KEY",
    "N8N_LOG_LEVEL",
    "N8N_LOG_OUTPUT",
    # All three are set together by n8n_metrics_enabled, so all three are
    # reserved. Listing only N8N_METRICS left the other two appendable: a
    # caller could put N8N_METRICS_INCLUDE_QUEUE_METRICS in n8n_extra_env and
    # the module rendered the name twice in one container's env list, which is
    # the silent last-wins override this list exists to prevent. There is no
    # N8N_METRICS_ prefix entry because the remaining N8N_METRICS_INCLUDE_*
    # groups are genuinely the caller's to set.
    "N8N_METRICS",
    "N8N_METRICS_INCLUDE_QUEUE_METRICS",
    "N8N_METRICS_INCLUDE_CACHE_METRICS",
    "N8N_REINSTALL_MISSING_PACKAGES",
    "N8N_COMMUNITY_PACKAGES_PREVENT_LOADING",
    "N8N_COMMUNITY_PACKAGES_REGISTRY",
    "N8N_CUSTOM_EXTENSIONS",
    # Owned by redis_key_prefix, which is the single source of truth for the
    # Redis namespace: it sets this, the chart's redis.prefix (QUEUE_BULL_PREFIX)
    # and the KEDA ScaledObject's listName together. QUEUE_BULL_PREFIX is
    # already covered by the QUEUE_ prefix below; without this entry the two
    # halves could be set independently, leaving n8n's pub/sub channel and
    # Bull's job keys under different namespaces, and KEDA watching a list
    # nothing writes to.
    "N8N_REDIS_KEY_PREFIX",
    # Owned by the four "n8n defaults scheduled to change" inputs. Listed even
    # though three of them are only emitted when set: an extraEnv override would
    # move a limit the module deliberately leaves to n8n, or unpin the task
    # timeout the module deliberately pins, without the input saying so.
    # N8N_RUNNERS_TASK_TIMEOUT is already covered by the N8N_RUNNERS_ prefix
    # below and is not repeated here.
    "N8N_UNVERIFIED_PACKAGES_ENABLED",
    "N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES",
    "N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES",
    # Chart-rendered env var name moved from WEBHOOK_URL to N8N_WEBHOOK_URL at
    # chart 1.16.0 (n8n deprecated WEBHOOK_URL as of n8n 2.35.0, an alias of
    # N8N_WEBHOOK_URL since 2.30.0); n8n_image_tag's pinned default (2.44.5) is
    # past that deprecation either way. Reserved under the new name, since
    # that is what both the chart's single-host path and this module's own
    # split-ingress injection below now render.
    "N8N_WEBHOOK_URL",
    # Owned by n8n_proxy_hops, which renders it on every path. Unreserved, the
    # module wrote it whenever create_ingress was true while n8n_extra_env
    # would still accept a second entry of the same name, and two entries in
    # one env list is the duplicate that wedges the next helm upgrade.
    "N8N_PROXY_HOPS",
    # Owned by n8n_payload_size_max, which renders it on every path when set
    # and derives the Ingress proxy-body-size annotation from the same value.
    "N8N_PAYLOAD_SIZE_MAX",
    "N8N_TEMPLATES_ENABLED",
    "N8N_PERSONALIZATION_ENABLED",
    "N8N_OTEL_ENABLED",
    "N8N_OTEL_EXPORTER_OTLP_ENDPOINT",
    "N8N_OTEL_EXPORTER_OTLP_HEADERS",
    "N8N_OTEL_EXPORTER_SERVICE_NAME",
    "N8N_OTEL_TRACES_SAMPLE_RATE",
    "N8N_OTEL_TRACES_INCLUDE_NODE_SPANS",
    "N8N_OTEL_TRACES_INJECT_OUTBOUND",
    "N8N_OTEL_TRACES_PRODUCTION_ONLY",
    # Owned by var.n8n_execution_data_storage_mode, which only accepts "database"
    # and so emits nothing. Listed anyway: an extraEnv override would flip
    # execution data onto object storage the module has not configured, without
    # the input saying so, and every pod then refuses to start.
    "N8N_EXECUTION_DATA_STORAGE_MODE",
    # Rendered by the chart from module values (identity, topology, storage).
    # DB_*, QUEUE_* and N8N_RUNNERS_* are covered by n8n_managed_env_prefixes.
    "EXECUTIONS_MODE",
    "OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS",
    # Owned by the four n8n_executions_data_save_* inputs, which the chart
    # renders unconditionally from executions.data.*. No EXECUTIONS_DATA_SAVE_
    # prefix exists in n8n_managed_env_prefixes (unlike DB_/QUEUE_/
    # N8N_RUNNERS_), so these four exact names are reserved individually
    # instead; an extraEnv override would duplicate whichever of them the
    # module already renders, and Kubernetes keeps only the last entry of a
    # duplicated env name.
    "EXECUTIONS_DATA_SAVE_ON_SUCCESS",
    "EXECUTIONS_DATA_SAVE_ON_ERROR",
    "EXECUTIONS_DATA_SAVE_ON_PROGRESS",
    "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS",
    # Owned by the three n8n_pruning_*_interval/_buffer inputs, which the
    # chart renders only while the corresponding values key is set (see
    # k8s_values_executions.pruning below). Reserved unconditionally, same
    # reasoning as the four EXECUTIONS_DATA_SAVE_* names above: an extraEnv
    # override would duplicate whichever of them the module renders, and
    # Kubernetes keeps only the last entry of a duplicated env name.
    "EXECUTIONS_DATA_HARD_DELETE_BUFFER",
    "EXECUTIONS_DATA_PRUNE_HARD_DELETE_INTERVAL",
    "EXECUTIONS_DATA_PRUNE_SOFT_DELETE_INTERVAL",
    # Reserved because the module sets them from n8n_binary_data_mode and
    # n8n_binary_data_path, not because the chart renders them: chart 1.10.0
    # emits them only from the "n8n.s3Env" helper (_environment-helpers.tpl:7),
    # gated on .Values.s3.enabled, which k8s_values_s3_off pins false with no
    # input to turn it on.
    #
    # They were unreserved for a stretch, because before those inputs existed
    # n8n_extra_env was the only way to reach the setting a caller needs. That
    # left the mode reachable by two doors and only one of them checked:
    # filesystem mode set here skipped the shared-mount validation, skipped
    # N8N_STORAGE_PATH entirely, and still let the module report "filesystem",
    # which is per-pod local disk in a queue-mode deployment and loses payloads
    # without an error anywhere. One door now, and it is the checked one. See
    # docs/operations.md → "Shared storage across the pods".
    "N8N_DEFAULT_BINARY_DATA_MODE",
    "N8N_STORAGE_PATH",
    "N8N_HOST",
    "N8N_PORT",
    "N8N_PROTOCOL",
    # Chart-rendered on a single host, module-rendered on a split ingress --
    # reserved either way, because the two halves have to agree. See
    # k8s_split_ingress_urls.
    "N8N_EDITOR_BASE_URL",
    "N8N_DISABLE_PRODUCTION_MAIN_PROCESS",
    "N8N_NATIVE_PYTHON_RUNNER",
    "TZ",
    # Owned by n8n_timezone alongside TZ: the chart renders TZ from
    # config.timezone, and the module emits this one in extraEnv because
    # Schedule Triggers read it and no chart template renders it. One input,
    # two names, both reserved so they cannot disagree.
    "GENERIC_TIMEZONE",
    "N8N_DISABLED_MODULES",
    # Owned by n8n_smtp, which renders the family when set. The exact names
    # rather than an N8N_SMTP_ prefix, so the OAuth pair the input does not
    # model (N8N_SMTP_OAUTH_*) stays reachable through n8n_extra_env.
    "N8N_EMAIL_MODE",
    "N8N_SMTP_HOST",
    "N8N_SMTP_PORT",
    "N8N_SMTP_SSL",
    "N8N_SMTP_STARTTLS",
    "N8N_SMTP_SENDER",
    "N8N_SMTP_USER",
    "N8N_SMTP_PASS",
    # Owned by n8n_diagnostics_enabled, emitted only when set. Reserved
    # anyway: an extraEnv override would flip telemetry without the input
    # saying so.
    "N8N_DIAGNOSTICS_ENABLED",
    ],
    # NODE_OPTIONS is reserved ONLY while n8n_node_max_old_space_size_mb is
    # set, unlike every entry above. It is a whole flag STRING rather than a
    # single setting: when the module emits it, a caller entry would replace
    # the module's --max-old-space-size wholesale rather than merge with it,
    # which is the collision this guard exists to prevent while that override
    # is in force. With the input null the module emits nothing, there is no
    # value to clobber, and a caller passing NODE_OPTIONS for unrelated flags
    # is doing something legitimate this module has no business rejecting.
    var.n8n_node_max_old_space_size_mb != null ? ["NODE_OPTIONS"] : [],
  )

  # Whole env-var families the module/chart owns, matched by prefix so the guard
  # stays correct when the chart adds new members. This intentionally fails
  # closed: it also blocks DB_*/QUEUE_* *tuning* vars the module does not set
  # today (e.g. DB_LOGGING_ENABLED). If a caller has a genuine need for one, add
  # an exact-match carve-out rather than narrowing the prefix.
  # N8N_EXTERNAL_STORAGE_S3_* and AWS_* are deliberately absent: the module
  # provisions no object storage and sets neither, so a caller pointing n8n at
  # their own bucket needs both families. Blocking a prefix nothing here writes
  # would reject a legitimate configuration to protect a value that does not
  # exist.
  # N8N_ENDPOINT_ is here because the module hardcodes the path segments n8n
  # serves and then publishes them. n8n_webhook_path_prefixes lists /webhook,
  # /webhook-waiting, /form, /form-waiting and /mcp, the examples route exactly
  # those five on the webhook Ingress, and n8n_oauth_callback_url spells /rest
  # into the redirect URI. Every one of those segments is an N8N_ENDPOINT_
  # variable: REST, WEBHOOK, WEBHOOK_WAIT, FORM, FORM_WAIT, MCP.
  #
  # Change one through n8n_extra_env and nothing here follows. The Ingress goes
  # on routing the old segment, the outputs go on advertising it, and n8n
  # answers on the new one - so webhooks 404 at the ingress and the OAuth
  # redirect URI names a path that no longer exists, with the module reporting
  # both as correct. Reserved rather than plumbed through: routing them is a
  # feature with a real design behind it, and this guard says so at plan time
  # instead of letting the deployment say it in production.
  n8n_managed_env_prefixes = [
    "DB_",
    "QUEUE_",
    "N8N_RUNNERS_",
    "N8N_ENDPOINT_",
  ]

  # Official n8n names the prefixes above catch by accident, carved back out:
  # checked before the prefix rule, so these exact names pass both extra-env
  # inputs while everything else under DB_ and QUEUE_ stays blocked. Every
  # name below was read directly out of n8n 2.44.5's own config source
  # (@n8n/config database.config.ts and scaling-mode.config.ts) rather than
  # assumed, and cross-checked against this module's own typed inputs so the
  # carve-out opens a door only where none already exists.
  #
  # The client certificate/key are the reason the list exists. A corporate
  # Postgres that requires mutual TLS needs them handed to n8n, and n8n's
  # PostgresSSLConfig reads DB_POSTGRESDB_SSL_CERT / _SSL_KEY directly with no
  # typed input in this module for either; the DB_ prefix made them
  # unreachable. DB_POSTGRESDB_SSL_CA is deliberately NOT carved out here: it
  # already has a proper typed door, db_postgresdb_ssl_ca_pem, rendered
  # through the chart's own database.ssl.ca value, and carving the raw env
  # name out too would let a caller set the same destination two ways.
  # n8n has no separate "_FILE" variant of any of the three; the single env
  # var accepts either a path or inline content, so those names are not real
  # and are not carved out.
  #
  # Names NOT carved out stay blocked for a reason. Connection coordinates
  # (DB_POSTGRESDB_HOST, QUEUE_BULL_REDIS_HOST and family) are module-written.
  # DB_POSTGRESDB_CONNECTION_TIMEOUT, DB_PING_TIMEOUT_MS and
  # DB_PING_INTERVAL_SECONDS already have typed inputs
  # (db_postgresdb_connection_timeout_ms, db_ping_timeout_ms,
  # db_ping_interval_seconds), so carving them out too would open the same
  # second door. QUEUE_BULL_REDIS_CLUSTER_NODES, _DB and _DUALSTACK have
  # chart values (redis.clusterNodes, redis.database, redis.dualstack)
  # reachable through n8n_extra_helm_values, and the env route would fight
  # the chart-rendered host/port pair. QUEUE_WORKER_LOCK_* and friends
  # likewise live under the chart's redis.worker block and this module's own
  # n8n_queue_worker_lock_duration / _lock_renew_time / _stalled_interval
  # inputs. One door per setting, and the checked one.
  n8n_env_carveouts = [
    # External Postgres mutual TLS. n8n's PostgresSSLConfig reads these
    # directly; the module has no typed input for either.
    "DB_POSTGRESDB_SSL_CERT",
    "DB_POSTGRESDB_SSL_KEY",
    # Postgres client tuning. Matters alongside the PgBouncer pooler, whose
    # connection recycling interacts with lifetime and idle timeouts.
    "DB_POSTGRESDB_IDLE_CONNECTION_TIMEOUT",
    "DB_POSTGRESDB_STATEMENT_TIMEOUT",
    "DB_POSTGRESDB_MAX_CONNECTION_LIFETIME_MS",
    "DB_POSTGRESDB_KEEP_ALIVE",
    "DB_POSTGRESDB_KEEP_ALIVE_INITIAL_DELAY_MS",
    "DB_POSTGRESDB_DESTROY_TIMEOUT_MS",
    "DB_CONNECTION_ACQUISITION_TIMEOUT_MS",
    # Connection health-check recovery tuning. DB_PING_INTERVAL_SECONDS and
    # DB_PING_TIMEOUT_MS are deliberately absent here: both already have
    # typed inputs.
    "DB_PING_MAX_FAILURES_BEFORE_RECOVERY",
    "DB_RECOVERY_BACKOFF_MIN_MS",
    "DB_RECOVERY_BACKOFF_MAX_MS",
    "DB_STARTUP_CONNECT_MAX_RETRIES",
    # Query logging and the table prefix for a shared database.
    "DB_LOGGING_ENABLED",
    "DB_LOGGING_OPTIONS",
    "DB_LOGGING_MAX_EXECUTION_TIME",
    "DB_TABLE_PREFIX",
    # Redis client TLS and keep-alive names the chart has no values for.
    "QUEUE_BULL_REDIS_TLS_SERVERNAME",
    "QUEUE_BULL_REDIS_TLS_VALIDATE_CERTIFICATE",
    "QUEUE_BULL_REDIS_DNS_LOOKUP_STRATEGY",
    "QUEUE_BULL_REDIS_KEEP_ALIVE",
    "QUEUE_BULL_REDIS_KEEP_ALIVE_DELAY",
    "QUEUE_BULL_REDIS_KEEP_ALIVE_INTERVAL",
    "QUEUE_BULL_REDIS_RECONNECT_ON_FAILOVER",
    "QUEUE_BULL_REDIS_SLOT_REFRESH_INTERVAL",
    "QUEUE_BULL_REDIS_SLOT_REFRESH_TIMEOUT",
  ]

  # Modules explicitly disabled via N8N_DISABLED_MODULES. A list rather than a
  # direct string assignment so a later toggle for another module can append
  # to it without touching the join() that renders it. See
  # var.n8n_external_secrets_enabled.
  n8n_disabled_modules = concat(
    var.n8n_external_secrets_enabled ? [] : ["external-secrets"],
  )

  # ── Backing-service selection ──────────────────────────────────────────────
  # Each flag gates one in-cluster resource, so a caller can put Postgres
  # in-cluster while pointing Redis at something they already run.
  cnpg_enabled   = var.postgres_backend == "cnpg"
  valkey_enabled = var.redis_backend == "valkey"

  # ── CNPG-derived names ─────────────────────────────────────────────────────
  # Mirrors the naming the platforms/kubernetes/ code used before the fold-in,
  # so a deployment migrated from that layout keeps the same CNPG Cluster CR
  # name and the same app-secret name (CNPG creates "<cluster>-app").
  cnpg_release_name    = "n8n"
  cnpg_cluster_name    = "${local.cnpg_release_name}-pg"
  cnpg_service_host    = "${local.cnpg_cluster_name}-rw.${local.namespace_name}.svc.cluster.local"
  cnpg_app_secret_name = "${local.cnpg_cluster_name}-app"

  # ── PgBouncer pooler ───────────────────────────────────────────────────────
  # A Pooler is scoped to one Cluster and serves one deployment, so it sits on
  # the module side of the ownership line for the same reason the Cluster and
  # the worker ScaledObject do: the caller owns the CNPG operator, the module
  # owns the resources that operator reconciles for this workload.
  #
  # rw only. n8n writes on every execution, so there is no read-only traffic to
  # split onto a second pooler.
  cnpg_pooler_enabled = local.cnpg_enabled && var.cnpg_pooler_enabled
  cnpg_pooler_name    = "${local.cnpg_cluster_name}-pooler-rw"
  cnpg_pooler_host    = "${local.cnpg_pooler_name}.${local.namespace_name}.svc.cluster.local"

  # ── Valkey-derived names ───────────────────────────────────────────────────
  # Valkey chart names its Service "<release>-valkey".
  valkey_release     = "${local.cnpg_release_name}-redis"
  valkey_service     = "${local.valkey_release}-valkey"
  valkey_host        = "${local.valkey_service}.${local.namespace_name}.svc.cluster.local"
  valkey_secret_name = "${local.valkey_release}-auth"

  # ── Connection wiring for the k8s-backend helm release ─────────────────────
  # Resolved once here so postgres_cnpg.tf, redis_valkey.tf and the
  # helm_release.n8n below all read from a single source of truth.
  # With a pooler in front, n8n connects to PgBouncer rather than to Postgres.
  # This is the single place that changes, which is the point of resolving the
  # host once: nothing downstream needs to know a pooler exists.
  k8s_pg_host                = local.cnpg_pooler_enabled ? local.cnpg_pooler_host : (local.cnpg_enabled ? local.cnpg_service_host : (var.db_host == null ? "" : var.db_host))
  k8s_pg_secret_name         = local.cnpg_enabled ? local.cnpg_app_secret_name : (var.db_password_secret_ref == null ? "n8n-db-secret" : var.db_password_secret_ref.name)
  k8s_pg_secret_password_key = local.cnpg_enabled ? "password" : local.db_password_secret_ref_key != null ? local.db_password_secret_ref_key : "password"

  k8s_redis_host                = local.valkey_enabled ? local.valkey_host : (var.redis_host == null ? "" : var.redis_host)
  k8s_redis_port                = local.valkey_enabled ? 6379 : var.redis_port
  k8s_redis_secret_name         = local.valkey_enabled ? local.valkey_secret_name : (var.redis_auth_token_secret_ref == null ? "n8n-redis-secret" : var.redis_auth_token_secret_ref.name)
  k8s_redis_secret_password_key = local.valkey_enabled ? "redis-password" : (local.redis_auth_token_secret_ref_key != null ? local.redis_auth_token_secret_ref_key : "password")

  # ── k8s-backend Helm values assembly (chart 1.10.0 schema) ─────────────────
  # Ported from the fold-in of platforms/kubernetes/locals.tf. Every fragment
  # below is merged into local.k8s_values_final and only referenced from
  # helm_release.n8n (n8n.tf), so these
  # locals are evaluated to a value that never reaches a resource.


  # repository and tag are both omitted when unset so the chart's own values
  # apply: docker.n8n.io/n8nio/n8n at the chart's own appVersion (before
  # chart 1.12.0, the floating `stable` tag instead). Setting repository is
  # the supported path for an image with community nodes baked in; the check
  # block in n8n.tf refuses it without an explicit tag, because a custom
  # repository almost never publishes a tag matching the pinned chart's
  # appVersion.
  k8s_values_image = {
    image = merge(
      { pullPolicy = "IfNotPresent" },
      var.n8n_image_repository != null && var.n8n_image_repository != "" ? { repository = var.n8n_image_repository } : {},
      var.n8n_image_tag != null && var.n8n_image_tag != "" ? { tag = var.n8n_image_tag } : {},
    )
  }

  # secretRefs.existingSecret names the one Secret the chart's coreSecretsEnv
  # helper reads N8N_ENCRYPTION_KEY / N8N_HOST / N8N_PORT / N8N_PROTOCOL from:
  # the module-owned Secret in n8n.tf (kubernetes_secret.n8n), or the caller's
  # own Secret when n8n_encryption_key_secret_ref names one. On that path the
  # module Secret is count-gated to zero, so the name here has to follow the
  # gate: pointing the chart at "n8n-secrets" while not creating it left every
  # pod stuck in CreateContainerConfigError on a Secret that did not exist,
  # while the Secret the caller actually wrote was never read. The one caller
  # the bug spared was one whose own Secret was itself named "n8n-secrets",
  # where the hardcoded name happened to resolve to the right object.
  k8s_values_secret_refs = {
    secretRefs = {
      existingSecret = var.n8n_encryption_key_secret_ref != null ? var.n8n_encryption_key_secret_ref.name : "n8n-secrets"
    }
  }

  k8s_values_queue_mode = {
    queueMode = {
      enabled            = true
      workerReplicaCount = var.n8n_worker_keda_min_replicas
      workerConcurrency  = var.n8n_worker_concurrency
      workerExtraEnv     = []
    }
  }

  k8s_values_replicas = {
    replicaCount = 1
  }

  k8s_values_webhook_processor = {
    webhookProcessor = {
      enabled                                = true
      replicaCount                           = var.n8n_webhook_hpa_min_replicas
      disableProductionWebhooksOnMainProcess = true
      extraEnv                               = []
    }
  }

  # ── PostgreSQL SSL: CA delivery and the chart-version collision it dodges ──
  # Major and minor only; n8n_chart_version's validation guarantees both are
  # numeric.
  n8n_chart_version_parts = split(".", split("+", var.n8n_chart_version)[0])

  # True only when the pinned chart is known to render DB_POSTGRESDB_SSL_ENABLED
  # from database.ssl.enabled: upstream fixed this at chart 1.15.0
  # (n8n-io/n8n-hosting#175; earlier charts rendered DB_POSTGRESDB_SSL, which
  # n8n does not read, see the comment on k8s_values_database below). For any
  # other repository, or a prerelease (a SemVer "-" segment, which may predate
  # the fix), the chart contents cannot be verified, and the safe failure is a
  # duplicate "true" entry rather than a missing one, so the extraEnv block
  # below keeps emitting its own in that case. Same gate as
  # terraform-aws-n8n, terraform-google-n8n#39 and terraform-azurerm-n8n#77.
  n8n_chart_renders_postgres_ssl_enabled = var.n8n_chart_repository != "oci://ghcr.io/n8n-io/n8n-helm-chart" ? false : (
    strcontains(split("+", var.n8n_chart_version)[0], "-") ? false : (
      tonumber(local.n8n_chart_version_parts[0]) > 1 ? true : (
        tonumber(local.n8n_chart_version_parts[0]) < 1 ? false : tonumber(local.n8n_chart_version_parts[1]) >= 15
      )
    )
  )

  # Whether the chart's database.ssl.ca value carries the CA. Gated on
  # db_postgresdb_ssl_enabled, not also on db_postgresdb_ssl_reject_unauthorized:
  # a CA with verification off is encrypted but unverified either way, which
  # check.db_postgresdb_ssl_ca_pem_requires_verification (n8n.tf) flags as
  # likely a mistake, not something this local silently drops.
  postgres_ssl_ca_active = var.db_postgresdb_ssl_enabled && var.db_postgresdb_ssl_ca_pem != null

  # The CA reaches n8n through the chart's own database.ssl.ca value, the one
  # case where this module does use that key (see k8s_values_database below
  # for why it otherwise stays unset). Keeping the CA inside the Helm release
  # means a failed upgrade's atomic rollback restores the previous CA with the
  # pods, removing the CA is a Helm-only change with no separate object to
  # delete first, and the chart's checksum/config annotation rolls the pods
  # when only the CA changes.
  #
  # rejectUnauthorized is always true here, whatever
  # db_postgresdb_ssl_reject_unauthorized says: the chart renders
  # DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED only when this is false
  # (_configmap-env.tpl), and the extraEnv block in this file owns that name
  # unconditionally. Pinning it true here keeps the chart from ever rendering
  # a second entry under it, whatever the caller's own setting is.
  #
  # trimspace keeps the rendered value stable when the caller's PEM file ends
  # in a newline, so a whitespace-only edit does not roll the pods. The size
  # validation on db_postgresdb_ssl_ca_pem measures the same trimmed value.
  postgres_ssl_ca_values = local.postgres_ssl_ca_active ? {
    ssl = {
      enabled            = true
      rejectUnauthorized = true
      ca                 = trimspace(var.db_postgresdb_ssl_ca_pem)
    }
  } : {}

  # Same split as k8s_values_redis below. On the cnpg path the operator owns the
  # endpoint: its rw Service listens on 5432 and initdb creates the database and
  # owner from the cnpg_* inputs. On the external path all three belong to the
  # caller, and reading them from the cnpg_* inputs, documented "Only used when
  # postgres_backend = cnpg", meant an external Postgres had to be n8n/n8n on
  # 5432 or it could not be reached at all.
  k8s_values_database = {
    database = merge(
      {
        type        = "postgresdb"
        useExternal = true
        host        = local.k8s_pg_host
        port        = local.cnpg_enabled ? 5432 : var.db_port
        database    = local.cnpg_enabled ? var.cnpg_database_name : var.db_name
        schema      = "public"
        user        = local.cnpg_enabled ? var.cnpg_database_owner : var.db_user
        passwordSecret = {
          name = local.k8s_pg_secret_name
          key  = local.k8s_pg_secret_password_key
        }
      },
      # The ssl key is otherwise left unset, deliberately. DB_POSTGRESDB_SSL_ENABLED
      # and DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED are set through config.extraEnv
      # in this file (from db_postgresdb_ssl_enabled and
      # db_postgresdb_ssl_reject_unauthorized), and the chart's own ssl.enabled
      # must not ALSO render them, for two independent reasons.
      #
      # It used to not do what its name suggests. Through chart 1.10.0,
      # `database.ssl.enabled` rendered DB_POSTGRESDB_SSL
      # (templates/configmap.yaml:26), and that variable did not exist in
      # n8n: the product declares its database TLS inputs in
      # packages/@n8n/config/src/configs/database.config.ts as
      # DB_POSTGRESDB_SSL_ENABLED, _CA, _CERT, _KEY and _REJECT_UNAUTHORIZED,
      # verified against n8n 2.35.0, and read nothing named DB_POSTGRESDB_SSL.
      # Setting the chart key looked like enabling TLS and changed nothing the
      # product read. Chart 1.16.0 fixed the name (it now renders
      # DB_POSTGRESDB_SSL_ENABLED), which is why local.postgres_ssl_ca_values
      # below can lean on it at all, but ssl.enabled stays off here on every
      # path that is not delivering a CA, for the second, independent reason.
      #
      # And its second effect does collide. With `rejectUnauthorized = false`
      # the chart renders DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED itself, which
      # this module already emits, a duplicate name in the container's env,
      # which Kubernetes rejects on every later patch. That is the failure that
      # once broke every helm upgrade, and its rollback with it.
      # local.postgres_ssl_ca_values pins rejectUnauthorized = true whenever it
      # sets ssl.enabled, which keeps the chart's own `if not rejectUnauthorized`
      # guard (_configmap-env.tpl) from ever firing: config.extraEnv stays the
      # only source of that name, regardless of what
      # db_postgresdb_ssl_reject_unauthorized actually says.
      #
      # local.postgres_ssl_ca_values is {} whenever db_postgresdb_ssl_ca_pem is
      # null or db_postgresdb_ssl_enabled is false, so a deployment that never
      # sets a CA renders this key byte-identical to before: merge() with an
      # empty map changes nothing. See the comment there, and
      # docs/postgresql-tls.md, for why the CNPG path's own operator-issued CA
      # is not read or wired in automatically.
      local.postgres_ssl_ca_values,
    )
  }

  # On the valkey path the in-cluster Service always listens on 6379 and the
  # chart manages the credential; on the external path every one of these comes
  # from the caller, and hardcoding them here silently ignored four documented
  # inputs (port, username, TLS and the timeout threshold).
  k8s_values_redis = {
    redis = merge(
      {
        enabled     = true
        useExternal = true
        host        = local.k8s_redis_host
        port        = local.k8s_redis_port
        username    = local.valkey_enabled || local.redis_username_value == null ? "" : local.redis_username_value
        database    = 0

        # The chart's only use of redis.worker.timeout is to render
        # N8N_GRACEFUL_SHUTDOWN_TIMEOUT (templates/configmap.yaml), in seconds,
        # which is exactly what this input means. Set through the chart's own
        # key rather than appended to config.extraEnv: the chart already emits
        # that name from its ConfigMap, and a second entry with the same name
        # makes every later helm upgrade fail. See the note on webhook.url.
        #
        # lockDuration, lockRenewTime and stalledInterval are merged in
        # conditionally, same reasoning: the chart renders
        # QUEUE_WORKER_LOCK_DURATION / _LOCK_RENEW_TIME / _STALLED_INTERVAL
        # from this same redis.worker block (unlike timeout, only when their
        # own key is set), and the QUEUE_ prefix in n8n_managed_env_prefixes
        # blocks all three from n8n_extra_env regardless. Omitted on the null
        # path, which is every deployment before this input existed, so the
        # chart's own defaults (60000 / 10000 / 30000 ms) keep applying.
        worker = merge(
          { timeout = var.n8n_termination_grace_period },
          var.n8n_queue_worker_lock_duration == null ? {} : {
            lockDuration = var.n8n_queue_worker_lock_duration
          },
          var.n8n_queue_worker_lock_renew_time == null ? {} : {
            lockRenewTime = var.n8n_queue_worker_lock_renew_time
          },
          var.n8n_queue_worker_stalled_interval == null ? {} : {
            stalledInterval = var.n8n_queue_worker_stalled_interval
          },
        )
      },
      # Only when there is a credential to point at. The valkey path always
      # has one (the module generates it); the external path has one only when
      # the caller supplied a token or a secret ref. Rendered unconditionally,
      # this named "n8n-redis-secret" on the no-auth external path - a Secret
      # the module only creates when auth is active - and the chart's
      # `if and .name .key` guard passed, so every pod carried a secretKeyRef
      # to a Secret that does not exist and sat in CreateContainerConfigError.
      local.valkey_enabled || local.redis_auth_active ? {
        passwordSecret = {
          name = local.k8s_redis_secret_name
          key  = local.k8s_redis_secret_password_key
        }
      } : {},
      # Sets QUEUE_BULL_PREFIX (configmap.yaml's `if .Values.redis.prefix`
      # guard omits it entirely when unset, so Bull's own "bull" default
      # applies exactly as before on the null path). The matching
      # N8N_REDIS_KEY_PREFIX env var lives in config.extraEnv, and the KEDA
      # listName reads local.redis_key_prefix_value: all three have to move
      # together, see redis_key_prefix. Until this key existed, only the KEDA
      # half moved - setting the input repointed the scaler at
      # "<prefix>:jobs:wait" while Bull kept writing under "bull", so worker
      # autoscaling froze and none of the promised per-deployment isolation
      # happened.
      var.redis_key_prefix != null ? { prefix = var.redis_key_prefix } : {},
      # Empty unless n8n_redis_timeout_threshold is set, so the chart's own
      # 10000 continues to apply and existing releases render unchanged.
      local.redis_timeout_values,
    )
  }

  # The module provisions no object storage: it will not own a stateful data
  # service on a cluster it does not own. Binary data follows
  # n8n_binary_data_mode - Postgres by default, or filesystem on a shared
  # volume the caller mounts - and execution data stays in Postgres.
  # See docs/operations.md for wiring an external bucket by hand.
  # N8N_WEBHOOK_URL (the chart renamed it from WEBHOOK_URL at chart 1.16.0,
  # matching n8n's own deprecation of WEBHOOK_URL as of n8n 2.35.0) is the
  # address n8n hands out for callers to POST to. Left
  # unset, n8n builds it from N8N_PROTOCOL + N8N_HOST, and N8N_PROTOCOL is
  # "http" here because TLS terminates at the ingress rather than in the pod --
  # so every advertised webhook URL would be http:// against an https://
  # endpoint. It also has to be settable independently for a split ingress,
  # where webhooks are advertised on a different hostname from the editor.
  #
  # Set through the chart's webhook.url rather than appended to
  # config.extraEnv. The chart renders N8N_WEBHOOK_URL into its own ConfigMap and
  # references it from all three pod types (main, worker and webhook processor
  # each pull the same key), so the coverage is identical -- but a second entry
  # of the same name in the container's env list makes Kubernetes' strategic
  # merge patch fail on every subsequent helm upgrade, and the rollback fails
  # with it, leaving the release stuck in `failed`. The first apply succeeds,
  # so this only ever surfaced on the second one.
  #
  # The exception is a split ingress, below.
  # k8s_ingress_host is documented as "only used when create_ingress = true",
  # and homelab-split-ingress leaves it unset on the stated grounds that every
  # consumer of it is gated on create_ingress except the webhook URL fallback,
  # which n8n_webhook_url overrides. So the editor base reads n8n_domain once
  # the module renders no Ingress: sourcing it from k8s_ingress_host would make
  # a value the docs call ignored decide the OAuth callback host.
  #
  # The webhook fallback keeps reading k8s_ingress_host_effective, unchanged --
  # it is the pre-existing exception the example already accounts for, and
  # moving it would change an address callers may have registered elsewhere.
  k8s_editor_base_url    = "https://${var.create_ingress ? local.k8s_ingress_host_effective : local.n8n_domain}"
  k8s_webhook_url        = coalesce(var.n8n_webhook_url, "https://${local.k8s_ingress_host_effective}")
  k8s_split_ingress_urls = !var.create_ingress && local.k8s_webhook_url != local.k8s_editor_base_url

  # chart 1.16.0's configmap.yaml derives N8N_EDITOR_BASE_URL from editor.url
  # first (this module never sets it), then the first
  # ingress host, and failing that from webhook.url, on the stated assumption
  # that "webhook.url is the domain". That holds for a single host and breaks
  # for a split one: with create_ingress = false the chart has no ingress host
  # to read, so it labels the editor with the webhook hostname.
  #
  # Nothing warns. The editor still loads, because it is reached through the
  # caller's own Ingress on the right host. What breaks is every absolute URL
  # n8n builds from UrlService.getInstanceBaseUrl(), which prefers
  # N8N_EDITOR_BASE_URL over N8N_WEBHOOK_URL -- above all the OAuth2 redirect URI,
  # <editor base>/rest/oauth2-credential/callback. Sent to the webhook host
  # that path 404s twice over: a split ingress routes only the webhook prefixes
  # there, and the webhook processor serves no /rest routes even when reached.
  # So every OAuth credential fails at the provider's callback, while webhook
  # delivery keeps working, which points the search at the wrong half.
  #
  # Fixed by taking both names away from the chart rather than overriding it.
  # An override would put a second entry of the same name in the env list and
  # wedge the next upgrade, exactly as the note above describes. Emptying
  # webhook.url makes the chart's own guards (`if .Values.webhook.url`, and the
  # matching ones on the configMapKeyRef entries in _configmap-env.tpl) render
  # neither key nor either reference, leaving the module to set both in
  # config.extraEnv with no duplication.
  #
  # Single-host deployments are untouched: k8s_split_ingress_urls is false
  # whenever the two URLs agree, and false whenever create_ingress is true,
  # since the chart then reads its own ingress host and is already correct.
  k8s_values_webhook = {
    webhook = {
      url = local.k8s_split_ingress_urls ? "" : local.k8s_webhook_url
    }
  }

  k8s_values_s3_off = {
    s3 = {
      enabled = false
      storage = {
        mode           = "filesystem"
        availableModes = "filesystem"
      }
    }
  }

  k8s_values_hpa = {
    hpa = {
      # Always off. n8n elects a leader among main pods only under multi-main,
      # which is a licensed feature this module does not carry, so a second main
      # would be a second leader. The bounds are rendered to keep the chart's
      # value shape intact; nothing reads them while enabled is false.
      main = {
        enabled                        = false
        minReplicas                    = 1
        maxReplicas                    = 1
        targetCPUUtilizationPercentage = 70
      }
      worker = {
        # Yields to the KEDA ScaledObject below when the caller attests KEDA is
        # installed. Two controllers on one Deployment fight over replica count.
        enabled                        = !var.k8s_keda_installed
        minReplicas                    = var.n8n_worker_keda_min_replicas
        maxReplicas                    = var.n8n_worker_keda_max_replicas
        targetCPUUtilizationPercentage = 70
      }
      webhookProcessor = {
        enabled = var.n8n_webhook_hpa_enabled
        # Scale-down keeps the Kubernetes API's own 300s stabilization; only
        # scale-up is exposed, because that is the direction a webhook burst
        # cares about.
        behavior = {
          scaleUp = {
            stabilizationWindowSeconds = var.n8n_webhook_hpa_scale_up_stabilization_window_seconds
          }
        }
        minReplicas                    = var.n8n_webhook_hpa_min_replicas
        maxReplicas                    = var.n8n_webhook_hpa_max_replicas
        targetCPUUtilizationPercentage = var.n8n_webhook_hpa_cpu_threshold
      }
    }
  }

  # ── Pod shutdown budget ────────────────────────────────────────────────────
  # n8n_termination_grace_period reached only one of the two things that have
  # to agree. It sets the chart's redis.worker.timeout, which renders
  # N8N_GRACEFUL_SHUTDOWN_TIMEOUT into the shared ConfigMap and so applies to
  # main, worker and webhook processor alike: that is how long n8n believes it
  # has to finish in-flight work after SIGTERM. The pod's own
  # terminationGracePeriodSeconds, which is what decides when the kubelet stops
  # asking and sends SIGKILL, stayed on the chart's 60 no matter what the input
  # said.
  #
  # The two clocks do not start together, which is what makes the default wrong
  # rather than merely equal. Kubernetes starts the grace period when the pod
  # is marked for deletion, then runs the preStop hook, and only sends SIGTERM
  # once the hook returns. n8n's budget therefore begins one preStop sleep
  # after the kubelet's. At the chart defaults that is a 10 second sleep inside
  # a 60 second grace period against a 60 second shutdown budget: n8n is killed
  # at 50 of the 60 seconds it was told it had, mid-execution.
  #
  # Raising the input bought nothing, silently. Asking for 300 seconds of
  # drain still got a pod killed at 60, so the usable window stayed at roughly
  # 50 seconds whatever the input said. Executions finishing inside that were
  # never at risk; the long-running ones the raised budget existed to protect
  # were the ones it failed, and a worker scale-down or a node drain took them
  # with nothing recording why.
  #
  # So the pod-level period is the sum: the drain sleep plus the budget n8n is
  # given after it. That makes the input mean what its description always said,
  # "seconds Kubernetes waits after SIGTERM", and the sum is what the pod needs
  # for that to be true.
  n8n_pod_termination_grace_period = var.n8n_termination_grace_period + var.n8n_prestop_sleep

  k8s_values_lifecycle = {
    lifecycle = {
      # All three pod families, because N8N_GRACEFUL_SHUTDOWN_TIMEOUT reaches
      # all three: it comes from the chart's shared ConfigMap, not a
      # worker-only one, despite living under a redis.worker key.
      for family in ["main", "worker", "webhookProcessor"] : family => {
        terminationGracePeriodSeconds = local.n8n_pod_termination_grace_period

        # The drain delay, and the only place it has ever taken effect. The
        # module used to render n8n_prestop_sleep as an N8N_PRESTOP_SLEEP
        # environment variable, which no chart template references and n8n
        # does not declare, so raising the input changed nothing and the real
        # window stayed on the chart's hardcoded `sleep 10`.
        #
        # What the sleep buys: SIGTERM is not sent until this hook returns, so
        # the pod goes on serving while the ingress controller and Cilium
        # remove it from their endpoint lists. Without the gap a rollout drops
        # requests that were routed microseconds before the pod left the
        # Service, which surfaces as occasional 502s during an otherwise clean
        # deploy.
        preStop = {
          enabled = true
          command = ["/bin/sh", "-c", "sleep ${var.n8n_prestop_sleep}"]
        }
      }
    }
  }

  # ── Pod network policy ─────────────────────────────────────────────────────
  # Off by default, matching the chart, and exposed rather than decided here
  # because what it costs depends entirely on what the caller's workflows call.
  #
  # Worth being precise about what the chart's policy is, since "NetworkPolicy"
  # suggests more than it delivers: every egress rule it writes has `to: []`,
  # meaning all destinations, and differs only by port. So it is a port
  # allowlist. DNS, the configured database port, the configured Redis port and
  # 443 reach anywhere; everything else reaches nothing.
  #
  # That still closes something real. n8n makes arbitrary outbound HTTP by
  # design, so a workflow, or a node with an SSRF bug, can reach whatever the
  # pod network can: on a Talos cluster that includes the Talos API on 50000.
  # What it does not close is anything on 443, the Kubernetes API included, so
  # this is not a substitute for a policy written against real destinations.
  k8s_values_network_policy = {
    networkPolicy = {
      enabled = var.n8n_network_policy_enabled
    }
  }

  # ── Rollout strategy for the single main pod ───────────────────────────────
  # The chart ships `strategy: {}`, and its template wraps the key in a `with`,
  # so an empty map renders nothing at all and the Deployment takes Kubernetes'
  # default: RollingUpdate at maxSurge 25%. Twenty-five percent of one replica
  # rounds up to one, so the new main goes Ready while the old one is still
  # serving, and the old one goes on serving until its pod's
  # terminationGracePeriodSeconds runs out. That is one number, not a sum of
  # two clocks: the kubelet runs the preStop hook inside the grace period
  # rather than before it. The number happens to be a sum because this module
  # sizes the period as n8n_termination_grace_period + n8n_prestop_sleep, so
  # the drain sleep and the shutdown budget that follows it both fit.
  #
  # That window is two n8n mains sharing one Redis and one Postgres. Leader
  # election among mains is the licensed multi-main feature this module does
  # not carry, so both pods hold schedule triggers and both register on the
  # pub/sub command channel: cron workflows fire twice, and nothing anywhere
  # records that a second main existed. On a version bump the new main also
  # runs its one-way startup migrations while the old one is still reading the
  # old schema. Everything the module does to guarantee one main
  # (replicaCount = 1, hpa.main.enabled = false) was true except during the
  # rollout that changes it.
  #
  # Only Recreate renders zero overlap. RollingUpdate's maxSurge = 0 bounds
  # how many pods may exist, but a Terminating pod stops counting the moment
  # its ReplicaSet is scaled to zero while the process inside it keeps
  # running, so the controller still creates the incoming main while the
  # outgoing one finishes draining (see check.rolling_update_still_overlaps_two_mains
  # and n8n_main_strategy's own validation message). Live-cluster
  # measurement observed a ~9.5s overlap window under RollingUpdate.
  #
  # merge() rather than a ternary returning two whole objects: Terraform
  # unifies a conditional's branches to one type, and an object carrying
  # rollingUpdate against one that does not is "Inconsistent conditional result
  # types". The same unification rule that stringifies a number elsewhere in
  # this file (see launcher.autoShutdownTimeout below) rejects the mismatch
  # outright here.
  k8s_values_strategy = {
    strategy = merge(
      { type = var.n8n_main_strategy },
      var.n8n_main_strategy == "RollingUpdate" ? {
        # maxUnavailable must be at least 1 alongside maxSurge = 0, or the
        # Deployment may neither add a pod nor remove one and never progresses.
        rollingUpdate = {
          maxSurge       = 0
          maxUnavailable = 1
        }
      } : {},
    )
  }

  # ── Disruption budget for the single main pod ──────────────────────────────
  # Before chart 1.16.0, the chart defaulted pdb.enabled to true with
  # minAvailable = 1 and rendered the object over the main Deployment only
  # (templates/pdb.yaml selects component: main). Against this module's
  # replicaCount = 1 that was allowedDisruptions = 0 forever: no voluntary
  # eviction of the main pod ever succeeded, so draining the node it landed on
  # blocked indefinitely and a Talos node upgrade stalled behind it.
  #
  # Chart 1.16.0 (n8n-io/n8n-hosting#228) now gates templates/pdb.yaml on main
  # running more than one replica, which this module never does, so the
  # object no longer renders regardless of this value; see the note in
  # n8n.tf where the check that used to warn about this lived. The input
  # stays false by default anyway, both to document the intent plainly and in
  # case this module ever supports more than one main. There is no longer a
  # production reader of whether n8n_extra_helm_values also sets pdb.enabled
  # (the check that read it was removed above), so that detection is no
  # longer a named local; tests/defaults.tftest.hcl inlines the same
  # try(yamldecode(...)) expression directly where it still wants to assert
  # the overlay is visible.

  # The strategy the Deployment actually ends up with. Same two-routes problem
  # as the PDB below: n8n_extra_helm_values is merged after the module's own
  # values and Helm gives the later file precedence, so the overlay can select
  # RollingUpdate regardless of what the typed input says.
  #
  # Helm merges the two values files key by key, and an explicit null in the
  # later one is a deletion rather than an absence. That splits the overlay
  # into five outcomes, and only two of them take the Deployment away from
  # this module's Recreate:
  #
  #   strategy absent                -> module's type stands
  #   strategy: null                 -> whole key deleted, Kubernetes default
  #   strategy: {} or no `type` key  -> map merge, module's type survives
  #   strategy: {type: null}         -> type deleted, Kubernetes default
  #   strategy: {type: X}            -> X
  #
  # The Kubernetes default is RollingUpdate at maxSurge 25%, which is worse
  # than asking for RollingUpdate here: this module's own rendering at least
  # pins maxSurge to 0, so it overlaps a terminating main rather than surging
  # a second one to Ready. Neither coalesce nor a plain key-presence test
  # separates the deletions from the merges, so each null is tested for
  # directly.
  n8n_extra_values_decoded = try(yamldecode(var.n8n_extra_helm_values), {})

  n8n_extra_values_keys = try(keys(local.n8n_extra_values_decoded), [])

  n8n_extra_declares_strategy = contains(local.n8n_extra_values_keys, "strategy")

  # `strategy: null` decodes to null while `strategy: {}` decodes to an empty
  # map, so this is the one test that tells a deleted key from an empty one.
  n8n_extra_deletes_strategy = local.n8n_extra_declares_strategy && try(local.n8n_extra_values_decoded.strategy, null) == null

  # keys() of a null or a non-mapping raises, and try() reads that as "no type
  # key here", which is what a map merge leaving the module's type alone means.
  n8n_extra_declares_strategy_type = contains(try(keys(local.n8n_extra_values_decoded.strategy), []), "type")

  n8n_main_strategy_via_extra_values = try(local.n8n_extra_values_decoded.strategy.type, null)

  n8n_extra_deletes_strategy_type = local.n8n_extra_declares_strategy_type && local.n8n_main_strategy_via_extra_values == null

  # True only for the two deletion rows above, where nothing pins maxSurge and
  # the incoming main goes Ready beside the outgoing one rather than after it.
  n8n_main_strategy_left_to_kubernetes = local.n8n_extra_deletes_strategy || local.n8n_extra_deletes_strategy_type

  n8n_main_strategy_effective = (
    local.n8n_main_strategy_left_to_kubernetes ? "RollingUpdate" : (
      local.n8n_main_strategy_via_extra_values != null ? local.n8n_main_strategy_via_extra_values : var.n8n_main_strategy
    )
  )

  # Same five-way split as the strategy above, for ingress.enabled. Needed
  # because n8n_proxy_hops is checked against whether an Ingress is actually in
  # front of the pods, and create_ingress is only the module's half of that
  # answer: the overlay is merged last and decides.
  #
  # The two deletion rows land differently here than they do for strategy.
  # Deleting the key does not hand the decision to Kubernetes, it hands it back
  # to chart 1.10.0's own values.yaml, where `ingress.enabled` is false. So a
  # deletion means no Ingress, which is the same answer as an explicit false
  # and the reason both collapse to one branch below.
  n8n_extra_declares_ingress = contains(local.n8n_extra_values_keys, "ingress")

  n8n_extra_deletes_ingress = local.n8n_extra_declares_ingress && try(local.n8n_extra_values_decoded.ingress, null) == null

  n8n_extra_declares_ingress_enabled = contains(try(keys(local.n8n_extra_values_decoded.ingress), []), "enabled")

  n8n_ingress_enabled_via_extra_values = try(local.n8n_extra_values_decoded.ingress.enabled, null)

  n8n_extra_deletes_ingress_enabled = local.n8n_extra_declares_ingress_enabled && local.n8n_ingress_enabled_via_extra_values == null

  n8n_ingress_rendered = (
    local.n8n_extra_deletes_ingress || local.n8n_extra_deletes_ingress_enabled ? false : (
      local.n8n_ingress_enabled_via_extra_values != null ? local.n8n_ingress_enabled_via_extra_values : var.create_ingress
    )
  )

  # And once more for networkPolicy.enabled, for the same reason and with the
  # same shape as ingress above: the check that warns about a blocked OTLP
  # collector has to know whether the policy is really rendered, and
  # n8n_network_policy_enabled is only this module's half of that answer.
  #
  # Chart 1.10.0 defaults networkPolicy.enabled to false, so the two deletion
  # rows mean no policy, which is the same answer as an explicit false. Both
  # directions matter here. Reading the input alone would stay quiet when the
  # overlay turns the policy on behind a default-false input, which is the
  # silent trace loss the check exists to catch, and would warn about a
  # collision that cannot happen when the overlay turns it off.
  n8n_extra_declares_network_policy = contains(local.n8n_extra_values_keys, "networkPolicy")

  n8n_extra_deletes_network_policy = local.n8n_extra_declares_network_policy && try(local.n8n_extra_values_decoded.networkPolicy, null) == null

  n8n_extra_declares_network_policy_enabled = contains(try(keys(local.n8n_extra_values_decoded.networkPolicy), []), "enabled")

  n8n_network_policy_enabled_via_extra_values = try(local.n8n_extra_values_decoded.networkPolicy.enabled, null)

  n8n_extra_deletes_network_policy_enabled = local.n8n_extra_declares_network_policy_enabled && local.n8n_network_policy_enabled_via_extra_values == null

  n8n_network_policy_rendered = (
    local.n8n_extra_deletes_network_policy || local.n8n_extra_deletes_network_policy_enabled ? false : (
      local.n8n_network_policy_enabled_via_extra_values != null ? local.n8n_network_policy_enabled_via_extra_values : var.n8n_network_policy_enabled
    )
  )

  # What that policy actually permits on the way out, so the OTLP check can ask
  # whether the collector is reachable rather than whether it is on 443.
  #
  # templates/networkpolicy.yaml writes one egress rule per port, each with
  # `to: []`, for 53, database.port when database.useExternal, redis.port when
  # queueMode.enabled, and 443. This module renders both of those flags true
  # unconditionally, so both ports are always in the list.
  #
  # The two ports are recomputed from their own inputs rather than read back
  # out of k8s_values_final, which can be sensitive as a whole: an
  # error_message built from it would be suppressed in full, printing nothing
  # where the port belongs. These expressions are the same ones
  # k8s_values_database and k8s_values_redis use.
  #
  # Not because it carries the database and Redis passwords, which an earlier
  # version of this comment claimed and which is not true of either fragment:
  # k8s_values_database and k8s_values_redis pass passwordSecret = {name, key}
  # and no value, which is the whole point of the Secret wiring in n8n.tf. The
  # route that does make it sensitive is n8n_otel_exporter_otlp_headers, a
  # sensitive input that lands in the tree directly. So the conclusion holds on
  # the OTLP path and the ports are recomputed unconditionally, because a local
  # that is sensitive only sometimes is worse to reason about than one that is
  # never read here at all.
  #
  # n8n_extra_helm_values can move either port the same way it can move
  # networkPolicy.enabled, and the chart writes the policy from whatever
  # survives the merge, so the allowlist follows the overlay too. Naming the key
  # replaces the module's value; deleting it with an explicit null falls back to
  # the chart's own default, 5432 and 6379. A `database: null` or `redis: null`
  # that deletes the whole block is not modelled: it takes the host and the
  # credentials with it, so the release is broken well before the policy is.
  n8n_extra_declares_database_port = contains(try(keys(local.n8n_extra_values_decoded.database), []), "port")
  n8n_extra_declares_redis_port    = contains(try(keys(local.n8n_extra_values_decoded.redis), []), "port")

  n8n_extra_database_port = try(tonumber(local.n8n_extra_values_decoded.database.port), null)
  n8n_extra_redis_port    = try(tonumber(local.n8n_extra_values_decoded.redis.port), null)

  n8n_network_policy_database_port = (
    local.n8n_extra_declares_database_port
    ? coalesce(local.n8n_extra_database_port, 5432)
    : (local.cnpg_enabled ? 5432 : var.db_port)
  )

  n8n_network_policy_redis_port = (
    local.n8n_extra_declares_redis_port
    ? coalesce(local.n8n_extra_redis_port, 6379)
    : local.k8s_redis_port
  )

  n8n_network_policy_allowed_ports = [
    53,
    443,
    local.n8n_network_policy_database_port,
    local.n8n_network_policy_redis_port,
  ]

  # Everything between "://" and the first "/", "?" or "#". Null when the
  # endpoint is null or not a URL, which the check treats as passing: a
  # malformed endpoint is n8n's problem to report, not this check's.
  n8n_otel_endpoint_authority = try(
    regex("^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]*)", var.n8n_otel_exporter_otlp_endpoint)[0],
    null
  )

  # A bracketed IPv6 literal carries colons of its own, so the port is only a
  # ":digits" that follows the closing bracket. Hosts that are names or IPv4
  # addresses have no colon but the port separator. With no explicit port the
  # scheme decides, which is the whole reason an https:// URL passes.
  n8n_otel_endpoint_host = try(
    lower(regex("^(\\[[^\\]]*\\]|[^:]*)", local.n8n_otel_endpoint_authority)[0]),
    null
  )

  n8n_otel_endpoint_port = try(
    tonumber(regex("^(?:\\[[^\\]]*\\]|[^:]*):([0-9]+)$", local.n8n_otel_endpoint_authority)[0]),
    can(regex("^(?i:https)://", var.n8n_otel_exporter_otlp_endpoint)) ? 443 : 80
  )

  # Loopback never leaves the pod, so no NetworkPolicy applies to it and a
  # sidecar collector is reachable whatever the allowlist says. This is the
  # same reason a null endpoint is fine: n8n's own default is localhost:4318.
  #
  # Only a numeric address counts. "127.collector.example" is a perfectly
  # ordinary hostname that a prefix match would wave through, and its A record
  # can point anywhere. The IPv6 pattern accepts every spelling of ::1, which is
  # any run of zero groups followed by a 1: "::1", "0:0:0:0:0:0:0:1" and
  # "0000:...:0001" all reach the same address.
  n8n_otel_endpoint_host_address = local.n8n_otel_endpoint_host == null ? null : trim(local.n8n_otel_endpoint_host, "[]")

  n8n_otel_endpoint_is_loopback = local.n8n_otel_endpoint_host_address == null ? false : (
    local.n8n_otel_endpoint_host_address == "localhost" ||
    can(regex("^127\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$", local.n8n_otel_endpoint_host_address)) ||
    can(regex("^[0:]*:0*1$", local.n8n_otel_endpoint_host_address))
  )

  n8n_otel_collector_reachable_under_network_policy = (
    local.n8n_otel_endpoint_authority == null ||
    local.n8n_otel_endpoint_is_loopback ||
    contains(local.n8n_network_policy_allowed_ports, local.n8n_otel_endpoint_port)
  )

  # Whether the values tree asks the chart to enable the PDB, by either route:
  # the typed input, or the n8n_extra_helm_values overlay. The chart itself no
  # longer acts on this for a single main pool (see the comment above), but
  # tests still assert that both routes reach local.k8s_values_final honestly,
  # which is what local.n8n_pdb_enabled_via_extra_values is read by below.

  k8s_values_pdb = {
    pdb = {
      enabled = var.n8n_main_pdb_enabled
    }
  }

  # The chart's own extraVolumes/extraVolumeMounts. Translated in the locals
  # above from the module's snake_case inputs, and then, until now, never
  # rendered into the values tree at all.
  k8s_values_volumes = {
    extraVolumes      = local.n8n_extra_volumes
    extraVolumeMounts = local.n8n_extra_volume_mounts
  }

  # podAnnotations reaches the pod template on all three Deployments
  # (deployment-main.yaml, deployment-worker.yaml,
  # deployment-webhook-processor.yaml all merge it in ahead of
  # commonAnnotations). Two checksums can land here: the one that rolls every
  # n8n pod when n8n_extra_ca_pem changes, since Node reads NODE_EXTRA_CA_CERTS
  # once at start and a Secret update alone does not restart anything reading
  # it, and the one that rolls every n8n pod when the generated Valkey
  # password rotates. The password reaches these pods through a secretKeyRef
  # resolved once at start, so a rotation otherwise updates the Secret and
  # restarts nothing: every pod keeps the old password until something else
  # restarts it, and then meets whichever ACL generation Valkey happens to be
  # running. helm_release.valkey carries the same checksum (redis_valkey.tf),
  # so one apply rolls the server onto the new ACL and the clients onto the
  # new password together. The hash, never the password: annotations are
  # readable by anyone who can get a pod.
  #
  # The Valkey checksum is opt-in (valkey_password_rotation_roll_enabled,
  # default false), not just gated on the backend. Introducing a brand-new key
  # into podAnnotations is itself a pod-template change, so the apply that
  # first adds this key rolls every n8n pod and, via deploymentStrategy =
  # Recreate, takes Valkey fully down and back up once (the standalone PVC is
  # ReadWriteOnce, so a rolling update of it would deadlock rather than
  # overlap). A default caller taking this module version has rotated nothing
  # and asked for nothing; forcing that one-time disruption on every such
  # caller on adoption, rather than only on the caller who deliberately turns
  # the feature on, is the wrong trade. Gated on the valkey backend too, so
  # the external-redis path renders byte-identical regardless.
  k8s_values_pod_annotations = (local.n8n_extra_ca_enabled || (local.valkey_enabled && var.valkey_password_rotation_roll_enabled)) ? {
    podAnnotations = merge(
      local.n8n_extra_ca_enabled ? { "checksum/extra-ca" = sha256(local.n8n_ca_bundle_pem) } : {},
      (local.valkey_enabled && var.valkey_password_rotation_roll_enabled) ? { "checksum/valkey-password" = sha256(random_password.valkey_default[0].result) } : {},
    )
  } : {}

  # var.n8n_dns_config with unset keys removed. Necessary because the
  # variable's optional() attributes materialise as null rather than being
  # absent, and the chart renders dnsConfig with a bare key present even when
  # every entry under it is null, which is not the same as omitting the key.
  n8n_dns_config_options = var.n8n_dns_config == null ? [] : [
    for o in coalesce(var.n8n_dns_config.options, []) :
    o.value == null ? { name = o.name } : { name = o.name, value = o.value }
  ]

  n8n_dns_config_stripped = var.n8n_dns_config == null ? {} : {
    for k, v in {
      nameservers = var.n8n_dns_config.nameservers
      searches    = var.n8n_dns_config.searches
      options     = length(local.n8n_dns_config_options) == 0 ? null : local.n8n_dns_config_options
    } : k => v if v != null
  }

  # Collapsed to null when nothing survives the stripping, so a caller passing
  # `n8n_dns_config = {}` (or all-null attributes) omits the dnsConfig key from
  # the Helm values entirely rather than rendering `dnsConfig: {}`, keeping the
  # variable's "null omits the block entirely" promise true for every
  # equivalent-to-unset shape.
  n8n_dns_config = length(local.n8n_dns_config_stripped) == 0 ? null : local.n8n_dns_config_stripped

  k8s_values_dns = local.n8n_dns_config == null ? {} : {
    dnsConfig = local.n8n_dns_config
  }

  # Sidecars, translated from the snake_case inputs the same way the volumes
  # above are. resources is flattened from four optional strings into the
  # nested requests/limits shape Kubernetes wants, and an absent corner is
  # omitted rather than rendered null, because a null request is not the same
  # as no request: the first is rejected by the API server, the second inherits
  # the namespace default.
  n8n_extra_containers = [
    for c in var.n8n_extra_containers : merge(
      {
        name  = c.name
        image = c.image
      },
      c.command == null ? {} : { command = c.command },
      c.args == null ? {} : { args = c.args },
      length(c.env) == 0 ? {} : { env = c.env },
      length(c.ports) == 0 ? {} : {
        ports = [
          for p in c.ports : merge(
            { containerPort = p.container_port },
            p.name == null ? {} : { name = p.name },
          )
        ]
      },
      length(c.volume_mounts) == 0 ? {} : {
        volumeMounts = [
          for m in c.volume_mounts : merge(
            { name = m.name, mountPath = m.mount_path, readOnly = m.read_only },
            m.sub_path == null ? {} : { subPath = m.sub_path },
          )
        ]
      },
      c.resources == null ? {} : {
        resources = merge(
          merge(
            c.resources.cpu_request == null ? {} : { cpu = c.resources.cpu_request },
            c.resources.memory_request == null ? {} : { memory = c.resources.memory_request },
            ) == {} ? {} : {
            requests = merge(
              c.resources.cpu_request == null ? {} : { cpu = c.resources.cpu_request },
              c.resources.memory_request == null ? {} : { memory = c.resources.memory_request },
            )
          },
          merge(
            c.resources.cpu_limit == null ? {} : { cpu = c.resources.cpu_limit },
            c.resources.memory_limit == null ? {} : { memory = c.resources.memory_limit },
            ) == {} ? {} : {
            limits = merge(
              c.resources.cpu_limit == null ? {} : { cpu = c.resources.cpu_limit },
              c.resources.memory_limit == null ? {} : { memory = c.resources.memory_limit },
            )
          },
        )
      },
    )
  ]

  n8n_extra_init_containers = [
    for c in var.n8n_extra_init_containers : merge(
      {
        name  = c.name
        image = c.image
      },
      c.command == null ? {} : { command = c.command },
      c.args == null ? {} : { args = c.args },
      length(c.env) == 0 ? {} : { env = c.env },
      length(c.volume_mounts) == 0 ? {} : {
        volumeMounts = [
          for m in c.volume_mounts : merge(
            { name = m.name, mountPath = m.mount_path, readOnly = m.read_only },
            m.sub_path == null ? {} : { subPath = m.sub_path },
          )
        ]
      },
      c.resources == null ? {} : {
        resources = merge(
          merge(
            c.resources.cpu_request == null ? {} : { cpu = c.resources.cpu_request },
            c.resources.memory_request == null ? {} : { memory = c.resources.memory_request },
            ) == {} ? {} : {
            requests = merge(
              c.resources.cpu_request == null ? {} : { cpu = c.resources.cpu_request },
              c.resources.memory_request == null ? {} : { memory = c.resources.memory_request },
            )
          },
          merge(
            c.resources.cpu_limit == null ? {} : { cpu = c.resources.cpu_limit },
            c.resources.memory_limit == null ? {} : { memory = c.resources.memory_limit },
            ) == {} ? {} : {
            limits = merge(
              c.resources.cpu_limit == null ? {} : { cpu = c.resources.cpu_limit },
              c.resources.memory_limit == null ? {} : { memory = c.resources.memory_limit },
            )
          },
        )
      },
    )
  ]

  # Both keys are omitted entirely when empty. The chart defaults them to [],
  # so rendering an empty list would be a no-op that still shows up in every
  # `helm get values` as noise.
  k8s_values_containers = merge(
    length(local.n8n_extra_containers) == 0 ? {} : { extraContainers = local.n8n_extra_containers },
    length(local.n8n_extra_init_containers) == 0 ? {} : { extraInitContainers = local.n8n_extra_init_containers },
  )

  k8s_values_resources = {
    resources = {
      main = {
        requests = { cpu = var.n8n_main_cpu_request, memory = var.n8n_main_memory_request }
        limits   = { cpu = var.n8n_main_cpu_limit, memory = var.n8n_main_memory_limit }
      }
      worker = {
        requests = { cpu = var.n8n_worker_cpu_request, memory = var.n8n_worker_memory_request }
        limits   = { cpu = var.n8n_worker_cpu_limit, memory = var.n8n_worker_memory_limit }
      }
      # No taskRunner key here. Chart 1.16.0's top-level resources block
      # covers main, worker and webhookProcessor only; the sidecar's
      # quantities live under taskRunners.resources, in
      # k8s_values_task_runners below (_helpers.tpl's
      # n8n.taskRunnerContainer helper is the only template that reads a
      # resources key for the task-runner container, and it reads that one).
      webhookProcessor = {
        requests = { cpu = var.n8n_webhook_cpu_request, memory = var.n8n_webhook_memory_request }
        limits   = { cpu = var.n8n_webhook_cpu_limit, memory = var.n8n_webhook_memory_limit }
      }
    }
  }

  k8s_values_config = {
    config = {
      timezone = var.n8n_timezone

      extraEnv = concat(
        # Rendered on both paths, and from an input rather than a literal.
        #
        # The literal 1 was only ever right for the topology the module renders
        # itself, and it was gated on create_ingress, so a caller running their
        # own routing got no N8N_PROXY_HOPS at all: n8n then trusts no
        # X-Forwarded-For entry and attributes every request to the ingress
        # controller's own address. Both split-ingress examples worked around
        # that by setting the name through n8n_extra_env, which is the escape
        # hatch doing a typed input's job, and which no longer works now that
        # the name is reserved.
        #
        # Reserved because the module writes it: a second entry of the same
        # name in one container's env list is the duplicate that makes every
        # later helm upgrade fail its strategic merge patch, rollback included.
        [
          { name = "N8N_PROXY_HOPS", value = tostring(var.n8n_proxy_hops) },
        ],

        # Only emitted when set, so the two independent defaults (n8n's own
        # 16 MiB and the Ingress annotation's literal 32m) stay exactly as
        # they are today until a caller opts in. Setting this also moves the
        # Ingress proxy-body-size annotation (see k8s_ingress_annotations),
        # which is what keeps the proxy's limit and n8n's limit from
        # disagreeing once either one is tuned.
        var.n8n_payload_size_max != null ? [
          { name = "N8N_PAYLOAD_SIZE_MAX", value = tostring(var.n8n_payload_size_max) },
        ] : [],
        # The scheduler's timezone, emitted only when n8n_timezone is set
        # away from this module's own literal default ("UTC"), so a caller
        # who left it alone sees no render change. TZ (above, from
        # config.timezone) and GENERIC_TIMEZONE are not the same setting:
        # TZ is the process clock (log timestamps, new Date()),
        # GENERIC_TIMEZONE is what Schedule Triggers fire in, and n8n's own
        # default for it is America/New_York, not UTC and not TZ. No chart
        # template renders this name, so a caller who customizes
        # n8n_timezone away from "UTC" without this entry keeps getting
        # schedules on US Eastern no matter what they set, while the log
        # timestamps made the configuration look honored.
        var.n8n_timezone != "UTC" ? [
          { name = "GENERIC_TIMEZONE", value = var.n8n_timezone },
        ] : [],

        # Binary data. Emitted only in filesystem mode: "database" is what n8n
        # already does in queue mode, so rendering it would add a variable that
        # changes nothing and reserve a name a caller may be setting themselves.
        # The path goes with it every time. Setting the mode alone leaves n8n
        # writing under its own default rather than the volume that was
        # mounted, which is the same silent loss the input's validation exists
        # to prevent, arrived at from the other direction.
        var.n8n_binary_data_mode == "filesystem" ? [
          { name = "N8N_DEFAULT_BINARY_DATA_MODE", value = "filesystem" },
          { name = "N8N_STORAGE_PATH", value = "${var.n8n_binary_data_path}/storage" },
        ] : [],

        # Split ingress only. See k8s_split_ingress_urls above for why the
        # chart cannot render these two itself and why overriding it in place
        # would break the next helm upgrade. Both are set here or neither is:
        # emptying webhook.url drops the chart's N8N_WEBHOOK_URL as well, so
        # this block has to carry it back.
        local.k8s_split_ingress_urls ? [
          { name = "N8N_WEBHOOK_URL", value = local.k8s_webhook_url },
          { name = "N8N_EDITOR_BASE_URL", value = local.k8s_editor_base_url },
        ] : [],

        # Postgres TLS. Kept as an explicit "false" rather than omitted, so the
        # rendered value states the choice instead of leaning on n8n's default:
        # this is the switch that matters when the endpoint is an in-cluster
        # pooler terminating SSL on its own upstream leg.
        # db_postgresdb_ssl_reject_unauthorized defaults to false, preserving
        # this module's original behavior: an in-cluster CNPG cluster serves a
        # cert signed by its own per-cluster CA, which Node.js has no reason
        # to trust by default, and the traffic never leaves the cluster
        # network.
        #
        # DB_POSTGRESDB_SSL_ENABLED is omitted here, not emitted "true", on the
        # one path where the chart already carries it: local.postgres_ssl_ca_active
        # (a CA is being delivered through database.ssl, see k8s_values_database)
        # on a chart known to render DB_POSTGRESDB_SSL_ENABLED from
        # database.ssl.enabled itself (local.n8n_chart_renders_postgres_ssl_enabled).
        # Carrying both would put two entries of that name in the container's
        # env list, the duplicate that fails every later helm upgrade. Every
        # other combination, including SSL on with no CA, keeps the entry here:
        # it is the only source of that name on every path but the one above.
        var.db_postgresdb_ssl_enabled ? concat(
          local.postgres_ssl_ca_active && local.n8n_chart_renders_postgres_ssl_enabled ? [] : [
            { name = "DB_POSTGRESDB_SSL_ENABLED", value = "true" },
          ],
          [
            { name = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED", value = tostring(var.db_postgresdb_ssl_reject_unauthorized) },
          ],
          ) : [
          { name = "DB_POSTGRESDB_SSL_ENABLED", value = "false" },
        ],

        # Database connection acquisition and health-check ping settings. The
        # chart has no values path for these and DB_ is a module-managed
        # prefix, so n8n_extra_env cannot reach them; each is omitted on the
        # null path, leaving n8n's own defaults.
        #
        # DB_POSTGRESDB_CONNECTION_TIMEOUT becomes pg-pool's
        # connectionTimeoutMillis, which bounds both connection establishment
        # and waiting for the shared pool to free a slot. The database monitor
        # also calls pool.connect(), so its acquisition is subject to this
        # timeout and to the separate DB_PING_TIMEOUT_MS race: the effective
        # health-check acquisition deadline is whichever fires first.
        var.db_postgresdb_connection_timeout_ms == null ? [] : [
          { name = "DB_POSTGRESDB_CONNECTION_TIMEOUT", value = tostring(var.db_postgresdb_connection_timeout_ms) },
        ],
        var.db_ping_timeout_ms == null ? [] : [
          { name = "DB_PING_TIMEOUT_MS", value = tostring(var.db_ping_timeout_ms) },
        ],
        var.db_ping_interval_seconds == null ? [] : [
          { name = "DB_PING_INTERVAL_SECONDS", value = tostring(var.db_ping_interval_seconds) },
        ],

        # Editor and package-installation policy. All plain booleans n8n reads
        # from the environment; none has a typed key in the chart.
        [
          { name = "N8N_TEMPLATES_ENABLED", value = tostring(var.n8n_templates_enabled) },
          { name = "N8N_PERSONALIZATION_ENABLED", value = tostring(var.n8n_personalization_enabled) },
          { name = "N8N_COMMUNITY_PACKAGES_PREVENT_LOADING", value = tostring(var.n8n_community_packages_prevent_loading) },
        ],

        # Gated on null rather than rendered with tostring() like the three
        # above: this is the only one of the four that defaults to null, and
        # tostring(null) is "", which n8n rejects at boot with "Invalid boolean
        # value for N8N_UNVERIFIED_PACKAGES_ENABLED:" and then ignores. The
        # variable's own description promises null omits the variable, so the
        # default was contradicting the documented contract in every deployment.
        var.n8n_unverified_packages_enabled == null ? [] : [
          { name = "N8N_UNVERIFIED_PACKAGES_ENABLED", value = tostring(var.n8n_unverified_packages_enabled) },
        ],

        # Only the request timeout belongs here. It is read by n8n itself —
        # how long the broker waits for a runner to accept a task — so the n8n
        # containers are the right place for it.
        #
        # N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT is deliberately NOT here. It is read
        # by the launcher, which runs in the separate task-runner sidecar, and
        # config.extraEnv reaches the n8n containers only. Setting it here left
        # the sidecar on the chart default no matter what the caller asked for.
        # It is set via taskRunners.launcher.autoShutdownTimeout instead — see
        # k8s_values_task_runners below.
        var.n8n_task_runners_enabled ? [
          { name = "N8N_RUNNERS_TASK_REQUEST_TIMEOUT", value = tostring(var.n8n_task_runner_request_timeout) },
        ] : [],

        # Custom-node loading. N8N_CUSTOM_EXTENSIONS names a directory n8n scans
        # at startup, which is how nodes baked into a custom image are found;
        # the check block in n8n.tf already refuses a path that no volume mount
        # or custom image provides. N8N_REINSTALL_MISSING_PACKAGES is emitted
        # only when true, because n8n's own default is false and an explicit
        # "false" would claim a decision the caller did not make.
        var.n8n_custom_extensions_path == null ? [] : [
          { name = "N8N_CUSTOM_EXTENSIONS", value = var.n8n_custom_extensions_path },
        ],
        var.n8n_reinstall_missing_packages ? [
          { name = "N8N_REINSTALL_MISSING_PACKAGES", value = "true" },
        ] : [],

        # V8 heap ceiling. A whole flag STRING rather than a single setting,
        # so the reservation in n8n_extra_env's validation only fires while
        # this is set: with it null, the module emits nothing and a caller's
        # own NODE_OPTIONS (--enable-source-maps, --inspect, their own heap
        # flag) has nothing of the module's to clobber.
        var.n8n_node_max_old_space_size_mb == null ? [] : [
          { name = "NODE_OPTIONS", value = "--max-old-space-size=${var.n8n_node_max_old_space_size_mb}" },
        ],

        # Credential overwrites. local.n8n_credentials_overwrite_env is an
        # empty list only when n8n_credentials_overwrite_secret_ref is null;
        # the volume and mount that back this file live in
        # local.n8n_extra_volumes / local.n8n_extra_volume_mounts above.
        local.n8n_credentials_overwrite_env,

        # OpenTelemetry. The master switch emits nothing when false so the SDK
        # is never loaded, and every other knob is gated behind it: setting a
        # sample rate on a deployment with tracing off would render a variable
        # n8n reads and then ignores. Each one is additionally null-gated, so
        # leaving it unset keeps n8n's own default rather than restating it.
        var.n8n_otel_enabled ? concat(
          [{ name = "N8N_OTEL_ENABLED", value = "true" }],
          var.n8n_otel_exporter_otlp_endpoint == null ? [] : [
            { name = "N8N_OTEL_EXPORTER_OTLP_ENDPOINT", value = var.n8n_otel_exporter_otlp_endpoint },
          ],
          var.n8n_otel_exporter_otlp_headers == null ? [] : [
            { name = "N8N_OTEL_EXPORTER_OTLP_HEADERS", value = var.n8n_otel_exporter_otlp_headers },
          ],
          var.n8n_otel_exporter_service_name == null ? [] : [
            { name = "N8N_OTEL_EXPORTER_SERVICE_NAME", value = var.n8n_otel_exporter_service_name },
          ],
          var.n8n_otel_traces_sample_rate == null ? [] : [
            { name = "N8N_OTEL_TRACES_SAMPLE_RATE", value = tostring(var.n8n_otel_traces_sample_rate) },
          ],
          var.n8n_otel_traces_include_node_spans == null ? [] : [
            { name = "N8N_OTEL_TRACES_INCLUDE_NODE_SPANS", value = tostring(var.n8n_otel_traces_include_node_spans) },
          ],
          var.n8n_otel_traces_inject_outbound == null ? [] : [
            { name = "N8N_OTEL_TRACES_INJECT_OUTBOUND", value = tostring(var.n8n_otel_traces_inject_outbound) },
          ],
          var.n8n_otel_traces_production_only == null ? [] : [
            { name = "N8N_OTEL_TRACES_PRODUCTION_ONLY", value = tostring(var.n8n_otel_traces_production_only) },
          ],
        ) : [],

        # Logging, lifecycle and connection-pool settings n8n reads from the
        # environment. None has a typed key in the chart.
        [
          { name = "N8N_LOG_LEVEL", value = var.n8n_log_level },
          { name = "N8N_LOG_OUTPUT", value = var.n8n_log_output },
          { name = "DB_POSTGRESDB_POOL_SIZE", value = tostring(var.db_postgresdb_pool_size) },
        ],

        # N8N_PRESTOP_SLEEP used to be emitted here, and was read by nothing.
        # The drain delay it describes is a pod lifecycle hook, not application
        # configuration: chart 1.10.0 mentions the name in no template, and n8n
        # declares no such variable (its deployment env var reference lists
        # N8N_GRACEFUL_SHUTDOWN_TIMEOUT and not this). So the value was rendered
        # into every container's environment, ignored there, and the actual
        # drain window stayed on the chart's hardcoded `sleep 10` no matter what
        # the input said. It is set through lifecycle.*.preStop.command in
        # k8s_values_lifecycle above, where it takes effect.

        # Guardrails on what a workflow can decompress. Left to n8n's own
        # defaults when null, rather than pinned to a value this module invented.
        var.n8n_compression_max_decompressed_size_bytes == null ? [] : [
          { name = "N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES", value = tostring(var.n8n_compression_max_decompressed_size_bytes) },
        ],
        var.n8n_compression_max_zip_entries == null ? [] : [
          { name = "N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES", value = tostring(var.n8n_compression_max_zip_entries) },
        ],

        # Only emitted when it differs from n8n's own default. The input accepts
        # nothing else today, so this renders empty; it stays as the seam for
        # the day an object-storage mode is wired up.
        var.n8n_execution_data_storage_mode == "database" ? [] : [
          { name = "N8N_EXECUTION_DATA_STORAGE_MODE", value = var.n8n_execution_data_storage_mode },
        ],

        var.n8n_community_packages_registry == null ? [] : [
          { name = "N8N_COMMUNITY_PACKAGES_REGISTRY", value = var.n8n_community_packages_registry },
        ],

        length(local.n8n_disabled_modules) == 0 ? [] : [
          { name = "N8N_DISABLED_MODULES", value = join(",", local.n8n_disabled_modules) },
        ],

        var.n8n_task_runners_enabled ? [
          { name = "N8N_RUNNERS_TASK_TIMEOUT", value = tostring(var.n8n_task_runner_timeout) },
        ] : [],

        # n8n's own key prefix, set alongside the chart's redis.prefix
        # (QUEUE_BULL_PREFIX) so the pub/sub command channel and Bull's job
        # keys live under one namespace. n8n's default is "n8n" and Bull's is
        # "bull", so the two env vars are different names carrying the same
        # caller value, and both are omitted when the input is null so those
        # defaults keep applying.
        var.redis_key_prefix == null ? [] : [
          { name = "N8N_REDIS_KEY_PREFIX", value = var.redis_key_prefix },
        ],

        # Declared TLS on a caller-supplied endpoint. Set through the
        # environment rather than the chart's redis.tls key: both render the
        # same QUEUE_BULL_REDIS_TLS on every pod (the chart's via its
        # ConfigMap), and staying in config.extraEnv keeps this list the one
        # place the module's own env decisions live. The QUEUE_ prefix
        # reservation blocks the name from the two env inputs; an
        # n8n_extra_helm_values overlay setting redis.tls alongside
        # redis_transit_encryption_enabled is NOT blocked, and renders the
        # name twice - the duplicate-env failure that wedges the next helm
        # upgrade. Use the module input, not the overlay, for this key.
        local.valkey_enabled || !local.redis_tls_active ? [] : [
          { name = "QUEUE_BULL_REDIS_TLS", value = "true" },
        ],

        var.n8n_metrics_enabled ? [
          { name = "N8N_METRICS", value = "true" },
          { name = "N8N_METRICS_INCLUDE_QUEUE_METRICS", value = "true" },
          { name = "N8N_METRICS_INCLUDE_CACHE_METRICS", value = "true" },
        ] : [],

        # SMTP for user-management email, only when the caller configured a
        # server. N8N_EMAIL_MODE is emitted even though "smtp" is n8n's own
        # default, so the choice survives a future n8n default change. The
        # password never appears as a value: it is a secretKeyRef into a
        # Secret the caller owns, which keeps it out of Terraform state and
        # out of the Helm release values.
        # Two concat arguments rather than one nested ternary, because the
        # plain {name, value} entries and the {name, valueFrom} password entry
        # cannot share a ternary branch: Terraform unifies the branches to one
        # object type and there is none.
        var.n8n_smtp == null ? [] : concat(
          [
            { name = "N8N_EMAIL_MODE", value = "smtp" },
            { name = "N8N_SMTP_HOST", value = var.n8n_smtp.host },
            { name = "N8N_SMTP_PORT", value = tostring(var.n8n_smtp.port) },
            { name = "N8N_SMTP_SSL", value = tostring(var.n8n_smtp.ssl) },
            { name = "N8N_SMTP_STARTTLS", value = tostring(var.n8n_smtp.starttls) },
            { name = "N8N_SMTP_SENDER", value = var.n8n_smtp.sender },
          ],
          var.n8n_smtp.user == null ? [] : [
            { name = "N8N_SMTP_USER", value = var.n8n_smtp.user },
          ],
        ),
        var.n8n_smtp == null ? [] : var.n8n_smtp.password_secret_ref == null ? [] : [
          {
            name = "N8N_SMTP_PASS"
            valueFrom = {
              secretKeyRef = {
                name = var.n8n_smtp.password_secret_ref.name
                key  = coalesce(var.n8n_smtp.password_secret_ref.key, "password")
              }
            }
          },
        ],

        # Telemetry, only when the caller took a position. Omitted at null so
        # n8n's own default (currently true) applies untouched.
        var.n8n_diagnostics_enabled == null ? [] : [
          { name = "N8N_DIAGNOSTICS_ENABLED", value = tostring(var.n8n_diagnostics_enabled) },
        ],

        # Outbound CA trust (n8n_extra_ca_pem): points Node at the bundle
        # mounted from kubernetes_secret.n8n_ca_bundle. Reaches the n8n
        # containers only; the task runner sidecar is a separate container
        # this value does not touch (see docs/tls-proxy.md).
        local.n8n_ca_bundle_env,

        # The two caller-supplied env inputs, both landing in this one list.
        # n8n_extra_env is typed list(object({name, value})), so it carries no
        # valueFrom path; n8n_extra_env_from_secret is the secretKeyRef form,
        # and the reason it is a typed input rather than a job for
        # n8n_extra_helm_values is that the overlay cannot append here. Helm
        # coalesces maps across values documents but *replaces* lists, so an
        # overlay setting config.extraEnv substitutes its own list for this
        # entire one, dropping N8N_ENCRYPTION_KEY and every connection variable
        # assembled above. The release still installs; the pods just come up
        # misconfigured.
        [
          for e in var.n8n_extra_env :
          { name = e.name, value = e.value }
        ],
        [
          for e in var.n8n_extra_env_from_secret :
          {
            name = e.name
            valueFrom = {
              secretKeyRef = {
                name = e.secret_name
                key  = e.secret_key
              }
            }
          }
        ],
      )
    }
  }

  # Execution limits, data retention and history pruning. The chart reads
  # these from the top-level `executions` block (templates/_environment-helpers.tpl,
  # "n8n.executionsEnv"); an earlier version rendered the limits under
  # config.executions as well, a key the chart never reads, so timeout,
  # timeoutMax, the concurrency limit and pruning maxCount were silently
  # dropped and only pruning enabled/maxAge ever reached the pods. The chart's
  # own gates still apply: a timeout or productionLimit of -1 emits no env var,
  # which is n8n's "disabled" spelling for both. productionLimit's default is
  # -1 for exactly that reason: n8n's worker.ts reads
  # N8N_CONCURRENCY_PRODUCTION_LIMIT before the worker's own --concurrency
  # flag (var.n8n_worker_concurrency, rendered into queueMode.workerConcurrency
  # below) and only falls back to the flag when the env var is -1. A
  # non-default value here therefore overrides every worker's configured
  # concurrency instance-wide, which is what silently capped a KEDA-scaled
  # worker pool at one number regardless of replica count before this
  # variable's default changed (live finding, see CHANGELOG).
  #
  # executions.data (saveOnError / saveOnSuccess / saveOnProgress /
  # saveManualExecutions) is rendered unconditionally by the chart whether or
  # not this block is present, so these four keys replace what would
  # otherwise be the chart's own baked-in defaults with the module's typed
  # inputs; every one of the four defaults to the same value n8n itself
  # defaults to, so a deployment that sets none of them renders unchanged.
  # The four EXECUTIONS_DATA_SAVE_* names are reserved in
  # local.n8n_managed_env_names for the same duplicate-key reason
  # the redis.worker merge above documents for QUEUE_WORKER_*.
  k8s_values_executions = {
    executions = {
      timeout     = var.n8n_execution_timeout
      timeoutMax  = var.n8n_execution_timeout_max
      concurrency = { productionLimit = var.n8n_execution_concurrency_limit }
      data = {
        saveOnError          = var.n8n_executions_data_save_on_error
        saveOnSuccess        = var.n8n_executions_data_save_on_success
        saveOnProgress       = var.n8n_executions_data_save_on_progress
        saveManualExecutions = var.n8n_executions_data_save_manual_executions
      }
      # enabled now reads var.n8n_pruning_enabled (true by default, matching
      # the hardcoded value this replaces byte-for-byte). The three cadence
      # keys default to null and are merged in only when set: the chart
      # deep-merges its own values.yaml defaults (hardDeleteBuffer 1,
      # hardDeleteInterval 15, softDeleteInterval 60) under any key this
      # module omits, so leaving them out at the default renders exactly what
      # omitting them always rendered. Reserved under
      # local.n8n_managed_env_names (EXECUTIONS_DATA_HARD_DELETE_BUFFER,
      # EXECUTIONS_DATA_PRUNE_HARD_DELETE_INTERVAL,
      # EXECUTIONS_DATA_PRUNE_SOFT_DELETE_INTERVAL) so n8n_extra_env cannot
      # duplicate whichever of them is set here.
      pruning = merge(
        {
          enabled  = var.n8n_pruning_enabled
          maxAge   = var.n8n_pruning_max_age
          maxCount = var.n8n_pruning_max_count
        },
        var.n8n_pruning_hard_delete_buffer != null ? { hardDeleteBuffer = var.n8n_pruning_hard_delete_buffer } : {},
        var.n8n_pruning_hard_delete_interval != null ? { hardDeleteInterval = var.n8n_pruning_hard_delete_interval } : {},
        var.n8n_pruning_soft_delete_interval != null ? { softDeleteInterval = var.n8n_pruning_soft_delete_interval } : {},
      )
    }
  }

  # Task runners on by default: base n8n image ships no Python, so any Code
  # node using Python fails with 500 "Python runner unavailable" without them.
  # customConfig points at the ConfigMap the module renders in
  # task_runners_config.tf, which overrides the chart's default (empty)
  # stdlib allow-list.
  k8s_values_task_runners = {
    taskRunners = merge(
      {
        enabled            = var.n8n_task_runners_enabled
        mode               = "external"
        nativePythonRunner = var.n8n_task_runner_python_enabled

        # The only key the chart reads for the sidecar container:
        # _helpers.tpl's n8n.taskRunnerContainer helper renders
        # `toYaml .Values.taskRunners.resources` into it. Nothing in the
        # chart reads a taskRunner key under the top-level resources block
        # (see k8s_values_resources above).
        resources = {
          requests = { cpu = var.n8n_task_runner_cpu_request, memory = var.n8n_task_runner_memory_request }
          limits   = { cpu = var.n8n_task_runner_cpu_limit, memory = var.n8n_task_runner_memory_limit }
        }
      },
      var.n8n_task_runners_enabled ? {
        customConfig = {
          enabled       = true
          configMapName = "${local.cnpg_release_name}-task-runners"
          configMapKey  = "n8n-task-runners.json"
        }
      } : {},

      # Idle shutdown for the runner processes. This has to be the nested
      # launcher key: the chart reads taskRunners.launcher.autoShutdownTimeout
      # (_configmap-env.tpl) and renders it into the SIDECAR's environment as
      # N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT, inside the taskRunnerSidecarEnv
      # define. It is the only key in the chart that carries this value; there
      # is no flat taskRunners.autoShutdownTimeout in 1.10.0 or 1.11.0.
      #
      # 0 disables idle shutdown entirely — the runner process the launcher
      # spawns checks `idleTimeout === 0` and skips arming its timer
      # (task-runner.js, `if (this.idleTimeout === 0) return`). That
      # trades a resident runner process against cold start, and the cold start
      # is not small: a Code node measured at ~17ms warm took ~7.4s cold.
      #
      # Kept as its own merge argument rather than folded in with customConfig
      # above. In a `cond ? {...} : {}` the two branches are unified to a common
      # type, and an object mixing this number with customConfig's strings
      # collapses to map(string) — which turns the 0 into "0" before it ever
      # reaches the chart.
      var.n8n_task_runners_enabled ? {
        launcher = { autoShutdownTimeout = var.n8n_task_runner_auto_shutdown_timeout }
      } : {},

      # The runner sidecar's tag. Omitted when null so the chart falls back to
      # the n8n application image's tag, which is right as long as that tag is a
      # published n8n version. It stops being right on a custom application
      # image, whose tag n8nio/runners has never heard of, which is why the
      # check block in n8n.tf requires this alongside n8n_image_repository.
      var.n8n_task_runners_enabled && var.n8n_task_runner_image_tag != null ? {
        image = { tag = var.n8n_task_runner_image_tag }
      } : {},
    )
  }

  # Annotations for the ingress controller the caller runs. ingress-nginx is
  # the assumed default; k8s_ingress_extra_annotations is where
  # controller-specific keys go for anything else.
  # The proxy settings are unconditional: they describe how the controller must
  # carry n8n's traffic and have nothing to do with TLS. They were nested inside
  # the cluster-issuer branch, so bringing your own certificate, or serving
  # without one, as on a local cluster where no ACME issuer can validate the
  # name, silently dropped all three. nginx then applies its own 1m body limit
  # and 60s timeouts, which fails binary-data uploads with 413 and cuts
  # long-running executions off mid-request, neither of which points at TLS.
  #
  # n8n_payload_size_max null (its default) leaves this at the literal 32m it
  # has always been, matching n8n's own 16 MiB default unset; setting the
  # input derives both this annotation and N8N_PAYLOAD_SIZE_MAX (above) from
  # the same value, plus 2 MiB of multipart-framing headroom, so the proxy's
  # limit and n8n's limit cannot disagree. Also exported as the
  # ingress_proxy_body_size output for create_ingress = false callers to put
  # on their own Ingress instead of a literal that can drift.
  ingress_proxy_body_size = var.n8n_payload_size_max == null ? "32m" : "${var.n8n_payload_size_max + 2}m"

  k8s_ingress_annotations = merge(
    {
      "nginx.ingress.kubernetes.io/proxy-body-size"    = local.ingress_proxy_body_size
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600"
      "nginx.ingress.kubernetes.io/proxy-send-timeout" = "3600"
    },
    length(var.k8s_ingress_cluster_issuer) > 0 ? {
      "cert-manager.io/cluster-issuer" = var.k8s_ingress_cluster_issuer
    } : {},
    var.k8s_ingress_extra_annotations,
  )

  # Lowercased on both branches. k8s_ingress_host and n8n_domain's own
  # validations both accept uppercase, but this value derives the TLS Secret
  # name below (a Kubernetes object name, lowercase-only) and feeds the
  # editor/webhook URL fallbacks above, so every consumer now inherits one
  # normalized value instead of each needing its own lower() call.
  k8s_ingress_host_effective = length(var.k8s_ingress_host) > 0 ? lower(var.k8s_ingress_host) : local.n8n_domain
  k8s_ingress_tls_secret     = length(var.k8s_ingress_tls_secret_name) > 0 ? var.k8s_ingress_tls_secret_name : replace("${local.k8s_ingress_host_effective}-tls", ".", "-")

  # Every hostname the Ingresses answer on, canonical first. Normalized once
  # here so the editor Ingress, the chart's webhook Ingress and the TLS secret
  # cannot disagree about the host list.
  #
  # Lowercased, because Kubernetes rejects an uppercase Ingress host outright
  # and cert-manager names the Certificate's SANs from these.
  # k8s_ingress_host_effective is already normalized at its own definition
  # above, so only n8n_additional_domains needs its own lower() call here.
  # distinct() covers the one duplicate neither variable's validation can
  # catch: an entry in n8n_additional_domains that differs from
  # k8s_ingress_host only in case, or matches k8s_ingress_host rather than
  # n8n_domain.
  #
  # n8n_domain (or k8s_ingress_host when set) stays first and canonical: it is
  # what n8n advertises as N8N_HOST and in webhook URLs. The additional names
  # route to the same Services; nothing about them changes what n8n hands out.
  k8s_ingress_hosts = distinct(concat(
    [local.k8s_ingress_host_effective],
    [for d in var.n8n_additional_domains : lower(d)],
  ))

  # The chart's webhook Ingress (templates/ingress-webhook.yaml) takes only
  # enabled/className/annotations/tls: it hardcodes the webhook path prefixes
  # itself and ranges over .Values.ingress.hosts for the host list, so every
  # name added above is routed on both Ingresses without a second host list
  # here. An earlier version of this block passed `hosts` and `paths` keys:
  # the chart ignores both, which is why only /webhook was ever routed despite
  # the block naming it.
  #
  # It hardcoded four of the five through chart 1.10.0, omitting /mcp.
  # Confirmed against chart 1.10.0 on a live deployment: /webhook/x returns
  # n8n's JSON 404 while /mcp/x returns 200 text/html, the editor SPA
  # answering because the main pods have no handler registered for it. That
  # was the silent failure docs/troubleshooting.md used to document, and MCP
  # Server Trigger nodes hit it on the module's default path. Chart 1.16.0
  # added /mcp/ to this same template, so all five prefixes are chart-routed
  # now; see n8n_webhook_path_prefixes and the now-removed supplementary
  # Ingress this module used to render to cover the gap.
  #
  # Gated on create_ingress alongside the main Ingress: ungated, a caller
  # bringing their own routing still got a chart-owned webhook Ingress with an
  # empty rule set (ingress.hosts is [] on that path).
  k8s_webhook_ingress_block = {
    enabled     = var.create_ingress
    className   = var.k8s_ingress_class_name
    annotations = local.k8s_ingress_annotations
    tls = var.create_ingress ? [
      {
        hosts      = local.k8s_ingress_hosts
        secretName = local.k8s_ingress_tls_secret
      }
    ] : []
  }

  # Rendered as one shape either way, Terraform's ternary type check requires
  # the two branches to be the same object type. `enabled = false` gates the
  # chart's Ingress off; the rest of the fields are ignored on that path.
  #
  # One TLS secret covers every host: cert-manager issues a single Certificate
  # with the other names as subject alternative names. The module does not
  # inspect the issued certificate's SAN set, an issuer that refuses one of the
  # names (a DNS-01 solver scoped to a single zone, say) fails at the
  # Certificate, not here.
  k8s_values_ingress = {
    ingress = {
      enabled     = var.create_ingress
      className   = var.k8s_ingress_class_name
      annotations = local.k8s_ingress_annotations
      hosts = var.create_ingress ? [
        for host in local.k8s_ingress_hosts : {
          host  = host
          paths = [{ path = "/", pathType = "Prefix" }]
        }
      ] : []
      tls = var.create_ingress ? [
        {
          hosts      = local.k8s_ingress_hosts
          secretName = local.k8s_ingress_tls_secret
        }
      ] : []

      # Session affinity, which the chart renders as nginx cookie annotations.
      # Off: there is one main pod, so there is nothing to be sticky to.
      sticky = {
        enabled = false
      }

      webhookProcessor = local.k8s_webhook_ingress_block
    }
  }

  # The other half of the ServiceAccount takeover described at
  # n8n_manages_service_account above. Both keys were hardcoded here
  # (create = true, name = "n8n") while that local and the ServiceAccount
  # resource in n8n.tf did all the work of deciding otherwise, so setting
  # n8n_image_pull_secrets created an account the chart's helper never named
  # and no pod ever ran as. The registry credentials were attached to an object
  # nothing used, and a private n8n_image_repository failed as ImagePullBackOff
  # inside an atomic release that then rolled back with nothing naming the
  # cause.
  #
  # With the default empty pull-secret list this renders exactly what it
  # rendered before (create = true, name = "n8n"), so nothing moves for a
  # deployment that does not use the input. The chart gates its own
  # ServiceAccount on create, and its Role and RoleBinding on rbac.create
  # instead, so handing the account over keeps the RBAC and re-points the
  # binding's subject at the module's account by name.
  k8s_values_service_account = {
    serviceAccount = {
      create = !local.n8n_manages_service_account
      name   = local.n8n_service_account_name
    }
  }

  # ── KEDA: queue-depth worker autoscaling ───────────────────────────────────
  # Two triggers: bull:jobs:wait for queued work, bull:jobs:active for jobs held
  # by a worker waiting on a task runner. KEDA takes the max. The address resolves to
  # the in-cluster Valkey Service or a caller-supplied external endpoint through
  # the same canonical locals the workload reads, so the scaling client and the
  # execution client cannot drift apart.
  #
  # Confirmed live against an external Valkey on a non-default port with
  # password auth: the rendered trigger address follows redis_port, no
  # enableTLS key appears when transit encryption is off, passwordFromEnv
  # names an env var that really exists on the worker container, the
  # ScaledObject reports Ready with real queue-depth numbers even at rest,
  # and a burst of queued webhooks scaled the workers from their floor of 1
  # to the configured max of 3.
  #
  # No TriggerAuthentication resource is needed here: the chart already
  # exposes keda.worker.triggers, so passwordFromEnv resolves the AUTH token from
  # QUEUE_BULL_REDIS_PASSWORD on the worker pod that the chart already sets. The
  # token never enters the ScaledObject manifest and there is no second Secret to
  # keep in sync.
  #
  # cooldownPeriod below only governs scale-to-zero, the delay KEDA waits
  # after the last trigger goes idle before it would remove the final
  # replica. This module never reaches that path: n8n_worker_keda_min_replicas
  # is validated >= 1, so the worker Deployment and its ScaledObject always
  # keep at least one replica, and cooldownPeriod never fires. The effective
  # scale-down delay a caller actually observes is Kubernetes' own default HPA
  # scaleDown stabilization window, 300s, which KEDA's ScaledObject inherits
  # for every scale-down step above the floor; measured live at ~298s. Chart
  # 1.17.0 exposes no values path to the ScaledObject's spec.advanced, so that
  # window cannot be shortened from this module (confirmed: keda.worker.advanced
  # renders no spec.advanced key through `helm template`), so it is left at the
  # default.
  k8s_values_keda = var.k8s_keda_installed ? {
    keda = {
      enabled = true
      worker = {
        pollingInterval = 15
        cooldownPeriod  = 60
        minReplicaCount = var.n8n_worker_keda_min_replicas
        maxReplicaCount = var.n8n_worker_keda_max_replicas
        triggers = [
          for list_name in ["jobs:wait", "jobs:active"] : {
            type = "redis"
            metadata = merge(
              {
                # The same resolved host and port n8n itself connects on. The
                # port was once hardcoded to 6379, which is only ever right for
                # the in-cluster Valkey Service: an external endpoint on any
                # other port had n8n consuming one address and KEDA scaling on
                # another that answers nothing.
                address    = "${local.k8s_redis_host}:${local.k8s_redis_port}"
                listName   = "${local.redis_key_prefix_value}:${list_name}"
                listLength = tostring(var.n8n_worker_keda_jobs_per_replica)
              },
              # Mirror of the QUEUE_BULL_REDIS_TLS gate in config.extraEnv: the
              # scaler and the workload have to agree about the endpoint or the
              # scaler dials a TLS listener in plaintext and reads nothing.
              local.valkey_enabled || !local.redis_tls_active ? {} : {
                enableTLS = "true"
              },
              # Only when a token exists. passwordFromEnv names an env var KEDA
              # resolves against the scale target's first container, which is
              # the worker n8n container carrying QUEUE_BULL_REDIS_PASSWORD via
              # secretKeyRef - but only when redis.passwordSecret is rendered.
              # Unconditional (the old gate compared a never-null local against
              # null), it named a variable that does not exist on the no-auth
              # path, and the scaler then authenticated with an empty password
              # against a server expecting none.
              local.valkey_enabled || local.redis_auth_active ? {
                passwordFromEnv = "QUEUE_BULL_REDIS_PASSWORD"
              } : {},
              # A literal, matching how the chart carries it to n8n: the
              # username is not a credential, and the scaler accepts it in
              # triggerMetadata directly. Without it, an ACL-authenticated
              # endpoint had n8n connecting as the named user and KEDA as
              # `default`, which usually cannot LLEN the bull lists, so the
              # scaler reported unknown and the worker count froze.
              local.valkey_enabled || local.redis_username_value == null ? {} : {
                username = local.redis_username_value
              },
            )
            # No authenticationRef: passwordFromEnv above resolves the
            # token from the worker container directly, so there is no
            # TriggerAuthentication object to name. A name = "" key was
            # rendered here before; KEDA tolerates it today, but an object
            # naming a TriggerAuthentication that cannot exist is the kind
            # of thing a future KEDA version could start validating against.
          }
        ]
      }
    }
  } : {}

  k8s_values_final = merge(
    local.k8s_values_image,
    local.k8s_values_secret_refs,
    local.k8s_values_queue_mode,
    local.k8s_values_replicas,
    local.k8s_values_webhook_processor,
    local.k8s_values_database,
    local.k8s_values_redis,
    local.k8s_values_webhook,
    local.k8s_values_s3_off,
    local.k8s_values_hpa,
    local.k8s_values_pdb,
    local.k8s_values_strategy,
    local.k8s_values_lifecycle,
    local.k8s_values_network_policy,
    local.k8s_values_keda,
    local.k8s_values_resources,
    local.k8s_values_volumes,
    local.k8s_values_pod_annotations,
    local.k8s_values_containers,
    local.k8s_values_config,
    local.k8s_values_executions,
    local.k8s_values_task_runners,
    local.k8s_values_ingress,
    local.k8s_values_service_account,
    local.k8s_values_dns,
  )
}
