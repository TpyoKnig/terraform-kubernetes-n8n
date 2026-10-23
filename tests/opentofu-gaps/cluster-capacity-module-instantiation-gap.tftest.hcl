# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Isolated out of tests/defaults.tftest.hcl's
# "kubernetes_ingress_serves_one_host_by_default" run (which keeps its other
# two assertions there) because OpenTofu v1.13.2's `tofu test` cannot resolve
# length(module.cluster_capacity) for this count-conditioned module: it
# always reports an empty tuple, regardless of the module's actual instance
# count, whenever the module declares zero output blocks.
# modules/cluster-capacity deliberately has none (see its README.md's
# "Outputs: No outputs." - it is a pure `check`-based advisory that creates
# nothing a caller needs back), so this is a `tofu test` runner limitation,
# not something this module's own code or test should work around by adding
# an output solely to dodge it.
#
# Confirmed with a minimal, unrelated reproduction: a root module declaring
# `module "sub" { count = var.enabled ? 1 : 0; source = "./sub" }` where
# var.enabled defaults to true and ./sub contains only `locals { dummy = 1 }`
# (no resources, no outputs). `tofu test`'s own plan output says "No
# changes. Your infrastructure matches the configuration." and then
# length(module.sub) reads as an empty tuple in the assertion, while real
# Terraform (any version through 1.17.0) correctly reports length 1.
# Adding a single trivial `output "dummy" { value = local.dummy }` to the
# same ./sub, with nothing else changed, makes `tofu test` agree with
# Terraform. Terraform's own documented test behaviour needs no such output
# to resolve a module's instance count; OpenTofu's test runner does here.
#
# .github/workflows/terraform-tests.yml's test-opentofu job does run this
# file, via its own "tofu test (known OpenTofu gaps)" step
# (`tofu test -test-directory=tests/opentofu-gaps`), but that step is
# continue-on-error: true and names this run as an expected, non-blocking
# failure in its comment. test/test-floor run it as a real, blocking
# assertion via `terraform test -test-directory=tests/opentofu-gaps`, with
# the rest of this directory's suite.
#
# Run: terraform test -test-directory=tests/opentofu-gaps
#   (from the module root)

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  n8n_domain = "n8n.test.example.com"

  # cnpg is the default backend and no backup is the default state, so
  # check.cnpg_has_no_backup_configured fires on every run that has not
  # configured one. Acknowledged here for the same reason
  # tests/defaults.tftest.hcl acknowledges it file-wide.
  cnpg_backup_acknowledged = true
}

run "kubernetes_ingress_serves_one_host_by_default_instantiates_cluster_capacity" {
  command = plan

  variables {
    postgres_backend           = "cnpg"
    redis_backend              = "valkey"
    create_ingress             = true
    k8s_ingress_cluster_issuer = "letsencrypt-prod"
  }

  assert {
    condition     = length(module.cluster_capacity) == 1
    error_message = "The kubernetes backend must instantiate modules/cluster-capacity: it is the only sizing diagnostic on this path."
  }
}
