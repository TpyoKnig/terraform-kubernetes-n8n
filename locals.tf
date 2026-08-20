# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Locals ────────────────────────────────────────────────────────────────────
# Shared values derived from inputs: input aliases, the labels every resource
# merges in, and the Helm values tree the n8n release renders from.

locals {
  n8n_domain = var.n8n_domain

  # A plain alias, not normalized here: the hostname list the Ingresses use is
  # assembled and lowercased at k8s_ingress_hosts further down. This value is
  # what n8n advertises as N8N_HOST, verbatim.

  # Service coordinates the Helm chart creates. Named here so the outputs a
  # bring-your-own Ingress consumes cannot drift from what the chart renders.
  n8n_service_name         = "n8n-main"
  n8n_webhook_service_name = "n8n-webhook-processor"
  n8n_service_port         = 5678

  # Path prefixes that must reach the webhook processors rather than the main
  # pods. The main pods run with production webhooks disabled, so every one of
  # these 404s if it reaches them.
  n8n_webhook_path_prefixes = [
    "/webhook",
    "/webhook-waiting",
    "/form",
    "/form-waiting",
    "/mcp",
  ]

  # Of those, the ones the chart's own webhook Ingress renders. The remainder
  # is what this module has to route itself when create_ingress = true. Derived
  # by subtraction rather than written out, so adding a prefix above needs no
  # second edit here, and a chart that starts rendering /mcp needs only this
  # list extended for the extra Ingress to disappear on its own.
  n8n_chart_routed_webhook_prefixes = [
    "/webhook",
    "/webhook-waiting",
    "/form",
    "/form-waiting",
  ]

  n8n_unrouted_webhook_prefixes = setsubtract(
    local.n8n_webhook_path_prefixes,
    local.n8n_chart_routed_webhook_prefixes,
  )

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
  n8n_extra_volumes = [
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
  ]

  n8n_extra_volume_mounts = [
    for mount in var.n8n_extra_volume_mounts : merge(
      {
        name      = mount.name
        mountPath = mount.mount_path
        readOnly  = mount.read_only
      },
      mount.sub_path == null ? {} : { subPath = mount.sub_path },
    )
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
  n8n_managed_env_names = [
    # Set by the module in config.extraEnv or the n8n secret.
    "N8N_ENCRYPTION_KEY",
    "N8N_LOG_LEVEL",
    "N8N_LOG_OUTPUT",
    "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS",
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
    "WEBHOOK_URL",
    # Owned by n8n_proxy_hops, which renders it on every path. Unreserved, the
    # module wrote it whenever create_ingress was true while n8n_extra_env
    # would still accept a second entry of the same name, and two entries in
    # one env list is the duplicate that wedges the next helm upgrade.
    "N8N_PROXY_HOPS",
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
    "N8N_DISABLED_MODULES",
    "N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL",
  ]

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
  # apply (docker.n8n.io/n8nio/n8n at the floating `stable` tag). Setting
  # repository is the supported path for an image with community nodes baked
  # in; the check block in n8n.tf refuses it without an explicit tag, because a
  # custom repository almost never publishes a tag called `stable`.
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
  # while the Secret the caller actually wrote was never read.
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

  # Same split as k8s_values_redis below. On the cnpg path the operator owns the
  # endpoint: its rw Service listens on 5432 and initdb creates the database and
  # owner from the cnpg_* inputs. On the external path all three belong to the
  # caller, and reading them from the cnpg_* inputs, documented "Only used when
  # postgres_backend = cnpg", meant an external Postgres had to be n8n/n8n on
  # 5432 or it could not be reached at all.
  k8s_values_database = {
    database = {
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

      # No `ssl` key, deliberately. Postgres TLS is set through
      # config.extraEnv in this file (DB_POSTGRESDB_SSL_ENABLED and
      # DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED, from db_postgresdb_ssl_enabled)
      # and the chart's key must not also be set, for two independent reasons.
      #
      # It does not do what its name suggests. `database.ssl.enabled` renders
      # DB_POSTGRESDB_SSL (chart 1.10.0, templates/configmap.yaml:26, and still
      # on n8n-hosting main), and that variable does not exist in n8n. The
      # product declares its database TLS inputs in
      # packages/@n8n/config/src/configs/database.config.ts as
      # DB_POSTGRESDB_SSL_ENABLED, _CA, _CERT, _KEY and _REJECT_UNAUTHORIZED, # verified against n8n 2.35.0, and reads nothing named DB_POSTGRESDB_SSL.
      # Setting the chart key would look like enabling TLS and change nothing
      # the product reads. Worth reporting upstream; until it is fixed, this
      # module cannot use that key at all.
      #
      # And its second effect does collide. With `rejectUnauthorized = false`
      # the chart renders DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED itself, which
      # this module already emits, a duplicate name in the container's env,
      # which Kubernetes rejects on every later patch. That is the failure that
      # once broke every helm upgrade, and its rollback with it.
      #
      # The block that used to sit here set enabled = false and
      # rejectUnauthorized = true: a verbatim restatement of the chart's own
      # defaults, so removing it changes nothing rendered, and leaves one place
      # describing TLS instead of two that disagreed.
    }
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
        worker = {
          timeout = var.n8n_termination_grace_period
        }
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
  # WEBHOOK_URL is the address n8n hands out for callers to POST to. Left
  # unset, n8n builds it from N8N_PROTOCOL + N8N_HOST, and N8N_PROTOCOL is
  # "http" here because TLS terminates at the ingress rather than in the pod --
  # so every advertised webhook URL would be http:// against an https://
  # endpoint. It also has to be settable independently for a split ingress,
  # where webhooks are advertised on a different hostname from the editor.
  #
  # Set through the chart's webhook.url rather than appended to
  # config.extraEnv. The chart renders WEBHOOK_URL into its own ConfigMap and
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

  # chart 1.10.0 configmap.yaml derives N8N_EDITOR_BASE_URL from the first
  # ingress host, and failing that from webhook.url, on the stated assumption
  # that "webhook.url is the domain". That holds for a single host and breaks
  # for a split one: with create_ingress = false the chart has no ingress host
  # to read, so it labels the editor with the webhook hostname.
  #
  # Nothing warns. The editor still loads, because it is reached through the
  # caller's own Ingress on the right host. What breaks is every absolute URL
  # n8n builds from UrlService.getInstanceBaseUrl(), which prefers
  # N8N_EDITOR_BASE_URL over WEBHOOK_URL -- above all the OAuth2 redirect URI,
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
  # Both accepted values render zero overlap. RollingUpdate carries the
  # explicit maxSurge = 0 that makes it so; without that key it is the default
  # above wearing a different name.
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
  # The chart defaults pdb.enabled to true with minAvailable = 1, and renders
  # the object over the main Deployment only (templates/pdb.yaml selects
  # component: main). Against this module's replicaCount = 1 that is
  # allowedDisruptions = 0 forever: no voluntary eviction of the main pod ever
  # succeeds, so draining the node it landed on blocks indefinitely and a Talos
  # node upgrade stalls behind it.
  #
  # A PDB is how you say "keep N of these up while I take a node away". With
  # one replica there is no N to keep, so the object cannot protect anything
  # and can only refuse. Off by default, and the check block in n8n.tf says so
  # at plan time for anyone who turns it back on.
  # Whether the escape hatch turns the PDB back on behind the typed input's
  # back. n8n_extra_helm_values is a YAML string merged after
  # local.k8s_values_final, and Helm gives the later values file precedence,
  # so this is the second way to end up with the object the check warns about.
  # try() covers the empty default, a value that is not a mapping, and a
  # mapping with no pdb key, all of which mean "not enabled here".
  n8n_pdb_enabled_via_extra_values = try(yamldecode(var.n8n_extra_helm_values).pdb.enabled, false) == true

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
  # out of k8s_values_final, which carries the database and Redis passwords and
  # is sensitive as a whole: an error_message built from it would be suppressed
  # in full, printing nothing where the port belongs. These expressions are the
  # same ones k8s_values_database and k8s_values_redis use.
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

  # Whether a PodDisruptionBudget ends up in the release at all, by either
  # route. Named because the check block asks exactly this question, and a
  # check reading `!a && !b` makes the reader reconstruct what the two halves
  # add up to.
  n8n_main_pdb_rendered = var.n8n_main_pdb_enabled || local.n8n_pdb_enabled_via_extra_values

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
      taskRunner = {
        requests = { cpu = var.n8n_task_runner_cpu_request, memory = var.n8n_task_runner_memory_request }
        limits   = { cpu = var.n8n_task_runner_cpu_limit, memory = var.n8n_task_runner_memory_limit }
      }
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
        # emptying webhook.url drops the chart's WEBHOOK_URL as well, so this
        # block has to carry it back.
        local.k8s_split_ingress_urls ? [
          { name = "WEBHOOK_URL", value = local.k8s_webhook_url },
          { name = "N8N_EDITOR_BASE_URL", value = local.k8s_editor_base_url },
        ] : [],

        # Postgres TLS. Kept as an explicit "false" rather than omitted, so the
        # rendered value states the choice instead of leaning on n8n's default:
        # this is the switch that matters when the endpoint is an in-cluster
        # pooler terminating SSL on its own upstream leg. REJECT_UNAUTHORIZED is
        # false alongside it because an in-cluster CNPG cluster serves a
        # cert Node.js has no reason to trust, and the traffic never leaves the
        # cluster network.
        var.db_postgresdb_ssl_enabled ? [
          { name = "DB_POSTGRESDB_SSL_ENABLED", value = "true" },
          { name = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED", value = "false" },
          ] : [
          { name = "DB_POSTGRESDB_SSL_ENABLED", value = "false" },
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
          { name = "N8N_COMPRESSION_MAX_DECOMPRESSED_SIZE", value = tostring(var.n8n_compression_max_decompressed_size_bytes) },
        ],
        var.n8n_compression_max_zip_entries == null ? [] : [
          { name = "N8N_COMPRESSION_MAX_ZIP_ENTRIES", value = tostring(var.n8n_compression_max_zip_entries) },
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

  # Execution limits and history pruning. The chart reads these from the
  # top-level `executions` block (templates/_environment-helpers.tpl,
  # "n8n.executionsEnv"); an earlier version rendered them under
  # config.executions as well, a key the chart never reads, so timeout,
  # timeoutMax, the concurrency limit and pruning maxCount were silently
  # dropped and only pruning enabled/maxAge ever reached the pods. The chart's
  # own gates still apply: a timeout or productionLimit of -1 emits no env var,
  # which is n8n's "disabled" spelling for both.
  k8s_values_executions = {
    executions = {
      timeout     = var.n8n_execution_timeout
      timeoutMax  = var.n8n_execution_timeout_max
      concurrency = { productionLimit = var.n8n_execution_concurrency_limit }
      pruning = {
        enabled  = true
        maxAge   = var.n8n_pruning_max_age
        maxCount = var.n8n_pruning_max_count
      }
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
  k8s_ingress_annotations = merge(
    {
      "nginx.ingress.kubernetes.io/proxy-body-size"    = "32m"
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600"
      "nginx.ingress.kubernetes.io/proxy-send-timeout" = "3600"
    },
    length(var.k8s_ingress_cluster_issuer) > 0 ? {
      "cert-manager.io/cluster-issuer" = var.k8s_ingress_cluster_issuer
    } : {},
    var.k8s_ingress_extra_annotations,
  )

  k8s_ingress_host_effective = length(var.k8s_ingress_host) > 0 ? var.k8s_ingress_host : var.n8n_domain
  k8s_ingress_tls_secret     = length(var.k8s_ingress_tls_secret_name) > 0 ? var.k8s_ingress_tls_secret_name : replace("${local.k8s_ingress_host_effective}-tls", ".", "-")

  # Every hostname the Ingresses answer on, canonical first. Normalized once
  # here so the editor Ingress, the chart's webhook Ingress and the TLS secret
  # cannot disagree about the host list.
  #
  # Lowercased because Kubernetes rejects an uppercase Ingress host outright,
  # and cert-manager names the Certificate's SANs from these. distinct() covers
  # the one duplicate the variable's own validation cannot catch: an entry in
  # n8n_additional_domains that differs from k8s_ingress_host only in case, or
  # matches k8s_ingress_host rather than n8n_domain.
  #
  # n8n_domain (or k8s_ingress_host when set) stays first and canonical: it is
  # what n8n advertises as N8N_HOST and in webhook URLs. The additional names
  # route to the same Services; nothing about them changes what n8n hands out.
  k8s_ingress_hosts = distinct(concat(
    [lower(local.k8s_ingress_host_effective)],
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
  # It hardcodes FOUR of the five, omitting /mcp. Confirmed against chart
  # 1.10.0 on a live deployment: /webhook/x returns n8n's JSON 404 while
  # /mcp/x returns 200 text/html, the editor SPA answering because the main
  # pods have no handler registered for it. That is the silent failure in
  # docs/troubleshooting.md, and MCP Server Trigger nodes hit it on the
  # module's default path. kubernetes_ingress_v1.n8n_mcp closes it.
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
  # No TriggerAuthentication resource is needed here: the chart already
  # exposes keda.worker.triggers, so passwordFromEnv resolves the AUTH token from
  # QUEUE_BULL_REDIS_PASSWORD on the worker pod that the chart already sets. The
  # token never enters the ScaledObject manifest and there is no second Secret to
  # keep in sync.
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
            authenticationRef = { name = "" }
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
    local.k8s_values_containers,
    local.k8s_values_config,
    local.k8s_values_executions,
    local.k8s_values_task_runners,
    local.k8s_values_ingress,
    local.k8s_values_service_account,
  )
}
