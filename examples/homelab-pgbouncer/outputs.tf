# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

locals {
  # smoke-test.sh evals kubectl_config_command, so the path has to survive word
  # splitting: quoted for spaces, which are ordinary in a Windows or macOS home
  # directory. Quoting alone would break the "~/.kube/config" default, because
  # tilde expansion does not happen inside quotes, so a leading ~/ becomes
  # $HOME/ before quoting. The variable's own validation rejects the characters
  # that would let the rest of the string out of the quotes.
  # Absolute, because the two consumers resolve a relative path against
  # different directories. Terraform resolves it against the root module; the
  # smoke test evals this export in whatever shell invoked it, which the
  # documented TERRAFORM_DIR=examples/... form runs from the repository root.
  # A relative kubeconfig therefore names one file at apply and a different,
  # usually absent, one at test.
  #
  # Only a genuinely relative path is resolved. abspath on Windows prepends a
  # drive to an already-absolute POSIX path, so running this from Windows
  # would rewrite a perfectly good /home/... into C:/home/..., and the output
  # would depend on where terraform ran rather than on what was configured.
  #
  # Drive-qualified means a separator after the colon. "C:config" is
  # drive-relative on Windows: it names a path against the current directory of
  # drive C rather than against its root, so it is relative and has to be
  # resolved like any other relative path.
  kubeconfig_is_absolute = startswith(var.kubeconfig_path, "/") || can(regex("^[A-Za-z]:[/\\\\]", var.kubeconfig_path))

  kubeconfig_resolved = startswith(var.kubeconfig_path, "~/") ? "$HOME/${substr(var.kubeconfig_path, 2, -1)}" : (
    local.kubeconfig_is_absolute ? var.kubeconfig_path : abspath(var.kubeconfig_path)
  )

  # Separators normalised, but only where a backslash is one. abspath uses the
  # platform's, so on Windows the resolved path arrives with backslashes, which
  # then sit inside a double-quoted shell string where they are at best noise
  # and at worst an escape. Forward slashes are correct on POSIX and accepted
  # by kubectl on Windows.
  #
  # On POSIX a backslash is an ordinary filename character, so normalising
  # unconditionally would point the smoke test at /tmp/kube/config while the
  # providers opened /tmp/kube\config. A drive letter is the only reliable
  # marker of a path whose separators are backslashes: a /-rooted path and a
  # ~/ path are both POSIX by construction.
  kubeconfig_shell_path = can(regex("^[A-Za-z]:", local.kubeconfig_resolved)) ? replace(local.kubeconfig_resolved, "\\", "/") : local.kubeconfig_resolved
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
