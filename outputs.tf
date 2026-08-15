# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Routing ───────────────────────────────────────────────────────────────────
# The module renders an Ingress only when create_ingress = true. Everything
# below is what a caller needs to route to the workload themselves when it is
# false; see examples/homelab-split-ingress for a worked version.

output "n8n_service_name" {
  description = "Name of the Kubernetes Service fronting the n8n main pods (the editor UI and REST API), on port 5678. Point a caller-owned Ingress at this when create_ingress = false."
  value       = local.n8n_service_name
}

output "n8n_webhook_service_name" {
  description = "Name of the Kubernetes Service fronting the n8n webhook processors, on port 5678. Production webhooks are disabled on the main pods, so a caller-owned Ingress must route the webhook prefixes here."
  value       = local.n8n_webhook_service_name
}

output "n8n_webhook_path_prefixes" {
  description = "Path prefixes that must be routed to n8n_webhook_service_name rather than n8n_service_name. The main pods run with production webhooks disabled, so every one of these returns 404 if it reaches them: /webhook, /webhook-waiting (also carries the Slack and Telegram human-in-the-loop callbacks), /form, /form-waiting, and /mcp. Route all of them when building your own Ingress with create_ingress = false."
  value       = local.n8n_webhook_path_prefixes
}

output "n8n_service_port" {
  description = "Port both n8n Services listen on. Use with n8n_service_name / n8n_webhook_service_name when building your own Ingress."
  value       = local.n8n_service_port
}

output "n8n_url" {
  description = "URL n8n is served at. The module creates no DNS record for it: publishing the hostname is caller-owned on this platform, because how a name reaches a self-hosted cluster depends entirely on the setup (a tunnel, a public LoadBalancer, split-horizon DNS, a reverse proxy)."
  value       = "https://${local.n8n_domain}"
}

output "n8n_webhook_url" {
  description = "Base URL n8n advertises in every production webhook, form and MCP URL it generates (WEBHOOK_URL). Equal to n8n_url unless n8n_webhook_url was set, which is the split-hostname topology: editor on one name, webhooks on another. Worth asserting on in a caller's own test suite, because getting it wrong fails silently. n8n keeps working, the editor keeps working, and only the external system POSTing to a stale address finds out."
  value       = local.k8s_values_webhook.webhook.url
}

output "namespace" {
  description = "Kubernetes namespace n8n is deployed into."
  # Deliberately sourced from local.namespace_name rather than var.k8s_namespace
  # directly. On the create_namespace = true path (the default), that local
  # reads the resource attribute rather than the plan-time-constant variable,
  # so a caller's own kubernetes_* resources referencing this output get a
  # dependency edge on the namespace; without it Terraform schedules them
  # concurrently and they fail with `namespaces "n8n" not found`. That trap is
  # easy to hit on the create_ingress = false path, where the caller's
  # Ingresses are the first thing to reference this output. On the
  # create_namespace = false path there is no module-owned namespace resource
  # to depend on, so the local is just var.k8s_namespace, and there is nothing for
  # a consumer to wait on: the namespace already existed before this apply.
  value = local.namespace_name
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# Retrieve with terraform output -raw <name>

output "n8n_encryption_key" {
  description = "n8n encryption key. Back this up in a password manager: losing it makes every stored credential unreadable, and that survives a database restore: restoring Postgres into a new deployment without this key leaves the credentials there but undecryptable. It is also the value to pass as var.n8n_encryption_key when rebuilding a deployment against existing data. Null when n8n_encryption_key_secret_ref is set: the key then lives in a Secret the module never reads, so backing it up belongs to that Secret's owner."
  value       = local.n8n_encryption_key
  sensitive   = true
}

# ── Backing services ──────────────────────────────────────────────────────────

output "backing_services" {
  description = "Resolved endpoints for n8n's Postgres and Redis backends. Names the in-cluster CNPG rw Service and Valkey Service on the default path, or the caller-supplied endpoints when postgres_backend / redis_backend are \"external\". The secret names are where each password actually lives; the module never emits those values as outputs, because on the in-cluster path it does not own them: CNPG generates the Postgres password into its own \"<cluster>-app\" Secret. Useful for a Grafana datasource, a debug pod, or a smoke test that needs to reach the backing services directly."
  value = {
    # Consumed by tests/scripts/smoke-test.sh.
    postgres_host   = local.k8s_pg_host
    postgres_secret = local.k8s_pg_secret_name
    redis_host      = local.k8s_redis_host
    redis_secret    = local.k8s_redis_secret_name
    binary_storage  = "filesystem"
  }
}
