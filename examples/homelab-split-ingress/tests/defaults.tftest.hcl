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
