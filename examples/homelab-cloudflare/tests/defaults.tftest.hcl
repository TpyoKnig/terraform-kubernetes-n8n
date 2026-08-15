# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Plan-time tests for the homelab example using mocked providers.
#
# Exercises the example end-to-end with the in-cluster backing services
# selected: postgres_backend = "cnpg" + redis_backend = "valkey".
#
# The mocked-provider limitations documented in AGENTS.md apply here too:
# helm_release.values (and the k8s helm_release block itself) resolves to
# (known after apply) through the mocked kubernetes_namespace attribute chain,
# so asserts on the planned helm_release.n8n attributes (name, chart,
# namespace) are not possible under mocks. What IS assertable is that the
# module-level backing_services output resolves through local.k8s_pg_host /
# local.k8s_redis_host, which the CNPG + Valkey wiring both feed. Those
# assertions cover the "planned on the right backend" contract without
# reaching into resources whose attributes the mock provider defers.
#
# Run: terraform test
#   (from examples/homelab/, mocks require terraform >= 1.11)

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

# Required even though this example plans no Cloudflare resource by default.
# The provider block in providers.tf is configured unconditionally, and the
# real plugin rejects an empty configuration with "must provide exactly one of
# api_key, api_token or api_user_service_key" before it ever reaches the
# question of whether a resource uses it.
mock_provider "cloudflare" {}

run "backing_services_output_populated_on_k8s_backend" {
  command = plan

  assert {
    condition     = module.n8n.backing_services.postgres_host != ""
    error_message = "backing_services.postgres_host should be populated on the k8s backend; got empty string."
  }
}

run "postgres_host_names_cnpg_service" {
  command = plan

  # local.cnpg_service_host is "<release>-pg-rw.<namespace>.svc.cluster.local".
  # When postgres_backend = "cnpg" the backing-services output resolves to
  # that DNS name, so a substring match is enough to confirm the CNPG path.
  assert {
    condition     = can(regex("-pg-rw", module.n8n.backing_services.postgres_host))
    error_message = "backing_services.postgres_host should reference the CNPG rw Service DNS name when postgres_backend = \"cnpg\"; got: ${module.n8n.backing_services.postgres_host}"
  }
}

run "redis_host_names_valkey_service" {
  command = plan

  # local.valkey_host is "<release>-redis-valkey.<namespace>.svc.cluster.local".
  assert {
    condition     = can(regex("-redis-valkey", module.n8n.backing_services.redis_host))
    error_message = "backing_services.redis_host should reference the Valkey Service DNS name when redis_backend = \"valkey\"; got: ${coalesce(module.n8n.backing_services.redis_host, "<null>")}"
  }
}

run "binary_storage_is_filesystem_on_k8s_backend" {
  command = plan

  assert {
    condition     = module.n8n.backing_services.binary_storage == "filesystem"
    error_message = "backing_services.binary_storage must be \"filesystem\": the module provisions no object storage. Got: ${module.n8n.backing_services.binary_storage}"
  }
}

# ponytail: asserting that a specific resource address IS or IS NOT planned
# (helm_release.valkey, helm_release.n8n) would be the ideal shape but is not
# reachable via `assert` blocks, the harness does not expose the planned
# resource set as an expression. That coverage comes from the module's own
# tests/defaults.tftest.hcl (variable-contract assertions) plus a real
# `terraform plan` against a live cluster.
