# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

output "editor_url" {
  description = "URL for the n8n editor UI and REST API. Put your authentication policy in front of this hostname."
  value       = "https://${var.editor_host}"
}

output "webhook_base_url" {
  description = "Public base URL for webhooks, forms, waiting webhooks and MCP. This is what n8n hands out in generated webhook URLs (passed to the module as n8n_webhook_url)."
  value       = "https://${var.webhook_host}"
}

output "n8n_url" {
  description = "Editor URL under the name tests/scripts/smoke-test.sh reads. Points at editor_host: the smoke test checks the editor's health endpoint, which the webhook hostname deliberately does not serve."
  value       = "https://${var.editor_host}"
}

output "namespace" {
  description = "Namespace the n8n release and its backing services were deployed into."
  value       = module.n8n.namespace
}

output "kubectl_config_command" {
  description = "Command that points kubectl at the cluster this example deployed to. Consumed by tests/scripts/smoke-test.sh."

  # Smoke test evals this in its own shell, so exporting KUBECONFIG points every
  # later kubectl call in the script at the same file this example deployed
  # through. The previous form read current-context out of kubeconfig_path and
  # set it in the default kubeconfig: a no-op when the two matched, and a switch
  # to the wrong cluster (or an error) when they did not.
  value = "export KUBECONFIG=${var.kubeconfig_path}"
}

output "backing_services" {
  description = "Which backend provides Postgres and Redis for this deployment, and the in-cluster endpoints for each."
  value       = module.n8n.backing_services
}

output "webhook_path_prefixes" {
  description = "Path prefixes routed to the webhook processors on both hostnames. Read from the module rather than hardcoded, so the Ingresses cannot drift as n8n adds endpoints."
  value       = module.n8n.n8n_webhook_path_prefixes
}

output "dns_records" {
  description = "Hostnames this example created proxied CNAMEs for. Empty when cloudflare_zone_id is null, in which case both names are yours to publish."
  value       = [for r in cloudflare_record.n8n : r.name]
}
