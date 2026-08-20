# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

locals {
  # "<release>-api" is the chart's apiName template applied to a fullname the
  # README's install command pins with fullnameOverride=<release>. Without that
  # override the chart's standard fullname helper concatenates release and
  # chart name (release "sandbox" does not contain "n8n-sandbox-service", so
  # nothing is dropped) and the Service renders as
  # "sandbox-n8n-sandbox-service-api" - a name this URL would never match.
  # The README and this local are one contract: install with
  # fullnameOverride equal to sandbox_release_name, or n8n points at a Service
  # that does not exist and every code execution times out.
  sandbox_service_url = "http://${var.sandbox_release_name}-api.${var.sandbox_namespace}.svc.cluster.local:8080"
}

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
  # main + worker pods; base n8n image ships no Python). Also what the AI
  # Assistant's generated workflows run their own Code nodes against.
  n8n_task_runners_enabled = true

  # ── AI Assistant / Agents, the point of this example ───────────────────────
  # The module's own n8n_image_tag default (see variables.tf in the module
  # root) already sits above 2.32.3, the Agents module's version floor - no
  # override needed here. Pin it yourself if you ever set n8n_image_tag
  # explicitly; see docs/ai-assistant.md's "Version floor" section for what an
  # unmet floor looks like (the variable is silently ignored, not rejected).
  #
  # instance-ai is the assistant; agents is the separate Agents module. Both
  # ride the same model and the same version floor, so this example turns on
  # both rather than making the second one a knob nobody would think to flip.
  #
  # N8N_SANDBOX_SERVICE_URL points at a Helm release this example does not
  # create. See README.md "Standing up the sandbox" for why: the upstream
  # chart is not published to a Helm repository yet (still main-branch only as
  # of chart 0.4.0 / PR n8n-io/n8n-sandbox-service#126), so there is nothing a
  # `helm_release` resource here could pin a version against without vendoring
  # a copy of someone else's chart into this repository to keep in sync by
  # hand. The module's own stance is the same one this example inherits: the
  # sandbox is a caller prerequisite, like the ingress controller or the CNPG
  # operator, not something the module or its examples provision.
  n8n_extra_env = [
    { name = "N8N_ENABLED_MODULES", value = "instance-ai,agents" },
    { name = "N8N_INSTANCE_AI_MODEL", value = var.ai_model },
    { name = "N8N_INSTANCE_AI_SANDBOX_ENABLED", value = "true" },
    { name = "N8N_INSTANCE_AI_SANDBOX_PROVIDER", value = "n8n-sandbox" },
    { name = "N8N_SANDBOX_SERVICE_URL", value = local.sandbox_service_url },
  ]

  # Nothing here passes through Terraform, so no key reaches the Helm release
  # or the state file. The Secret is created out of band on purpose - declaring
  # it as a kubernetes_secret resource would put the values straight back in
  # state. See README.md "Wiring n8n to the sandbox" for the exact command;
  # both keys have to come from the same place the sandbox chart's auth Secret
  # does, or code execution fails with the assistant chat still working, which
  # reads as a sandbox outage rather than the credential mismatch it is.
  n8n_extra_env_from_secret = [
    {
      name        = "N8N_INSTANCE_AI_MODEL_API_KEY"
      secret_name = "ai-assistant-secrets"
      secret_key  = "model-api-key"
    },
    {
      name        = "N8N_SANDBOX_SERVICE_API_KEY"
      secret_name = "ai-assistant-secrets"
      secret_key  = "sandbox-api-key"
    },
  ]

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
