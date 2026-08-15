# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

module "n8n" {
  source = "../.."

  # ── Backend selection ──────────────────────────────────────────────────────
  # Same backing services as examples/homelab: CNPG for Postgres, Valkey for
  # Redis, the cluster's default StorageClass for the PVCs.
  postgres_backend = "cnpg"
  redis_backend    = "valkey"
  # false when a shared claim exists, because the claim has to be created
  # before the release and it needs the namespace. See storage.tf.
  create_namespace = var.shared_storage_class == null

  # ── The split ──────────────────────────────────────────────────────────────
  # create_ingress = false hands routing to ingress.tf. The module still builds
  # everything those Ingresses point at, the Services, the queue-mode wiring,
  # the webhook processor Deployment, it just stops rendering the chart's own
  # single-host Ingress pair.
  create_ingress = false

  # What n8n hands out as the address to POST to. Without it, n8n builds webhook
  # URLs from N8N_HOST, which is the editor hostname here: every generated URL
  # would point at a name that serves the editor and refuses webhooks. Nothing
  # errors: the URLs are simply wrong, and only the external caller finds out.
  n8n_webhook_url = "https://${var.webhook_host}"

  # N8N_HOST, and the hostname n8n treats as canonical for the editor.
  # Production webhooks are advertised on var.webhook_host instead, via
  # n8n_webhook_url above. k8s_ingress_host is deliberately not set: every
  # consumer of it is gated on create_ingress, and the one that is not, the
  # webhook URL fallback, is overridden by n8n_webhook_url. Setting it here
  # would read as meaningful and do nothing.
  n8n_domain = var.editor_host

  # Queue-depth worker scaling when the cluster already runs KEDA. See
  # examples/homelab for why this is an attestation rather than an install.
  k8s_keda_installed = var.keda_installed


  k8s_namespace = var.namespace

  # ── k8s-backend Postgres / Redis ───────────────────────────────────────────
  cnpg_instances     = 1
  cnpg_storage_size  = "10Gi"
  cnpg_storage_class = var.storage_class

  valkey_storage_size  = "8Gi"
  valkey_storage_class = var.storage_class

  n8n_timezone = var.timezone

  # Task runners on so Python Code nodes work (adds the runner sidecar to main
  # and worker pods; the base n8n image ships no Python).
  n8n_task_runners_enabled = true

  n8n_extra_env = concat(
    [
      # The module sets this itself when it owns the Ingress. With
      # create_ingress = false it cannot know what sits in front, so the caller
      # declares it: without it n8n reads the ingress controller's own address
      # as the client IP, and every rate limit, audit log line and IP-based
      # restriction sees one source. See var.proxy_hops for how to count your
      # own chain; the default of 1 covers ingress-nginx alone and is wrong the
      # moment anything sits in front of it.
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

  # No depends_on here on purpose. n8n_extra_volumes already references the
  # claim, which is the ordering edge: Terraform cannot create the release until
  # the claim exists, and the claim cannot exist until the namespace does. An
  # explicit depends_on would add nothing and cost something, because it defers
  # everything inside the module, including the node lookup the capacity check
  # reads, turning a plan-time diagnostic into an apply-time one.

}
