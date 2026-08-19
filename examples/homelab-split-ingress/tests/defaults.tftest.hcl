# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Plan-time tests for the homelab split-ingress example using mocked providers.
#
# Same backend as examples/homelab (kubernetes + cnpg + valkey). What is
# distinctive here is the routing: create_ingress = false, two caller-owned
# Ingresses, and n8n advertising webhooks on a hostname that is not N8N_HOST.
# The assertions below cover that, not the backend wiring the homelab example
# already tests.
#
# The mocked-provider limitations documented in AGENTS.md apply: planned
# resource attributes that flow through the mocked kubernetes_namespace chain
# resolve to (known after apply), so these assert on inputs and module outputs
# rather than on the rendered Ingress objects.
#
# Run: terraform test
#   (from examples/homelab-split-ingress/, mocks require terraform >= 1.11)

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  editor_host  = "n8n.test.example.com"
  webhook_host = "hooks.test.example.com"
}

run "the_module_renders_no_ingress_of_its_own" {
  command = plan

  # Both Ingresses belong to this example. If the module also rendered its
  # pair, the editor host would carry two rules for / from two objects and
  # ingress-nginx would pick one arbitrarily.
  assert {
    condition     = var.editor_host != var.webhook_host
    error_message = "The two hostnames must differ; the variable validation should have caught this."
  }
}

run "webhooks_are_advertised_on_the_webhook_host" {
  command = plan

  # A positive assertion, which needed a module output to exist: n8n_url is the
  # editor address, so every earlier version of this run could only say what the
  # webhook URL is not. A regression in the n8n_webhook_url wiring in main.tf,
  # dropped or mistyped or pointing at a third host, passed all of them.
  #
  # The failure it guards is silent: n8n keeps working, the editor keeps
  # working, and every webhook URL n8n hands out points at a hostname that
  # serves 404 for webhook paths. Only the external caller finds out.
  assert {
    condition     = module.n8n.n8n_webhook_url == "https://${var.webhook_host}"
    error_message = "n8n must advertise webhooks on webhook_host; got ${module.n8n.n8n_webhook_url}."
  }

  assert {
    condition     = module.n8n.n8n_webhook_url != module.n8n.n8n_url
    error_message = "The webhook base URL and the editor URL must differ; that split is the entire point of this example."
  }
}

# The mirror image of the run above, and the one that was missing. n8n builds
# the OAuth2 redirect URI from N8N_EDITOR_BASE_URL, and the chart used to
# derive that from webhook.url whenever it had no ingress host of its own to
# read - which is exactly this example, create_ingress = false. Every OAuth
# credential then failed at the provider's callback while webhook delivery kept
# working, so the symptom pointed at the wrong half of the split.
#
# Silent in the same way as the webhook case: nothing logs, the editor loads,
# and the 404 lands in the provider's UI at the end of a consent flow.
run "oauth_callbacks_are_advertised_on_the_editor_host" {
  command = plan

  assert {
    condition     = module.n8n.n8n_oauth_callback_url == "https://${var.editor_host}/rest/oauth2-credential/callback"
    error_message = "OAuth callbacks must be advertised on editor_host; got ${module.n8n.n8n_oauth_callback_url}."
  }

  # The webhook Ingress does now route /rest/projects, for the Agents chat
  # integrations covered in the run below, but it is still the wrong host to
  # advertise this on: N8N_EDITOR_BASE_URL is what n8n puts in the redirect URI,
  # and pointing the two at different hostnames is how the beta.4 bug worked.
  assert {
    condition     = !startswith(module.n8n.n8n_oauth_callback_url, "https://${var.webhook_host}")
    error_message = "OAuth callbacks must be advertised on the editor host, which is what N8N_EDITOR_BASE_URL names."
  }
}

# Upstream n8n builds the Slack app-install URL and the platform event
# callbacks by appending /rest/projects/<id>/agents/... onto
# getWebhookBaseUrl(), which is WEBHOOK_URL, which is webhook_host here. Those
# are main-pod routes. Without the rule, connecting a Slack agent 404s at the
# end of the OAuth flow, after consent has already been granted, and nothing
# logs it - the same silent shape as the two runs above.
#
# This was the "known, not fixed" item on the 0.0.1-beta.4 release PR.
run "agent_oauth_callbacks_reach_the_mains_on_the_webhook_host" {
  command = plan

  assert {
    condition     = contains([for p in kubernetes_ingress_v1.webhook.spec[0].rule[0].http[0].path : p.path], "/rest/projects")
    error_message = "The webhook Ingress must route /rest/projects, or connecting a Slack agent 404s at the end of the OAuth flow."
  }

  assert {
    condition     = one([for p in kubernetes_ingress_v1.webhook.spec[0].rule[0].http[0].path : p.backend[0].service[0].name if p.path == "/rest/projects"]) == module.n8n.n8n_service_name
    error_message = "/rest/projects on the webhook host must reach the main pods; the webhook processors register no /rest routes."
  }

  # The rule only works because it is a prefix match: every real callback is
  # /rest/projects/<id>/agents/..., never /rest/projects itself. Switched to
  # Exact, nothing would match and the two assertions above would still pass.
  assert {
    condition     = one([for p in kubernetes_ingress_v1.webhook.spec[0].rule[0].http[0].path : p.path_type if p.path == "/rest/projects"]) == "Prefix"
    error_message = "/rest/projects must be a Prefix match; an Exact match routes none of the agent callback paths."
  }
}

run "the_webhook_prefixes_come_from_the_module" {
  command = plan

  # Hardcoding these in the example is how a split ingress silently loses an
  # endpoint family when n8n adds one. All five must be present.
  assert {
    condition     = length(module.n8n.n8n_webhook_path_prefixes) == 5
    error_message = "Expected five webhook path prefixes from the module; got ${length(module.n8n.n8n_webhook_path_prefixes)}."
  }

  assert {
    condition     = alltrue([for p in ["/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp"] : contains(module.n8n.n8n_webhook_path_prefixes, p)])
    error_message = "Every prefix the mains refuse must be routed to the webhook processors on both hostnames."
  }

  # /webhook-test must NOT be in the list: manual test executions run on the
  # main pods, so routing it to the webhook processors would break the editor's
  # "listen for test event" button.
  assert {
    condition     = !contains(module.n8n.n8n_webhook_path_prefixes, "/webhook-test")
    error_message = "/webhook-test belongs on the mains and must stay on the editor Ingress catch-all."
  }
}

run "splitting_the_ingress_does_not_change_the_backing_services" {
  command = plan

  assert {
    condition     = can(regex("-valkey", module.n8n.backing_services.redis_host))
    error_message = "Splitting the ingress must not change which backend provides Redis; got: ${module.n8n.backing_services.redis_host}"
  }

  assert {
    condition     = can(regex("-pg-rw", module.n8n.backing_services.postgres_host))
    error_message = "postgres_host should reference the CNPG rw Service DNS name; got: ${module.n8n.backing_services.postgres_host}"
  }
}

run "one_hostname_for_both_roles_is_rejected" {
  command = plan

  variables {
    editor_host  = "n8n.test.example.com"
    webhook_host = "N8N.Test.Example.com"
  }

  # Case-insensitive on purpose: DNS is, and two Ingresses claiming the same
  # host differing only in case is the single-hostname topology with extra
  # steps.
  expect_failures = [var.webhook_host]
}

run "proxy_hops_defaults_to_the_single_nginx_hop" {
  command = plan

  # 1 is ingress-nginx alone, which is what this example assumes and what the
  # module itself uses when it owns the Ingress.
  assert {
    condition     = var.proxy_hops == 1
    error_message = "proxy_hops should default to 1; got ${var.proxy_hops}."
  }
}

run "proxy_hops_is_raisable_for_a_tunnel_or_cdn" {
  command = plan

  variables {
    proxy_hops = 2
  }

  # The module exposes no output carrying extraEnv, so this cannot assert on
  # the rendered value. What it does prove is that 2 survives validation and
  # the tostring() conversion into n8n_extra_env: a plan that reaches
  # completion here is the pass condition. The value was hardcoded to "1"
  # until a Cloudflare Tunnel deployment needed 2 and had no way to say so.
  assert {
    condition     = var.proxy_hops == 2
    error_message = "proxy_hops should accept 2; got ${var.proxy_hops}."
  }
}

run "proxy_hops_rejects_a_fractional_count" {
  command = plan

  variables {
    proxy_hops = 1.5
  }

  # It is a count of proxies and n8n parses it as an integer, so a fraction is
  # a typo rather than a meaningful setting.
  expect_failures = [var.proxy_hops]
}

run "proxy_hops_rejects_zero" {
  command = plan

  variables {
    proxy_hops = 0
  }

  # 0 means "trust the socket address as the client". This example always
  # creates its own Ingresses, so ingress-nginx is always in the chain and the
  # socket address is always the controller. Accepting 0 here would let an
  # allowlist compare every request against one internal address, which either
  # admits everyone or no one, and reports neither.
  expect_failures = [var.proxy_hops]
}

run "no_shared_claim_without_a_class" {
  command = plan

  # Off by default: binary data stays in Postgres, which is n8n's own default in
  # queue mode. The example has to stay applicable on a cluster with no RWX
  # class, so the claim is opt-in rather than required.
  assert {
    condition     = length(kubernetes_persistent_volume_claim_v1.shared) == 0
    error_message = "No claim should be planned when shared_storage_class is null."
  }

  # The namespace is this example's on every path, shared storage or not, so
  # that turning shared storage on later cannot move it between two resource
  # addresses. See storage.tf for what that used to cost.
  assert {
    condition     = kubernetes_namespace.n8n.metadata[0].name == var.namespace
    error_message = "The example must own the namespace on every path, shared claim or not; its name should equal var.namespace."
  }
}

run "a_class_produces_one_rwx_claim" {
  command = plan

  variables {
    shared_storage_class = "nfs-csi"
  }

  assert {
    condition     = length(kubernetes_persistent_volume_claim_v1.shared) == 1
    error_message = "Expected exactly one shared claim."
  }

  # Membership rather than equality: access_modes is a set, and comparing a set
  # to a list literal fails on type before it ever compares contents.
  #
  # ReadWriteOnce would bind to one node and leave the other two pod types
  # unable to mount it, which is the failure this whole file exists to avoid.
  assert {
    condition = (
      contains(kubernetes_persistent_volume_claim_v1.shared[0].spec[0].access_modes, "ReadWriteMany") &&
      length(kubernetes_persistent_volume_claim_v1.shared[0].spec[0].access_modes) == 1
    )
    error_message = "The shared claim must be exactly ReadWriteMany; three pod types mount it."
  }

  # Same namespace resource as the run above, unconditional now, which is what
  # the claim needs to be created into before the release.
  assert {
    condition     = kubernetes_namespace.n8n.metadata[0].name == var.namespace
    error_message = "The example must own the namespace when it owns the claim; its name should equal var.namespace."
  }
}

run "shared_mount_path_must_be_absolute" {
  command = plan

  variables {
    shared_storage_class = "nfs-csi"
    shared_mount_path    = "opt/n8n-shared"
  }

  expect_failures = [var.shared_mount_path]
}

run "malformed_hostnames_are_rejected" {
  command = plan

  variables {
    editor_host = "n8n..example.com"
  }

  # The previous regex was "starts alnum, then any of [alnum.-], then a TLD",
  # which accepted an empty label and a label ending in "-". Both are rejected
  # by the API server on the Ingress host field, so the failure surfaced at
  # apply against a live cluster rather than at plan.
  expect_failures = [var.editor_host]
}

run "a_trailing_hyphen_label_is_rejected" {
  command = plan

  variables {
    webhook_host = "hooks-.example.com"
  }

  expect_failures = [var.webhook_host]
}

run "an_empty_storage_class_is_rejected" {
  command = plan

  variables {
    shared_storage_class = ""
  }

  # "" is not null, so it used to enable the claim and then set
  # storageClassName to "", which asks Kubernetes for no class at all rather
  # than for the default one. The claim sits Pending with nothing saying why.
  expect_failures = [var.shared_storage_class]
}

run "a_whitespace_padded_storage_class_is_rejected" {
  command = plan

  variables {
    shared_storage_class = " nfs-csi"
  }

  # The claim is created with the value as given, so a padded name asks for a
  # class no cluster has. Same Pending claim as the empty string, with a name
  # that looks right in the plan output.
  expect_failures = [var.shared_storage_class]
}

run "the_kubeconfig_path_is_quoted_for_the_shell" {
  command = plan

  variables {
    kubeconfig_path = "/home/me/my kube/config"
  }

  # smoke-test.sh evals this. Unquoted, the export took "/home/me/my" and left
  # "kube/config" as a stray word.
  assert {
    condition     = output.kubectl_config_command == "export KUBECONFIG=\"/home/me/my kube/config\""
    error_message = "kubectl_config_command must quote the path; got ${output.kubectl_config_command}."
  }
}

run "a_tilde_path_becomes_HOME_so_quoting_does_not_break_it" {
  command = plan

  # Tilde expansion does not happen inside quotes, so the default would have
  # become a literal ~ directory once the value was quoted.
  assert {
    condition     = output.kubectl_config_command == "export KUBECONFIG=\"$HOME/.kube/config\""
    error_message = "A leading ~/ must become $HOME/; got ${output.kubectl_config_command}."
  }
}

run "a_shell_metacharacter_in_the_kubeconfig_path_is_rejected" {
  command = plan

  variables {
    kubeconfig_path = "/tmp/$(id).kube"
  }

  expect_failures = [var.kubeconfig_path]
}

run "a_trailing_backslash_in_the_kubeconfig_path_is_rejected" {
  command = plan

  # Escapes the closing quote of the generated export, so smoke-test.sh evals
  # an unterminated command and silently skips it.
  variables {
    kubeconfig_path = "/home/me/kube/\\"
  }

  expect_failures = [var.kubeconfig_path]
}

run "an_empty_kubeconfig_path_is_rejected" {
  command = plan

  # abspath("") is the example directory, so the smoke test would export a
  # directory as KUBECONFIG. nullable = false stops null, not empty.
  variables {
    kubeconfig_path = ""
  }

  expect_failures = [var.kubeconfig_path]
}

run "a_bare_home_directory_kubeconfig_path_is_rejected" {
  command = plan

  # "~/" resolves to $HOME/ - the same directory-as-KUBECONFIG failure the
  # empty path is rejected for, arrived at through the tilde branch.
  variables {
    kubeconfig_path = "~/"
  }

  expect_failures = [var.kubeconfig_path]
}

run "a_bare_tilde_kubeconfig_path_is_rejected" {
  command = plan

  # pathexpand("~") is the home directory for the providers, while the smoke
  # test would treat it as a relative path - two different wrong answers.
  variables {
    kubeconfig_path = "~"
  }

  expect_failures = [var.kubeconfig_path]
}

run "a_dressed_up_home_directory_spelling_is_rejected_too" {
  command = plan

  # "~/./" is the same directory as "~/" to everything that expands it, and
  # would slip past an exact string comparison.
  variables {
    kubeconfig_path = "~/./"
  }

  expect_failures = [var.kubeconfig_path]
}

run "a_posix_backslash_is_a_filename_character_not_a_separator" {
  command = plan

  # Normalising unconditionally pointed the smoke test at /tmp/kube/config
  # while the providers opened this file. Only a drive-qualified path gets its
  # separators rewritten; everything else keeps its backslashes and has them
  # escaped, because the shell collapses a backslash pair inside the double
  # quotes smoke-test.sh evals. Escaped, eval reproduces the literal.
  variables {
    kubeconfig_path = "/tmp/kube\\config"
  }

  assert {
    condition     = output.kubectl_config_command == "export KUBECONFIG=\"/tmp/kube\\\\config\""
    error_message = "A backslash in a POSIX path must survive; got ${output.kubectl_config_command}."
  }
}

run "a_windows_unc_path_survives_the_shell_eval" {
  command = plan

  # Absolute, so abspath must not touch it, and its separators are backslashes
  # that the eval would otherwise collapse in pairs. Escaped, the shell hands
  # kubectl back the path that was configured.
  variables {
    kubeconfig_path = "\\\\server\\share\\config"
  }

  assert {
    condition     = output.kubectl_config_command == "export KUBECONFIG=\"\\\\\\\\server\\\\share\\\\config\""
    error_message = "A UNC path must survive the eval intact; got ${output.kubectl_config_command}."
  }
}

run "a_drive_relative_windows_path_is_resolved_not_passed_through" {
  command = plan

  # "C:config" names a path against the current directory of drive C, not its
  # root, so it is relative. Asserted as "not passed through unchanged" rather
  # than against a literal, because what abspath resolves it to depends on
  # where the test runs.
  variables {
    kubeconfig_path = "C:config"
  }

  assert {
    condition     = output.kubectl_config_command != "export KUBECONFIG=\"C:config\""
    error_message = "A drive-relative path must be resolved, not treated as absolute; got ${output.kubectl_config_command}."
  }
}
