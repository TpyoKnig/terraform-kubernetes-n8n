# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

module "n8n" {
  source = "../.."

  # ── Backend selection ──────────────────────────────────────────────────────
  # Same backing services as examples/homelab: CNPG for Postgres, Valkey for
  # Redis, the cluster's default StorageClass for the PVCs.
  postgres_backend = "cnpg"
  redis_backend    = "valkey"
  # Always false: this example owns the namespace, so that turning shared
  # storage on later cannot move it between two resource addresses mid-apply.
  # See storage.tf for what that used to cost.
  create_namespace = false

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

  # Counted by the caller, because with create_ingress = false the module
  # cannot know what sits in front. This used to go through n8n_extra_env,
  # which was the escape hatch doing a typed input's job; N8N_PROXY_HOPS is now
  # module-managed and reserved against that input, so setting it there is a
  # plan-time error. See var.proxy_hops for how to count your own chain: the
  # default of 1 covers ingress-nginx alone and is wrong the moment anything
  # sits in front of it.
  n8n_proxy_hops = var.proxy_hops

  # The mount alone does nothing. n8n defaults binary data to filesystem in
  # regular mode but to database in scaling mode, and this module always runs
  # queue mode, so without the mode below every payload still goes to Postgres
  # while the volume sits there empty and nothing reports a problem.
  #
  # These two used to be hand-written N8N_DEFAULT_BINARY_DATA_MODE and
  # N8N_STORAGE_PATH entries in the concat above. The module owns them now, and
  # it refuses filesystem mode unless a writable mount covers the path, which is
  # the check that turns the silent version of this mistake into a plan error.
  n8n_binary_data_mode = var.shared_storage_class != null ? "filesystem" : "database"
  # Only meaningful in filesystem mode, but validated either way, and this
  # example's own shared_mount_path check is laxer than the module's. Fall back
  # to the module default when shared storage is off, so a path that is only
  # ever unused cannot fail the plan.
  n8n_binary_data_path = var.shared_storage_class != null ? var.shared_mount_path : "/opt/n8n-shared"
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
