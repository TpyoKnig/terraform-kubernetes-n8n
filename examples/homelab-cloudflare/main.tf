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
  create_namespace = true

  # The hostname the Ingress serves and n8n advertises itself as. The module
  # creates no DNS record for it.
  n8n_domain = var.ui_host

  # Set true when KEDA is already running cluster-wide and workers should scale
  # on Redis queue depth instead of CPU. Off by default because the module does
  # not install KEDA on this backend, and a ScaledObject with no operator behind
  # it silently pins workers at their floor rather than failing.
  k8s_keda_installed = var.keda_installed


  k8s_namespace = var.namespace

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
  # empty namespace unchanged; create the Secret first, then uncomment.
  #
  #   kubectl create secret generic ai-assistant-secrets   #     --from-literal=anthropic-api-key=...   #     --from-literal=sandbox-api-key=...
  #
  # n8n_extra_env = [
  #   { name = "N8N_ENABLED_MODULES", value = "instance-ai,agents" },
  #   { name = "N8N_INSTANCE_AI_SANDBOX_ENABLED", value = "true" },
  #   { name = "N8N_INSTANCE_AI_SANDBOX_PROVIDER", value = "n8n-sandbox" },
  #   { name = "N8N_SANDBOX_SERVICE_URL", value = "http://sandbox-api.n8n-sandbox.svc.cluster.local:8080" },
  # ]
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
}
