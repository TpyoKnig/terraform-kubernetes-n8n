# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Every run below overrides data.kubernetes_nodes.capacity with a partial
# metadata object (just { name = "..." }), relying on Terraform
# auto-generating the remaining computed sub-attributes (annotations,
# generation, labels, resource_version, uid). OpenTofu v1.13.2 does not
# auto-fill those when only some fields of a nested block are given, and
# rejects the override instead ("Invalid mock/override field `nodes`: ...
# are required"). Isolated out of tests/capacity.tftest.hcl and out of the
# "tests" directory both tools scan by default, so this known gap cannot
# swallow a regression in that file's own "an_unavailable_read_says_nothing"
# run, which carries no override_data and is unaffected.
#
# .github/workflows/terraform-tests.yml's test-opentofu job never points at
# this directory, so tofu does not see this file at all. test/test-floor
# still run it, with the rest of the directory's suite, via
# `terraform test -test-directory=tests/opentofu-gaps`. See that workflow's
# comment on test-opentofu for the companion root-module gap.
#
# Run: terraform test -test-directory=tests/opentofu-gaps
#   (from modules/cluster-capacity)

mock_provider "kubernetes" {}

variables {
  model_readable          = true
  peak_cpu_request_millis = 12000
  demand_breakdown        = "main 3 × 1000m, worker 12 × 750m, webhook 8 × 300m"
}

run "ceilings_that_exceed_allocatable_cpu_warn" {
  command = plan

  override_data {
    target = data.kubernetes_nodes.capacity
    values = {
      nodes = [
        {
          metadata = [{ name = "worker-1" }]
          spec     = [{ unschedulable = false, taints = [] }]
          status   = [{ allocatable = { cpu = "3920m" } }]
        },
        {
          metadata = [{ name = "worker-2" }]
          spec     = [{ unschedulable = false, taints = [] }]
          status   = [{ allocatable = { cpu = "4" } }]
        },
      ]
    }
  }

  # 7,920m schedulable against 12,000m of ceilings.
  expect_failures = [check.autoscaler_ceilings_fit_cluster_capacity]
}

run "ceilings_that_fit_stay_quiet" {
  command = plan

  override_data {
    target = data.kubernetes_nodes.capacity
    values = {
      nodes = [
        {
          metadata = [{ name = "big-1" }]
          spec     = [{ unschedulable = false, taints = [] }]
          status   = [{ allocatable = { cpu = "64" } }]
        },
      ]
    }
  }
}

# Both quantity forms the kubelet reports have to parse. "4" is four cores, not
# four millicores: reading it as the latter would understate a node by 1000×
# and warn on every cluster.
run "a_core_count_and_a_millicore_quantity_are_both_read" {
  command = plan

  variables {
    peak_cpu_request_millis = 4500
  }

  override_data {
    target = data.kubernetes_nodes.capacity
    values = {
      nodes = [
        {
          metadata = [{ name = "cores" }]
          spec     = [{ unschedulable = false, taints = [] }]
          status   = [{ allocatable = { cpu = "4" } }]
        },
        {
          metadata = [{ name = "millicores" }]
          spec     = [{ unschedulable = false, taints = [] }]
          status   = [{ allocatable = { cpu = "600m" } }]
        },
      ]
    }
  }

  # 4,600m total. A run that fails here read "4" as 4m.
}

# Nodes nothing can schedule onto must not be counted. A homelab with three
# tainted control planes and three workers would otherwise look twice its real
# size, which is the failure mode this filter exists for: silently confirming
# ceilings the cluster cannot hold.
run "cordoned_and_tainted_nodes_are_not_counted" {
  command = plan

  variables {
    peak_cpu_request_millis = 5000
  }

  override_data {
    target = data.kubernetes_nodes.capacity
    values = {
      nodes = [
        {
          metadata = [{ name = "worker-1" }]
          spec     = [{ unschedulable = false, taints = [] }]
          status   = [{ allocatable = { cpu = "4" } }]
        },
        {
          metadata = [{ name = "worker-2-cordoned" }]
          spec     = [{ unschedulable = true, taints = [] }]
          status   = [{ allocatable = { cpu = "4" } }]
        },
        {
          metadata = [{ name = "control-plane-1" }]
          spec     = [{ unschedulable = false, taints = [{ key = "node-role.kubernetes.io/control-plane", value = "", effect = "NoSchedule" }] }]
          status   = [{ allocatable = { cpu = "4" } }]
        },
      ]
    }
  }

  # 4,000m schedulable, not 12,000m. Counting all three would pass 5,000m.
  expect_failures = [check.autoscaler_ceilings_fit_cluster_capacity]
}

# A PreferNoSchedule taint is a preference, not a bar: pods still land there,
# so the node stays in the supply.
run "a_prefer_no_schedule_taint_still_counts" {
  command = plan

  variables {
    peak_cpu_request_millis = 3000
  }

  override_data {
    target = data.kubernetes_nodes.capacity
    values = {
      nodes = [
        {
          metadata = [{ name = "worker-1" }]
          spec     = [{ unschedulable = false, taints = [{ key = "example.com/soft", value = "yes", effect = "PreferNoSchedule" }] }]
          status   = [{ allocatable = { cpu = "4" } }]
        },
      ]
    }
  }
}

# NoExecute blocks scheduling and evicts, so a node held by one (an
# out-of-service node, say) is not supply. Counting it would pass the 5,000m
# demand against 4,000m of real capacity.
run "a_noexecute_tainted_node_is_not_supply" {
  command = plan

  variables {
    peak_cpu_request_millis = 5000
  }

  override_data {
    target = data.kubernetes_nodes.capacity
    values = {
      nodes = [
        {
          metadata = [{ name = "worker-1" }]
          spec     = [{ unschedulable = false, taints = [] }]
          status   = [{ allocatable = { cpu = "4" } }]
        },
        {
          metadata = [{ name = "worker-2" }]
          spec     = [{ unschedulable = false, taints = [{ key = "node.kubernetes.io/out-of-service", value = "nodeshutdown", effect = "NoExecute" }] }]
          status   = [{ allocatable = { cpu = "4" } }]
        },
      ]
    }
  }

  expect_failures = [check.autoscaler_ceilings_fit_cluster_capacity]
}

# The provider can hand taints back as null rather than an empty list; a for
# over null is a hard plan error outside any check, which is exactly what this
# module must never produce.
run "a_null_taints_attribute_does_not_abort_the_plan" {
  command = plan

  variables {
    peak_cpu_request_millis = 3000
  }

  override_data {
    target = data.kubernetes_nodes.capacity
    values = {
      nodes = [
        {
          metadata = [{ name = "worker-1" }]
          spec     = [{ unschedulable = false }]
          status   = [{ allocatable = { cpu = "4" } }]
        },
      ]
    }
  }
}

# An unreadable CPU quantity upstream makes the demand figure meaningless. The
# check has to go silent rather than compare a zero against real capacity.
run "an_unreadable_demand_model_silences_the_check" {
  command = plan

  variables {
    model_readable          = false
    peak_cpu_request_millis = 0
  }

  override_data {
    target = data.kubernetes_nodes.capacity
    values = {
      nodes = [
        {
          metadata = [{ name = "tiny" }]
          spec     = [{ unschedulable = false, taints = [] }]
          status   = [{ allocatable = { cpu = "100m" } }]
        },
      ]
    }
  }
}
