# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Isolated out of tests/defaults.tftest.hcl, and out of the "tests"
# directory both Terraform and OpenTofu scan by default, because this run's
# override_resource block uses override_during = plan, which OpenTofu
# v1.13.2's override_resource schema does not support ("Unsupported
# argument"). That makes `tofu init` reject this file outright, and init
# scans every *.tftest.hcl file under the default test directory
# regardless of which one holds the invalid argument, so leaving this run
# in tests/ breaks `tofu init` for the whole root module, not just this run.
# Parking it in tests/opentofu-gaps/ instead keeps it outside that scan.
#
# .github/workflows/terraform-tests.yml's test-opentofu job does run this
# directory, via its own "tofu test (known OpenTofu gaps)" step
# (`tofu test -test-directory=tests/opentofu-gaps`), but that step is
# continue-on-error: true: `tofu init` rejecting this file outright is an
# expected, non-blocking failure the step's comment names. test/test-floor
# run the suite as a real, blocking assertion via
# `terraform test -test-directory=tests/opentofu-gaps`. See that workflow's
# comment on test-opentofu for the companion modules/cluster-capacity gap.
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

# A plan-time assert cannot read the hash itself once the toggle is on:
# random_password.valkey_default is unknown until apply (module-contract.md
# 5.4 rules out command = apply as a workaround for exactly this), so this run
# overrides it during plan and holds the shape, that the key the rotation
# depends on is present on both releases, which is the part that actually
# wires the two together.
run "enabling_rotation_roll_reaches_both_releases" {
  command = plan

  variables {
    redis_backend                         = "valkey"
    valkey_password_rotation_roll_enabled = true
  }

  override_resource {
    target          = random_password.valkey_default[0]
    override_during = plan
    values = {
      result = "test-valkey-password-0123456789ab"
    }
  }

  assert {
    condition     = contains(keys(local.k8s_values_pod_annotations.podAnnotations), "checksum/valkey-password")
    error_message = "The n8n release's podAnnotations must carry checksum/valkey-password once enabled, or rotating the generated password restarts no n8n pod."
  }

  assert {
    condition     = contains(keys(local.k8s_values_final.podAnnotations), "checksum/valkey-password")
    error_message = "The checksum must survive into the final merged values the n8n release renders."
  }

  assert {
    condition = length(helm_release.valkey) == 1 && alltrue([
      for r in helm_release.valkey :
      contains(keys(yamldecode(r.values[0]).podAnnotations), "checksum/valkey-password")
    ])
    error_message = "The valkey release's podAnnotations must carry the same key: one apply has to roll the server onto the new ACL and the clients onto the new password together, or rotation arms a split-brain instead."
  }
}
