# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Isolated out of tests/defaults.tftest.hcl because OpenTofu v1.13.2's
# `tofu test` does not fall an explicit null, set through a run's own
# `variables` block, back to a `nullable = false` input's declared default.
# OpenTofu's own language documentation and real Terraform both agree the
# default must apply here ("If nullable is false and the variable has a
# default value, then OpenTofu uses the default when a module input
# argument is null."); only the `tofu test` runner's own variable-override
# path disagrees with that, which is why this is a test-framework gap
# rather than a reason to touch n8n_webhook_cpu_request and its three
# siblings' `nullable = false` declarations (see variables.tf) or weaken
# the assertion below.
#
# Confirmed with a minimal, unrelated reproduction: a root module declaring
# only `variable "x" { type = string; default = "default-value";
# nullable = false }`, tested with a run whose `variables { x = null }`
# asserts `var.x == "default-value"`. `tofu test` fails that assertion
# (var.x reads back as null); `terraform test` on the identical
# configuration passes it.
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

# F-083: check.webhook_resources_sized_for_reinstall_missing_packages
# interpolates all four webhook quantities and branches on this toggle, and
# Terraform evaluates a check's error_message alongside its condition rather
# than lazily on failure. Before nullable = false, an explicit null on any of
# the five aborted the plan from inside a block whose whole purpose is to
# warn without failing. The plan simply succeeding at the defaults is the
# point of this run.
run "explicit_nulls_on_webhook_resources_fall_back_to_defaults" {
  command = plan

  variables {
    n8n_webhook_cpu_request        = null
    n8n_webhook_cpu_limit          = null
    n8n_webhook_memory_request     = null
    n8n_webhook_memory_limit       = null
    n8n_reinstall_missing_packages = null
  }

  assert {
    condition = (
      var.n8n_webhook_cpu_request == "300m" &&
      var.n8n_webhook_cpu_limit == "800m" &&
      var.n8n_webhook_memory_request == "512Mi" &&
      var.n8n_webhook_memory_limit == "1Gi" &&
      var.n8n_reinstall_missing_packages == false
    )
    error_message = "An explicit null on any of these five must fall back to its declared default, not propagate into the module."
  }
}
