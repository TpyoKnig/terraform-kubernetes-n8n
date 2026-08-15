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

  # The failure this guards is silent: n8n keeps working, the editor keeps
  # working, and every webhook URL it hands out points at a hostname that
  # serves 404 for webhook paths.
  assert {
    condition     = module.n8n.n8n_url != "https://${var.webhook_host}"
    error_message = "n8n_url is the editor address; the webhook base URL is a separate output."
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

  # And the module keeps creating the namespace on that path.
  assert {
    condition     = length(kubernetes_namespace.n8n) == 0
    error_message = "The example should not create the namespace when there is no shared claim; the module does it."
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

  # Namespace ownership moves to the example, or the claim would have nothing to
  # be created in before the release.
  assert {
    condition     = length(kubernetes_namespace.n8n) == 1
    error_message = "The example must own the namespace when it owns the claim."
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
