# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Mocked tests for the Kubernetes-backend capacity advisory.
#
# These live with the submodule rather than in the root suite for one reason:
# expect_failures cannot name a check inside a child module ("You cannot expect
# failures from module.cluster_capacity[0].check"). Run against this directory
# as its own root, the check is addressable and the warning can be asserted on
# directly: which is the whole point, since a diagnostic that fires when it
# should not is as bad as one that never fires.
#
# The root suite covers the other half: that the root instantiates the module at
# all, and only when k8s_capacity_check_enabled is true (tests/defaults.tftest.hcl).
#
# The rest of this suite, every run that overrides data.kubernetes_nodes.capacity,
# lives in tests/opentofu-gaps/override-data-field-gap.tftest.hcl instead: a
# known OpenTofu gap in that override makes tofu reject those runs (see that
# file's header, and the test-opentofu job's comment in
# .github/workflows/terraform-tests.yml), and keeping them out of this
# directory keeps that gap from swallowing a regression in the one run below,
# which carries no override_data and is unaffected by it.
#
# Run: terraform test    (from modules/cluster-capacity)

mock_provider "kubernetes" {}

variables {
  model_readable          = true
  peak_cpu_request_millis = 12000
  demand_breakdown        = "main 3 × 1000m, worker 12 × 750m, webhook 8 × 300m"
}

run "an_unavailable_read_says_nothing" {
  command = plan

  # No override_data: the mocked provider returns no nodes, which is what a
  # masked read looks like from inside the check. Supply of zero must mean
  # "nothing to compare against", not "no capacity" - the demand above would
  # otherwise fail against it every time.
}
