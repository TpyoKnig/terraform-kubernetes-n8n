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
  #
  # A UNC path is absolute too, and has to be recognised here rather than left
  # to abspath, which would resolve it against the working directory and name a
  # different file on either platform.
  kubeconfig_is_absolute = anytrue([
    startswith(var.kubeconfig_path, "/"),
    startswith(var.kubeconfig_path, "\\\\"),
    can(regex("^[A-Za-z]:[/\\\\]", var.kubeconfig_path)),
  ])

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
  #
  # Anything else keeps its backslashes and has them escaped instead, because
  # smoke-test.sh evals this inside double quotes, where the shell collapses a
  # backslash pair. That covers a POSIX filename containing backslashes and a
  # Windows UNC path (\\server\share\config) with one rule, rather than
  # needing to tell them apart: escaped, eval reproduces either literally.
  kubeconfig_shell_path = can(regex("^[A-Za-z]:", local.kubeconfig_resolved)) ? replace(local.kubeconfig_resolved, "\\", "/") : replace(local.kubeconfig_resolved, "\\", "\\\\")
}

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

output "oauth_callback_url" {
  description = "Redirect URI to register with any OAuth2 provider a credential will use. It sits on editor_host, never on webhook_host: n8n builds this one from N8N_EDITOR_BASE_URL, which is the editor hostname. The webhook Ingress does route /rest/projects, but for the Agents chat integrations, which is a different flow. Read it from the module rather than building it here, so the value stays whatever n8n was actually configured with."
  value       = module.n8n.n8n_oauth_callback_url
}

output "namespace" {
  description = "Namespace the n8n release and its backing services were deployed into."
  value       = module.n8n.namespace
}

output "kubectl_config_command" {
  description = "Command that points kubectl at the cluster this example deployed to. Consumed by tests/scripts/smoke-test.sh."

  # var.kubeconfig_path is validated, but abspath prepends a directory nobody
  # validated. A repository checked out under a path containing $, a backtick
  # or a double quote would put it into a string smoke-test.sh evals, which is
  # the same escape the variable's own validation exists to prevent. Only
  # reachable when a relative path forced abspath to run, so the check is
  # scoped to that: absolute and ~/ paths never touch path.root.
  #
  # Plan-time rather than silent, which is the whole point. Not covered by a
  # test, because the failure depends on where the repository lives and a test
  # cannot move it.
  precondition {
    condition     = local.kubeconfig_is_absolute || startswith(var.kubeconfig_path, "~/") || !can(regex("[\"`$]", abspath(path.root)))
    error_message = "kubeconfig_path is relative, so it resolves against ${abspath(path.root)}, and that path contains a double quote, a backtick or a dollar sign. tests/scripts/smoke-test.sh evals this command, so those characters would escape its quoting. Pass an absolute kubeconfig_path, or move the repository somewhere without them."
  }

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

output "webhook_path_prefixes" {
  description = "Path prefixes routed to the webhook processors on both hostnames. Read from the module rather than hardcoded, so the Ingresses cannot drift as n8n adds endpoints."
  value       = module.n8n.n8n_webhook_path_prefixes
}
