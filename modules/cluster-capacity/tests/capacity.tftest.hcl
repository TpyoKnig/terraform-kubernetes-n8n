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

# A NoExecute or PreferNoSchedule taint on its own does not stop an n8n pod
# landing there, so those nodes stay in the supply.
run "a_non_noschedule_taint_still_counts" {
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
