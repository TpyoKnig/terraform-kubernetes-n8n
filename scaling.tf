# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Autoscaling capacity model ────────────────────────────────────────────────
# The autoscaler ceilings (n8n_webhook_hpa_max_replicas,
# n8n_worker_keda_max_replicas) and the per-pod CPU requests have to be sized
# against what the cluster can actually schedule, and nothing in Kubernetes
# couples them. Set a ceiling above what the cluster can ever hold and the
# autoscalers still scale toward it: pods pile up Pending with "Insufficient
# cpu". That churn also delays rollouts, because a surging ReplicaSet competes
# for the same exhausted CPU.
#
# The locals below model the demand side of that arithmetic; supply is read from
# the cluster in modules/cluster-capacity, which warns at plan time. CPU is the
# binding constraint at the module's defaults; memory is modelled the same way
# in principle but is not what runs out first, so it is deliberately left out
# rather than half-modelled.

locals {
  # Kubernetes CPU quantities are either a core count ("1", "1.5") or millicores
  # ("500m"). Normalize to millicores so they can be summed.
  #
  # can() guards a quantity in a form this module cannot read. That drops
  # n8n_capacity_model_readable to false and the check below stays silent, rather
  # than failing the plan over an input Kubernetes itself would have rejected at
  # apply. Unreadable entries fall back to 0 rather than null, because a check
  # block evaluates its error_message alongside its condition and null operands
  # in the interpolated arithmetic would abort the plan outright.
  n8n_cpu_requests = {
    main = var.n8n_main_cpu_request
    # A task runner sidecar rides on main and worker pods only. The chart adds
    # the container in deployment-main.yaml and deployment-worker.yaml, not in
    # deployment-webhook-processor.yaml, so webhook processors carry no sidecar
    # cost below.
    task_runner = var.n8n_task_runners_enabled ? var.n8n_task_runner_cpu_request : "0"
    webhook     = var.n8n_webhook_cpu_request
    worker      = var.n8n_worker_cpu_request
  }

  n8n_cpu_requests_readable = alltrue([
    for quantity in values(local.n8n_cpu_requests) : can(tonumber(trimsuffix(quantity, "m")))
  ])

  n8n_cpu_request_millis = {
    for name, quantity in local.n8n_cpu_requests : name => (
      can(tonumber(trimsuffix(quantity, "m")))
      ? (endswith(quantity, "m") ? tonumber(trimsuffix(quantity, "m")) : tonumber(quantity) * 1000)
      : 0
    )
  }

  # What the three pod families request when every autoscaler sits at its
  # ceiling simultaneously. Not a forecast: the point is that this number must
  # be schedulable at all, because each autoscaler can independently reach its
  # own maximum.
  n8n_peak_cpu_request_millis = local.n8n_cpu_requests_readable ? (
    1 * (local.n8n_cpu_request_millis["main"] + local.n8n_cpu_request_millis["task_runner"]) +
    var.n8n_worker_keda_max_replicas * (local.n8n_cpu_request_millis["worker"] + local.n8n_cpu_request_millis["task_runner"]) +
    var.n8n_webhook_hpa_max_replicas * local.n8n_cpu_request_millis["webhook"]
  ) : 0

}

# ── Cluster capacity diagnostic ────────────────────────────
# Demand is backend-independent, local.n8n_peak_cpu_request_millis above is the
# same pods requesting the same CPU at the same ceilings. Only supply differs, so
# only supply moves into the submodule: it reads the cluster's own allocatable
# CPU instead of deriving a vCPU count from an instance type that has no meaning
# here.
#
# The count is the whole reason this is a submodule rather than another check
# block in this file. Terraform rejects count and for_each inside a check
# block's nested data block, and k8s_capacity_check_enabled has to be able to
# remove the node read entirely rather than merely silence the warning. See modules/cluster-capacity/main.tf for the rest of the reasoning.

module "cluster_capacity" {
  count  = var.k8s_capacity_check_enabled ? 1 : 0
  source = "./modules/cluster-capacity"

  model_readable          = local.n8n_cpu_requests_readable
  peak_cpu_request_millis = local.n8n_peak_cpu_request_millis

  demand_breakdown = join("", [
    "main 1 × ${local.n8n_cpu_request_millis["main"] + local.n8n_cpu_request_millis["task_runner"]}m, ",
    "worker ${var.n8n_worker_keda_max_replicas} × ${local.n8n_cpu_request_millis["worker"] + local.n8n_cpu_request_millis["task_runner"]}m, ",
    "webhook ${var.n8n_webhook_hpa_max_replicas} × ${local.n8n_cpu_request_millis["webhook"]}m",
  ])

  # No explicit `providers` map, deliberately. Passing one makes this module
  # stop inheriting its own providers implicitly, and every example then fails
  # with "module.n8n expects to inherit a configuration for provider
  # hashicorp/kubernetes ... but the root module doesn't pass a configuration
  # under that name" - a breaking change for every existing caller. The
  # submodule declares kubernetes in its own required_providers and inherits the
  # default configuration, which is the one this module already uses.
}

# ── Advisory: webhook resources vs. reinstall_missing_packages ────────────────
# With n8n_reinstall_missing_packages = true, every pod (main, worker, webhook
# processor) runs npm installs at boot, and n8n rebroadcasts installs to every
# pod via pubsub, so a rolling restart makes every webhook pod install
# repeatedly at once. Against the webhook processor's low default resources
# this produces two production failure modes: CPU spikes read as 200-300% of
# the request and drive the CPU-based HPA above into a scale-up-on-every-rollout
# loop, and concurrent installs plus the n8n baseline exceed a 1Gi memory limit,
# OOMKilling pods mid-install into a reinstall/broadcast crash loop that can
# leave corrupted package directories behind.
#
# This only warns: the thresholds below are one operator's stable production
# values, not a hard requirement, and n8n_reinstall_missing_packages defaults to
# false, so most callers never hit this. See docs/troubleshooting.md.

locals {
  # can() still turns an unparseable quantity into "unreadable" rather than a
  # plan-time error, because this check exists to warn rather than to validate
  # quantity syntax. The variables now carry that validation themselves, so the
  # null branches below are unreachable for any value that reaches this far;
  # they stay as the belt to the validation's braces.
  n8n_webhook_cpu_millis = {
    for name, quantity in {
      request = var.n8n_webhook_cpu_request
      limit   = var.n8n_webhook_cpu_limit
      } : name => can(regex("^[0-9]+(\\.[0-9]+)?m?$", quantity)) ? (
      endswith(quantity, "m") ? tonumber(trimsuffix(quantity, "m")) : tonumber(quantity) * 1000
    ) : null
  }

  # Mebibytes per Kubernetes memory suffix. Written out rather than computed so
  # the decimal suffixes are visibly not their binary namesakes: 1G is
  # 1,000,000,000 bytes, which is 953.674...Mi, not 1024Mi. Previously only Mi
  # and Gi parsed, and every other valid suffix fell through to null, which
  # silenced the advisory below on a configuration that was perfectly legal.
  memory_mebibytes_per_suffix = {
    "Ki" = 1 / 1024
    "Mi" = 1
    "Gi" = 1024
    "Ti" = 1024 * 1024
    "k"  = 1000 / 1048576
    "M"  = 1000000 / 1048576
    "G"  = 1000000000 / 1048576
    "T"  = 1000000000000 / 1048576
  }

  n8n_webhook_memory_mebibytes = {
    for name, quantity in {
      request = var.n8n_webhook_memory_request
      limit   = var.n8n_webhook_memory_limit
      } : name => can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", quantity)) ? (
      tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", quantity)) * lookup(
        local.memory_mebibytes_per_suffix,
        replace(quantity, "/^[0-9]+(?:\\.[0-9]+)?/", ""),
        # No suffix at all means plain bytes.
        1 / 1048576,
      )
    ) : null
  }

  n8n_webhook_resources_readable = alltrue([
    for v in concat(values(local.n8n_webhook_cpu_millis), values(local.n8n_webhook_memory_mebibytes)) : v != null
  ])

  # Thresholds are one operator's stable production values as reported against
  # this failure mode: CPU 800m request / 1500m limit, memory 1Gi request /
  # 2Gi limit. The module's own defaults
  # (300m/800m CPU, 512Mi/1Gi memory) sit below all four, which is deliberate:
  # this check exists because those defaults are the ones that failed.
  n8n_webhook_resources_sized_for_reinstall = local.n8n_webhook_resources_readable ? (
    local.n8n_webhook_cpu_millis["request"] >= 800 &&
    local.n8n_webhook_cpu_millis["limit"] >= 1500 &&
    local.n8n_webhook_memory_mebibytes["request"] >= 1024 &&
    local.n8n_webhook_memory_mebibytes["limit"] >= 2048
  ) : true
}

check "webhook_resources_sized_for_reinstall_missing_packages" {
  assert {
    condition = var.n8n_reinstall_missing_packages ? local.n8n_webhook_resources_sized_for_reinstall : true
    error_message = join("", [
      "n8n_reinstall_missing_packages is true, but the webhook processor's CPU/memory requests and limits ",
      "(currently ${var.n8n_webhook_cpu_request}/${var.n8n_webhook_cpu_limit} CPU, ",
      "${var.n8n_webhook_memory_request}/${var.n8n_webhook_memory_limit} memory) are below the values known to ",
      "survive it in production. Every pod reinstalls community packages on boot and n8n rebroadcasts installs ",
      "to all pods, so a rolling restart makes every webhook pod install repeatedly at once: CPU spikes to ",
      "200-300% of a low request (driving the CPU-based HPA into a scale-up-on-every-rollout loop), and ",
      "concurrent installs plus the n8n baseline can exceed a low memory limit and OOMKill pods mid-install into ",
      "a reinstall/broadcast crash loop. Raise n8n_webhook_cpu_request/limit to at least 800m/1500m and ",
      "n8n_webhook_memory_request/limit to at least 1Gi/2Gi. See docs/troubleshooting.md.",
    ])
  }
}

# ── Webhook-processor HPA the chart declines to render ────────────────────────
# The chart gates its own webhook HPA on `not .Values.keda.enabled`
# (templates/hpa-webhook-processor.yaml), on the assumption that turning KEDA on
# means every pool moves to a ScaledObject. It does not: the chart's webhook
# ScaledObject additionally needs `keda.webhookProcessor.enabled`, which
# defaults to false, and this module deliberately leaves it there: queue depth
# is the wrong signal for webhook processors. They are an HTTP ingest tier, and
# the Bull queue they write into is drained by workers, so a deep queue means
# "add workers", never "add webhook receivers". Sizing the ingest tier on it
# would scale up the pods that are keeping up and leave the ones that are not.
#
# So attesting KEDA suppressed the CPU HPA and put nothing in its place: webhook
# processors sat pinned at their replica count while n8n_webhook_hpa_* were
# silently ignored, and the capacity check went on counting a ceiling the pool
# could not reach. Found on a live cluster; the values-level tests could not see
# it, because the values were right and the chart's own condition was the
# problem. Same shape as kubernetes_ingress_v1.n8n_mcp: render what the chart
# will not.
#
# Only created on the KEDA path. Off it, the chart's own HPA is correct and two
# controllers on one Deployment would fight over the replica count.
#
# Also gated on n8n_webhook_hpa_enabled, which is the input's whole documented
# purpose: "bring your own autoscaling policy". Off the KEDA path that worked,
# because the input feeds the chart's hpa.webhookProcessor.enabled and the
# chart honours it. On the KEDA path the chart ignores that value (its own
# template is gated on `not keda.enabled`) and this resource was ungated, so
# turning the input off removed nothing and a caller who attached their own
# VPA or custom-metrics HPA got it fighting this one over the same Deployment,
# which is the dual-ownership the KEDA branch is otherwise careful to avoid.
resource "kubernetes_horizontal_pod_autoscaler_v2" "n8n_webhook_processor" {
  count = var.k8s_keda_installed && var.n8n_webhook_hpa_enabled ? 1 : 0

  metadata {
    name      = "${local.n8n_webhook_service_name}-supplementary"
    namespace = local.namespace_name
    labels = {
      "app.kubernetes.io/name"       = "n8n"
      "app.kubernetes.io/component"  = "webhook-processor"
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = local.n8n_webhook_service_name
    }

    min_replicas = var.n8n_webhook_hpa_min_replicas
    max_replicas = var.n8n_webhook_hpa_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.n8n_webhook_hpa_cpu_threshold
        }
      }
    }

    # Matches the chart's own webhook behaviour block: a webhook burst needs
    # capacity now, and the default 300s stabilisation window would spend it
    # waiting.
    behavior {
      scale_up {
        stabilization_window_seconds = 0

        # Kubernetes' own defaults, restated because the provider requires at
        # least one policy once a behavior block is present.
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 15
        }

        policy {
          type           = "Pods"
          value          = 4
          period_seconds = 15
        }

        select_policy = "Max"
      }
    }
  }

  depends_on = [helm_release.n8n]
}
