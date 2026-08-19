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
  # false when a shared claim exists, because the claim has to be created
  # before the release and it needs the namespace. See storage.tf.
  create_namespace = var.shared_storage_class == null

  # The hostname the Ingress serves and n8n advertises itself as. The module
  # creates no DNS record for it.
  n8n_domain = var.ui_host

  # Set true when KEDA is already running cluster-wide and workers should scale
  # on Redis queue depth instead of CPU. Off by default because the module does
  # not install KEDA on this backend, and a ScaledObject with no operator behind
  # it silently pins workers at their floor rather than failing.
  k8s_keda_installed = var.keda_installed


  # Reference the namespace resource rather than var.namespace on the shared
  # storage path, so every namespaced resource inside the module inherits an
  # edge to it. Without this the module only waits for the claim, and only for
  # the Helm release that mounts it: the Secrets, the CNPG Cluster and the
  # Valkey release have no path to the namespace at all and a first apply can
  # fail with `namespaces "n8n" not found`. Deploying in two steps hides it,
  # which is why it survived a live apply.
  #
  # A module-level depends_on would also fix it and costs more: it defers
  # everything inside, including the node lookup the capacity check reads, so a
  # plan-time diagnostic becomes an apply-time one. The name here stays known
  # at plan because it is a configured attribute, so this buys the edge without
  # making the namespace unknown.
  k8s_namespace = var.shared_storage_class != null ? kubernetes_namespace.n8n[0].metadata[0].name : var.namespace

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
  #   kubectl create secret generic ai-assistant-secrets   #     --from-literal=anthropic-api-key=...   #     --from-literal=sandbox-api-key=...
  #
  # n8n_extra_env is assigned below for shared storage, so these are entries to
  # add to that list rather than a second assignment: a second one is a
  # duplicate argument and Terraform rejects it before plan. Wrap the existing
  # value in concat() and put them in the second element.
  #
  #   { name = "N8N_ENABLED_MODULES", value = "instance-ai,agents" },
  #   { name = "N8N_INSTANCE_AI_SANDBOX_ENABLED", value = "true" },
  #   { name = "N8N_INSTANCE_AI_SANDBOX_PROVIDER", value = "n8n-sandbox" },
  #   { name = "N8N_SANDBOX_SERVICE_URL", value = "http://sandbox-api.n8n-sandbox.svc.cluster.local:8080" },
  #
  # n8n_extra_env is typed list(object({ name, value })) with no valueFrom
  # shape, so secret-backed variables go through n8n_extra_helm_values:
  #
  # n8n_extra_helm_values = <<-YAML
  #   config:
  #     extraEnv:
  #       - name: N8N_INSTANCE_AI_MODEL_API_KEY
  #         valueFrom:
  #           secretKeyRef:
  #             name: ai-assistant-secrets
  #             key: anthropic-api-key
  # YAML

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
  n8n_binary_data_path = var.shared_mount_path

  # No depends_on here on purpose. n8n_extra_volumes already references the
  # claim, which is the ordering edge: Terraform cannot create the release until
  # the claim exists, and the claim cannot exist until the namespace does. An
  # explicit depends_on would add nothing and cost something, because it defers
  # everything inside the module, including the node lookup the capacity check
  # reads, turning a plan-time diagnostic into an apply-time one.

}
