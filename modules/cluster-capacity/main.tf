# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Advisory: autoscaler ceilings vs. what this cluster can schedule ──────────
# The Kubernetes-backend half of the sizing model in the root module's
# scaling.tf. Demand is identical on both backends, the same pod families
# requesting the same CPU at the same ceilings, and arrives here already summed
# in var.peak_cpu_request_millis. Only supply differs: a self-hosted cluster has
# no instance-type ladder to read a vCPU count off, so the number comes from the
# cluster itself.
#
# Alternative considered: make the caller declare node count and CPU per node.
# Rejected because it is a second source of truth that goes stale the first time
# a node is added or resized, and a confidently wrong capacity warning is worse
# than no warning at all.
#
# ── Why this is a submodule ───────────────────────────────────────────────────
# The node read has to be removable. Where the kubernetes provider is
# configured from an endpoint
# that does not exist at plan time, so the read would be deferred to apply and
# the check's condition would be unknown at plan, a hard error in
# `terraform test`, not a warning (see AGENTS.md). Gating it in place is not
# possible: Terraform rejects count and for_each inside a check block's nested
# data block ("The "count" and "for_each" meta-arguments are not supported
# within nested data blocks"). A submodule the root calls with count is the gate
# that does exist, and it removes the read entirely rather than
# relying on error masking to hide it.
#
# ── Why the read is NOT nested inside the check ───────────────────────────────
# It was, at first. Terraform masks a check-scoped data source's provider errors
# as warnings, which is exactly the can't-fail-a-plan posture an advisory wants.
# It also creates a dependency cycle for any caller that writes
# `depends_on = [module.n8n]` on a resource of their own:
#
#   Cycle: kubernetes_ingress_v1.editor, module.n8n.module.cluster_capacity
#   (close), module.n8n (close), (execute checks),
#   module.n8n.module.cluster_capacity[0].data.kubernetes_nodes.capacity
#
# Checks execute after everything else, so the nested read depends on every
# resource in the configuration: including the caller's resource, which is
# already waiting on this module. examples/homelab-split-ingress found it, and
# `depends_on` on a module is too ordinary a thing to write for a sizing hint to
# break it. A cycle is also an inscrutable failure: nothing in that message
# points at a capacity diagnostic the operator never asked for.
#
# The cost of moving it out is that a failed read now fails the plan instead of
# warning. That is what k8s_capacity_check_enabled exists for at the root: a
# caller who plans without cluster access, or whose credentials cannot list
# nodes cluster-wide, sets it false and loses only this warning. Every other
# resource on this backend needs that same cluster reachable to apply, so the
# combination is narrow, a plan-only CI job is the realistic one.
#
# ── Which nodes count ─────────────────────────────────────────────────────────
# Only nodes that could actually take an n8n pod: cordoned nodes
# (spec.unschedulable) and nodes carrying any NoSchedule or NoExecute taint are
# excluded. The taint filter is what makes the number right on a cluster with
# dedicated control planes, counting three tainted control-plane nodes would
# roughly double the apparent supply on a six-node lab. It is deliberately
# blunt in the other direction: a taint the n8n pods happen to tolerate still
# excludes that node, understating supply and warning a hair early. Erring
# toward warning is the right side to be wrong on for an advisory, and this
# module sets no tolerations on those pods anyway.
#
# Two approximations remain, both erring toward under-reporting supply:
# allocatable CPU already has kubelet and system reservations removed but not
# what the caller's own workloads have claimed, and DaemonSet requests are not
# subtracted. The check therefore sees more room than really exists, costing a
# warning rather than raising a false one.
#
# ── Reading a CPU quantity ────────────────────────────────────────────────────
# The kubelet reports allocatable CPU either as a core count ("4") or in
# millicores ("3920m"). Reading "4" as four millicores would understate a node
# by 1000× and warn on every cluster, so the suffix decides. try() falls an
# unparseable quantity back to 0 rather than aborting: a check block evaluates
# its error_message alongside its condition, so an error anywhere in here would
# fail the plan from inside the block whose entire purpose is to warn without
# failing.

data "kubernetes_nodes" "capacity" {}

locals {
  # NoExecute is excluded alongside NoSchedule: it blocks new scheduling the
  # same way and additionally evicts what is already there, so counting such a
  # node (an out-of-service node, say) overstated supply - the one direction
  # this model promises not to be wrong in. PreferNoSchedule stays counted:
  # it is a preference, not a bar. The taints read is guarded twice because
  # the provider can return the attribute as null rather than an empty list,
  # and a for over null is a hard plan error outside any check.
  schedulable_nodes = [
    for node in try(data.kubernetes_nodes.capacity.nodes, []) : node
    if try(node.spec[0].unschedulable, false) != true && length([
      for taint in coalesce(try(node.spec[0].taints, []), []) : taint
      if contains(["NoSchedule", "NoExecute"], taint.effect)
    ]) == 0
  ]

  # sum() rejects an empty list, and concat([0], …) is what keeps a cluster that
  # returned no usable nodes at a supply of exactly 0 rather than erroring. Zero
  # then means "nothing to compare against", which the check reads as silence.
  schedulable_cpu_millis = sum(concat([0], [
    for node in local.schedulable_nodes :
    try(endswith(node.status[0].allocatable.cpu, "m")
      ? tonumber(trimsuffix(node.status[0].allocatable.cpu, "m"))
    : tonumber(node.status[0].allocatable.cpu) * 1000, 0)
  ]))
}

check "autoscaler_ceilings_fit_cluster_capacity" {
  assert {
    condition = var.model_readable ? (
      local.schedulable_cpu_millis == 0 ? true : (
        var.peak_cpu_request_millis <= local.schedulable_cpu_millis
      )
    ) : true

    error_message = join("", [
      "Autoscaler maxima exceed the CPU this cluster can schedule. At their ceilings the n8n pods request ",
      "${var.peak_cpu_request_millis}m CPU (${var.demand_breakdown}), but the ",
      "${length(local.schedulable_nodes)} schedulable node(s) in this cluster report ",
      "${local.schedulable_cpu_millis}m allocatable CPU in total, before anything else you run on them. ",
      "Pods sit Pending with \"Insufficient cpu\" once the autoscalers climb past what is left, and nothing ",
      "adds nodes for you. Either lower n8n_worker_keda_max_replicas / ",
      "n8n_webhook_hpa_max_replicas, lower the per-pod CPU requests, or add ",
      "nodes. See ${var.docs_reference}.",
    ])
  }
}
