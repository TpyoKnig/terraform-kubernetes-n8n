# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

locals {
  # smoke-test.sh evals kubectl_config_command, so the path has to survive word
  # splitting: quoted for spaces, which are ordinary in a Windows or macOS home
  # directory. Quoting alone would break the "~/.kube/config" default, because
  # tilde expansion does not happen inside quotes, so a leading ~/ becomes
  # $HOME/ before quoting. The variable's own validation rejects the characters
  # that would let the rest of the string out of the quotes.
  kubeconfig_shell_path = startswith(var.kubeconfig_path, "~/") ? "$HOME/${substr(var.kubeconfig_path, 2, -1)}" : var.kubeconfig_path
}

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

  # Smoke test evals this in its own shell, so exporting KUBECONFIG points every
  # later kubectl call in the script at the same file this example deployed
  # through. The previous form read current-context out of kubeconfig_path and
  # set it in the default kubeconfig: a no-op when the two matched, and a switch
  # to the wrong cluster (or an error) when they did not.
  value = "export KUBECONFIG=\"${local.kubeconfig_shell_path}\""
}

output "backing_services" {
  description = "Which backend provides Postgres and Redis for this deployment, and the in-cluster endpoints for each."
  value       = module.n8n.backing_services
}
