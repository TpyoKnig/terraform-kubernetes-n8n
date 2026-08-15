# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

module "n8n" {
  source = "../.."

  # ── Backend selection ──────────────────────────────────────────────────────
  # Same backing services as examples/homelab: CNPG for Postgres, Valkey for
  # Redis, the cluster's default StorageClass for the PVCs.
  postgres_backend = "cnpg"
  redis_backend    = "valkey"
  create_namespace = true

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

  # N8N_HOST, and the hostname n8n considers canonical for the editor.
  k8s_ingress_host = var.editor_host

  # The editor hostname is n8n's canonical one (N8N_HOST). Production
  # webhooks are advertised on var.webhook_host instead, via
  # n8n_webhook_url below.
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

  n8n_extra_env = [
    # The module sets this itself when it owns the Ingress. With create_ingress
    # = false it cannot know what sits in front, so the caller declares it:
    # without it n8n reads the ingress controller's own address as the client
    # IP, and every rate limit, audit log line and IP-based restriction sees one
    # source. See var.proxy_hops for how to count your own chain; the default of
    # 1 covers ingress-nginx alone and is wrong the moment anything sits in
    # front of it.
    { name = "N8N_PROXY_HOPS", value = tostring(var.proxy_hops) },
  ]
}
