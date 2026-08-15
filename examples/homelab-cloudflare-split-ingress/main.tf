# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

module "n8n" {
  source = "../.."

  # ── Backend selection ──────────────────────────────────────────────────────
  postgres_backend = "cnpg"
  redis_backend    = "valkey"
  # false when a shared claim exists, because the claim has to be created
  # before the release and it needs the namespace. See storage.tf.
  create_namespace = var.shared_storage_class == null
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

  # ── The split ──────────────────────────────────────────────────────────────
  # Routing belongs to ingress.tf. The module still builds everything those
  # Ingresses point at; it just stops rendering the chart's single-host pair.
  create_ingress = false

  # What n8n hands out as the address to POST to. Without it, n8n builds webhook
  # URLs from N8N_HOST, which is the editor hostname here: every generated URL
  # would name a host that serves the editor and refuses production webhooks.
  # Nothing errors, the URLs are simply wrong, and only the caller finds out.
  n8n_webhook_url = "https://${var.webhook_host}"

  # N8N_HOST, and the hostname n8n treats as canonical for the editor.
  # k8s_ingress_host is deliberately not set: every consumer of it is gated
  # on create_ingress, and the one that is not, the webhook URL fallback, is
  # overridden by n8n_webhook_url above. Setting it here would read as
  # meaningful and do nothing.
  n8n_domain = var.editor_host

  k8s_keda_installed = var.keda_installed
  n8n_timezone       = var.timezone

  cnpg_instances     = 1
  cnpg_storage_size  = "10Gi"
  cnpg_storage_class = var.storage_class

  valkey_storage_size  = "8Gi"
  valkey_storage_class = var.storage_class

  # Task runners on so Python Code nodes work; the base n8n image ships no
  # Python.
  n8n_task_runners_enabled = true

  # ── Shared storage ─────────────────────────────────────────────────────────
  # Reaches main, worker and webhook-processor alike, which is exactly what the
  # chart's own persistence does not do. Empty when shared_storage_class is
  # null, in which case binary data stays in Postgres.
  n8n_extra_volumes = var.shared_storage_class != null ? [{
    name                    = "shared"
    persistent_volume_claim = { claim_name = kubernetes_persistent_volume_claim_v1.shared[0].metadata[0].name }
  }] : []

  n8n_extra_volume_mounts = var.shared_storage_class != null ? [{
    name       = "shared"
    mount_path = var.shared_mount_path
    read_only  = false
  }] : []

  n8n_extra_env = concat(
    [
      # Two hops by default here, where ../homelab-split-ingress uses one. That
      # example sits behind ingress-nginx alone; this one adds the Cloudflare
      # edge in front of it. See var.proxy_hops.
      { name = "N8N_PROXY_HOPS", value = tostring(var.proxy_hops) },
    ],
    # Both lines are required, and the mode is the one people miss. n8n defaults
    # binary data to filesystem in regular mode but to database in scaling mode,
    # and this module always runs queue mode. Mount the volume without setting
    # the mode and every payload still goes to Postgres: the mount is there,
    # empty, and nothing reports a problem.
    var.shared_storage_class != null ? [
      { name = "N8N_DEFAULT_BINARY_DATA_MODE", value = "filesystem" },
      { name = "N8N_STORAGE_PATH", value = "${var.shared_mount_path}/storage" },
    ] : [],
  )

  # No depends_on here on purpose. n8n_extra_volumes already references the
  # claim, which is the ordering edge: Terraform cannot create the release until
  # the claim exists, and the claim cannot exist until the namespace does. An
  # explicit depends_on would add nothing and cost something, because it defers
  # everything inside the module, including the node lookup the capacity check
  # reads, turning a plan-time diagnostic into an apply-time one.

}
