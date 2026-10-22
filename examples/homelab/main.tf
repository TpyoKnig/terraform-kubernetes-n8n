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

  k8s_ingress_class_name     = "nginx"
  k8s_ingress_host           = var.ui_host
  k8s_ingress_cluster_issuer = var.cluster_issuer

  n8n_timezone = "America/New_York"

  # No backup, acknowledged rather than left to warn on every plan. A homelab
  # example is the case the acknowledgement exists for: the database's only
  # copy is its PVC, that is the documented shape here, and docs/operations.md
  # covers adding continuous archiving when it stops being acceptable.
  cnpg_backup_acknowledged = false

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

  # Observability: /metrics is always on, because it is scraped rather than
  # pushed and so needs no collector; an in-cluster Prometheus or Alloy picks
  # it up as is. OTLP tracing defaults to this lab's own collector via
  # otel_endpoint; point it elsewhere, or set it to null to turn tracing off,
  # without touching anything else. The tuning inputs are gated on the same
  # condition because the module rejects OTel tuning while the master switch
  # is off. Change service_name if you run multiple n8n instances so they
  # separate in Grafana.
  n8n_metrics_enabled             = true
  n8n_otel_enabled                = var.otel_endpoint != null
  n8n_otel_exporter_otlp_endpoint = var.otel_endpoint
  n8n_otel_exporter_service_name  = var.otel_endpoint != null ? var.namespace : null
  n8n_otel_traces_sample_rate     = var.otel_endpoint != null ? "1.0" : null
  n8n_otel_traces_production_only = var.otel_endpoint != null ? false : null

  # n8n's AI Assistant and Agents modules are not wired up here. They need an
  # Anthropic API key and a sandbox credential, so a Secret this example does
  # not create, and the inputs that carry them are easy to get subtly wrong.
  # Rather than a commented illustration repeated in four example roots, which
  # is how the last one drifted out of date, there is one runnable version:
  # examples/homelab-ai-assistant, with the reasoning in docs/ai-assistant.md.

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
