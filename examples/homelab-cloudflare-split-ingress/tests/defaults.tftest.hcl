# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Plan-time tests for the Cloudflare split-ingress example using mocked
# providers.
#
# The split routing itself is covered by ../homelab-split-ingress. What is
# distinctive here is everything the tunnel adds: two DNS records instead of
# one, the proxy-hop count, and the fact that DNS stays optional so the example
# still applies into a cluster whose zone is managed elsewhere.
#
# Run: terraform test
#   (from examples/homelab-cloudflare-split-ingress/, mocks require terraform >= 1.11)

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "cloudflare" {}

variables {
  editor_host  = "n8n.test.example.com"
  webhook_host = "n8n-hooks.test.example.com"
}

run "no_dns_records_without_a_zone" {
  command = plan

  # cloudflare_zone_id is null by default. The example has to stay applicable
  # against a cluster whose DNS lives somewhere else, so the records are opt-in
  # rather than required.
  assert {
    condition     = length(cloudflare_record.n8n) == 0
    error_message = "No DNS records should be planned when cloudflare_zone_id is null; got ${length(cloudflare_record.n8n)}."
  }
}

run "a_zone_produces_one_record_per_hostname" {
  command = plan

  variables {
    cloudflare_zone_id   = "0123456789abcdef0123456789abcdef"
    cloudflare_tunnel_id = "beb9653a-ec18-4811-a689-3a4e05fcf106"
    cloudflare_api_token = "test-token"
  }

  # Two hostnames, two records. The single-host cloudflare example creates one;
  # publishing only the editor here would leave every production webhook
  # unresolvable while the deployment looked healthy.
  assert {
    condition     = length(cloudflare_record.n8n) == 2
    error_message = "Expected one record per hostname (2); got ${length(cloudflare_record.n8n)}."
  }

  assert {
    condition = alltrue([
      for r in cloudflare_record.n8n : r.proxied == true
    ])
    error_message = "Every record must be proxied: an unproxied CNAME to cfargotunnel.com does not resolve, because that hostname exists only inside Cloudflare's edge."
  }

  assert {
    condition = alltrue([
      for r in cloudflare_record.n8n : endswith(r.content, ".cfargotunnel.com")
    ])
    error_message = "Records must be CNAMEs at the tunnel, not A records at the ingress LoadBalancer: a homelab ingress address is usually private."
  }

  assert {
    condition     = length(setsubtract([for r in cloudflare_record.n8n : r.name], [var.editor_host, var.webhook_host])) == 0
    error_message = "The records must name exactly the two hostnames the Ingresses serve."
  }
}

run "a_zone_without_a_tunnel_is_rejected" {
  command = plan

  variables {
    cloudflare_zone_id = "0123456789abcdef0123456789abcdef"
  }

  # There is nothing to point a CNAME at without the tunnel UUID, and the
  # failure would otherwise be a record whose content is ".cfargotunnel.com".
  expect_failures = [var.cloudflare_zone_id]
}

run "proxy_hops_defaults_to_two_behind_the_tunnel" {
  command = plan

  # One hop is ingress-nginx. The Cloudflare edge is the second. The sibling
  # example defaults to 1 because it has no tunnel; inheriting that here would
  # make n8n read cloudflared's address as the client on every request.
  assert {
    condition     = var.proxy_hops == 2
    error_message = "proxy_hops should default to 2 in the tunnel topology; got ${var.proxy_hops}."
  }
}

run "proxy_hops_rejects_a_fractional_count" {
  command = plan

  variables {
    proxy_hops = 2.5
  }

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

run "the_editor_url_is_the_editor_host" {
  command = plan

  # Named for what it checks. n8n_url derives from n8n_domain, which is
  # editor_host, so this is an editor-URL assertion and always was: it cannot
  # catch a wrong webhook address, and the previous name claimed it could.
  assert {
    condition     = module.n8n.n8n_url == "https://${var.editor_host}"
    error_message = "n8n_url should be the editor address; got ${module.n8n.n8n_url}."
  }
}

# The mirror image of the run below, and the one that was missing. n8n builds
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

  # The webhook Ingress does now route /rest, for the Agents chat
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
    condition     = contains([for p in kubernetes_ingress_v1.webhook.spec[0].rule[0].http[0].path : p.path], "/rest")
    error_message = "The webhook Ingress must route /rest, or connecting a Slack agent 404s at the end of the OAuth flow."
  }

  assert {
    condition     = one([for p in kubernetes_ingress_v1.webhook.spec[0].rule[0].http[0].path : p.backend[0].service[0].name if p.path == "/rest"]) == module.n8n.n8n_service_name
    error_message = "/rest on the webhook host must reach the main pods; the webhook processors register no /rest routes."
  }

  # The rule only works because it is a prefix match: every real callback is
  # /rest/projects/<id>/agents/..., never /rest itself. Switched to Exact,
  # nothing would match and the two assertions above would still pass.
  assert {
    condition     = one([for p in kubernetes_ingress_v1.webhook.spec[0].rule[0].http[0].path : p.path_type if p.path == "/rest"]) == "Prefix"
    error_message = "/rest must be a Prefix match; an Exact match routes none of the agent callback paths."
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

run "no_shared_claim_without_a_class" {
  command = plan

  # Binary data stays in Postgres, which is n8n's own default in queue mode.
  # The example has to stay applicable on a cluster with no RWX class.
  assert {
    condition     = length(kubernetes_persistent_volume_claim_v1.shared) == 0
    error_message = "No claim should be planned when shared_storage_class is null."
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

  # ReadWriteOnce would bind to one node and leave the other two pod types
  # unable to mount it, which is the failure this whole file exists to avoid.
  # Membership rather than equality: access_modes is a set, and comparing a set
  # to a list literal fails on type before it ever compares contents.
  assert {
    condition = (
      contains(kubernetes_persistent_volume_claim_v1.shared[0].spec[0].access_modes, "ReadWriteMany") &&
      length(kubernetes_persistent_volume_claim_v1.shared[0].spec[0].access_modes) == 1
    )
    error_message = "The shared claim must be exactly ReadWriteMany; three pod types mount it."
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
