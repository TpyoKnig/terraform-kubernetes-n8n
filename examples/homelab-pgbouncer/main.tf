# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

module "n8n" {
  source = "../.."

  # ── Backing services ───────────────────────────────────────────────────────
  # CNPG for Postgres, Valkey for Redis, ingress-nginx for the Ingress, and the
  # cluster's default StorageClass for the PVCs. Each is a slot, see the README
  # table for what swaps them.
  postgres_backend = "cnpg"
  redis_backend    = "valkey"
  create_ingress   = true
  # Always false: this example owns the namespace, so that turning shared
  # storage on later cannot move it between two resource addresses mid-apply.
  # See storage.tf for what that used to cost.
  create_namespace = false

  # The hostname the Ingress serves and n8n advertises itself as. The module
  # creates no DNS record for it.
  n8n_domain = var.ui_host

  # Set true when KEDA is already running cluster-wide and workers should scale
  # on Redis queue depth instead of CPU. Off by default because the module does
  # not install KEDA on this backend, and a ScaledObject with no operator behind
  # it silently pins workers at their floor rather than failing.
  k8s_keda_installed = var.keda_installed


  # Reference the namespace resource rather than var.namespace, so every
  # namespaced resource inside the module inherits an edge to it. Without this
  # the module waits only for the claim, and only for the Helm release that
  # mounts it: the Secrets, the CNPG Cluster and the Valkey release have no path
  # to the namespace at all and a first apply can fail with `namespaces "n8n"
  # not found`. Deploying in two steps hides it, which is why it survived a live
  # apply.
  #
  # A module-level depends_on would also fix it and costs more: it defers
  # everything inside, including the node lookup the capacity check reads, so a
  # plan-time diagnostic becomes an apply-time one. The name here stays known
  # at plan because it is a configured attribute, so this buys the edge without
  # making the namespace unknown.
  k8s_namespace = kubernetes_namespace.n8n.metadata[0].name

  # ── k8s-backend Postgres / Redis / Ingress ─────────────────────────────────
  cnpg_instances     = 1
  cnpg_storage_size  = "10Gi"
  cnpg_storage_class = var.storage_class

  valkey_storage_size  = "8Gi"
  valkey_storage_class = var.storage_class

  # ── PgBouncer, which is the point of this example ──────────────────────────
  # Everything above is the base homelab example unchanged. The four inputs
  # below are the entire difference, and they exist because pod count, not CPU,
  # is what bounds a queue-mode n8n first.
  #
  # Each n8n pod holds db_postgresdb_pool_size persistent Postgres connections.
  # That number is multiplied by a pod count an autoscaler owns, and the CNPG
  # Cluster this module creates runs max_connections = 200. A worker tier
  # scaling to 16 beside a webhook-processor tier scaling to 8, at the default
  # pool size of 10, asks for 250 against roughly 197 usable. Past the limit new
  # pods do not slow down, they fail to initialise their pool, exit non-zero and
  # CrashLoop, and requests already in flight stall until something gives.
  #
  # The pooler makes pod count stop mattering: pods connect to PgBouncer, and
  # Postgres only ever sees cnpg_pooler_pool_size x cnpg_pooler_instances.
  cnpg_pooler_enabled = true

  # 25 x 2 instances = 50 real connections, whatever the tiers do above them.
  cnpg_pooler_instances = 2
  cnpg_pooler_pool_size = 25

  # Client slots are cheap; server connections are not. Keep this far above
  # pods x db_postgresdb_pool_size, because exhausting it recreates the queue
  # this example exists to remove, one hop closer to the caller.
  cnpg_pooler_max_client_conn = 500

  # 5, not the module default of 10. These are connections to PgBouncer rather
  # than to Postgres, so they are cheap, and the real backend count is set by
  # cnpg_pooler_pool_size instead.
  db_postgresdb_pool_size = 5

  # Required with a pooler, and the module refuses the combination otherwise.
  # PgBouncer serves its clients in plaintext and encrypts its own leg to
  # Postgres, so leaving this true has n8n negotiate TLS against a listener
  # that does not speak it.
  db_postgresdb_ssl_enabled = false

  k8s_ingress_class_name     = "nginx"
  k8s_ingress_host           = var.ui_host
  k8s_ingress_cluster_issuer = var.cluster_issuer

  n8n_timezone = "America/New_York"

  # Both LoadBalancer Services below are off unless you name an address for
  # them. They exist for tooling that lives outside the cluster: a Grafana that
  # queries n8n's execution tables directly, a Prometheus that cannot use
  # in-cluster service discovery. Neither has anything authenticating in front
  # of it, so a trusted network is the assumption.
  cnpg_lan_expose = {
    enabled      = var.postgres_lan_ip != null
    ip           = var.postgres_lan_ip != null ? var.postgres_lan_ip : ""
    service_name = "n8n-pg-lan"
  }

  metrics_lan_expose = {
    enabled      = var.metrics_lan_ip != null
    ip           = var.metrics_lan_ip != null ? var.metrics_lan_ip : ""
    service_name = "n8n-main-metrics-lan"
  }

  # Task runners on so Python Code nodes work (adds n8nio/runners sidecar to
  # main + worker pods; base n8n image ships no Python).
  n8n_task_runners_enabled = true

  # Observability: emit metrics + traces to an in-cluster Alloy / OTel
  # collector. Change service_name if you run multiple n8n instances so they
  # separate in Grafana.
  n8n_metrics_enabled             = true
  n8n_otel_enabled                = true
  n8n_otel_exporter_otlp_endpoint = "http://alloy-otlp.monitoring.svc.cluster.local:4318"
  n8n_otel_exporter_service_name  = var.namespace
  n8n_otel_traces_sample_rate     = "1.0"
  n8n_otel_traces_production_only = false

  # n8n's AI Assistant and Agents modules are a good fit for a lab, but they
  # need an Anthropic API key and a sandbox credential, which means a Secret
  # this example does not create. Left commented so the example applies into an
  # empty namespace unchanged; create the Secret first, then add these.
  #
  #   kubectl create secret generic ai-assistant-secrets \
  #     --from-literal=anthropic-api-key=... \
  #     --from-literal=sandbox-api-key=...
  #
  # n8n_extra_env is unset in this example, so this goes in whole, brackets
  # included, rather than as loose entries to paste somewhere:
  #
  #   n8n_extra_env = [
  #     { name = "N8N_ENABLED_MODULES", value = "instance-ai,agents" },
  #     { name = "N8N_INSTANCE_AI_SANDBOX_ENABLED", value = "true" },
  #     { name = "N8N_INSTANCE_AI_SANDBOX_PROVIDER", value = "n8n-sandbox" },
  #     { name = "N8N_SANDBOX_SERVICE_URL", value = "http://sandbox-api.n8n-sandbox.svc.cluster.local:8080" },
  #   ]
  #
  # n8n_extra_env is typed list(object({ name, value })) with no valueFrom
  # shape, so secret-backed variables go through n8n_extra_env_from_secret,
  # which renders the secretKeyRef for you and keeps the value out of state:
  #
  # n8n_extra_env_from_secret = [{
  #   name        = "N8N_INSTANCE_AI_MODEL_API_KEY"
  #   secret_name = "ai-assistant-secrets"
  #   secret_key  = "anthropic-api-key"
  # }]
  #
  # Not n8n_extra_helm_values. That sets config.extraEnv wholesale, and the
  # module renders its own entries into the same list, so a hand-written block
  # there replaces them: shared storage, metrics and the connection settings
  # all disappear, and nothing reports it.

  # ── Shared storage ─────────────────────────────────────────────────────────
  # Reaches main, worker and webhook-processor alike, which is exactly what the
  # chart's own persistence does not do. All three are empty unless
  # shared_storage_class is set. See storage.tf.
  n8n_extra_volumes = var.shared_storage_class != null ? [{
    name                    = "shared"
    persistent_volume_claim = { claim_name = kubernetes_persistent_volume_claim_v1.shared[0].metadata[0].name }
  }] : []

  n8n_extra_volume_mounts = var.shared_storage_class != null ? [{
    name       = "shared"
    mount_path = var.shared_mount_path
    read_only  = false
  }] : []

  # The mount alone does nothing. n8n defaults binary data to filesystem in
  # regular mode but to database in scaling mode, and this module always runs
  # queue mode, so without the mode below every payload still goes to Postgres
  # while the volume sits there empty and nothing reports a problem.
  #
  # These two used to be hand-written N8N_DEFAULT_BINARY_DATA_MODE and
  # N8N_STORAGE_PATH entries in n8n_extra_env. The module owns them now, and it
  # refuses filesystem mode unless a writable mount covers the path, which is
  # the check that turns the silent version of this mistake into a plan error.
  n8n_binary_data_mode = var.shared_storage_class != null ? "filesystem" : "database"
  # Only meaningful in filesystem mode, but validated either way, and this
  # example's own shared_mount_path check is laxer than the module's. Fall back
  # to the module default when shared storage is off, so a path that is only
  # ever unused cannot fail the plan.
  n8n_binary_data_path = var.shared_storage_class != null ? var.shared_mount_path : "/opt/n8n-shared"

  # No depends_on here on purpose. n8n_extra_volumes already references the
  # claim, which is the ordering edge: Terraform cannot create the release until
  # the claim exists, and the claim cannot exist until the namespace does. An
  # explicit depends_on would add nothing and cost something, because it defers
  # everything inside the module, including the node lookup the capacity check
  # reads, turning a plan-time diagnostic into an apply-time one.

}
