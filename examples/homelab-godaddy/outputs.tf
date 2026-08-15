# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

output "n8n_url" {
  description = "URL to access n8n once the ingress controller has published the host. Consumed by tests/scripts/smoke-test.sh."
  value       = module.n8n.n8n_url
}

output "namespace" {
  description = "Namespace the n8n release and its backing services were deployed into."
  value       = module.n8n.namespace
}

output "kubectl_config_command" {
  description = "Command that points kubectl at the cluster this example deployed to. Consumed by tests/scripts/smoke-test.sh."

  # Smoke test reads this and evals it to point kubectl at the right cluster.
  # This example deploys wherever var.kubeconfig_path already points, so emit a
  # no-op that keeps the current context rather than naming one.
  value = "kubectl config use-context $(kubectl --kubeconfig=${var.kubeconfig_path} config current-context)"
}

output "backing_services" {
  description = "Which backend provides Postgres and Redis for this deployment, and the in-cluster endpoints for each."
  value       = module.n8n.backing_services
}
