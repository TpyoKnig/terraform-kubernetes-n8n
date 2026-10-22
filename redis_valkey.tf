# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Valkey (BSD-licensed Redis fork) ──────────────────────────────────────────
# Only rendered when redis_backend = "valkey". Wire-compatible with Redis so
# n8n's Bull queue works unchanged. Image source is docker.io/valkey/valkey,
# not tied to Bitnami's deprecated Docker Hub distribution.

# Null at every input (the default) renders no resources key at all, today's
# BestEffort scheduling unchanged. See postgres_cnpg.tf's matching locals for
# the same shape against the Cluster and the Pooler.
locals {
  valkey_resources_requests = merge(
    var.valkey_cpu_request != null ? { cpu = var.valkey_cpu_request } : {},
    var.valkey_memory_request != null ? { memory = var.valkey_memory_request } : {},
  )
  valkey_resources_limits = merge(
    var.valkey_cpu_limit != null ? { cpu = var.valkey_cpu_limit } : {},
    var.valkey_memory_limit != null ? { memory = var.valkey_memory_limit } : {},
  )
  valkey_resources = (length(local.valkey_resources_requests) > 0 || length(local.valkey_resources_limits) > 0) ? merge(
    length(local.valkey_resources_requests) > 0 ? { requests = local.valkey_resources_requests } : {},
    length(local.valkey_resources_limits) > 0 ? { limits = local.valkey_resources_limits } : {},
  ) : null
  # Maps a Kubernetes memory quantity's trailing suffix to its byte
  # multiplier; an empty suffix (plain bytes) falls through to the lookup()
  # default of 1 below. Shared with postgres_cnpg.tf's matching locals,
  # since locals are module-scoped, not file-scoped.
  memory_quantity_suffix_bytes = {
    Ki = 1024
    Mi = 1024 * 1024
    Gi = 1024 * 1024 * 1024
    Ti = 1024 * 1024 * 1024 * 1024
    k  = 1000
    M  = 1000 * 1000
    G  = 1000 * 1000 * 1000
    T  = 1000 * 1000 * 1000 * 1000
  }

  # Normalized to a common unit so a request can be compared against its
  # limit below: millicores for CPU, bytes for memory. Both variables'
  # own regex validation has already rejected anything but the shapes
  # handled here (a number, optionally followed by one Kubernetes
  # suffix), so the lookups below never miss.
  valkey_cpu_request_millicores = var.valkey_cpu_request == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.valkey_cpu_request)) *
    lookup({ m = 1 }, regex("[A-Za-z]*$", var.valkey_cpu_request), 1000)
  )
  valkey_cpu_limit_millicores = var.valkey_cpu_limit == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.valkey_cpu_limit)) *
    lookup({ m = 1 }, regex("[A-Za-z]*$", var.valkey_cpu_limit), 1000)
  )
  valkey_memory_request_bytes = var.valkey_memory_request == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.valkey_memory_request)) *
    lookup(local.memory_quantity_suffix_bytes, regex("[A-Za-z]*$", var.valkey_memory_request), 1)
  )
  valkey_memory_limit_bytes = var.valkey_memory_limit == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.valkey_memory_limit)) *
    lookup(local.memory_quantity_suffix_bytes, regex("[A-Za-z]*$", var.valkey_memory_limit), 1)
  )
}

check "valkey_resource_request_not_above_limit" {
  assert {
    # guard ? true : body, per AGENTS.md: this module's floor (>= 1.11) does
    # not short-circuit ||, so the comparison on the right must never run
    # while either side is null.
    condition = alltrue([
      (local.valkey_cpu_request_millicores == null || local.valkey_cpu_limit_millicores == null) ? true : (
        local.valkey_cpu_request_millicores <= local.valkey_cpu_limit_millicores
      ),
      (local.valkey_memory_request_bytes == null || local.valkey_memory_limit_bytes == null) ? true : (
        local.valkey_memory_request_bytes <= local.valkey_memory_limit_bytes
      ),
    ])
    error_message = "valkey_cpu_request/valkey_cpu_limit or valkey_memory_request/valkey_memory_limit set a request above its own limit. The Kubernetes API rejects that pod spec outright (\"must be less than or equal to cpu limit\" / the memory equivalent), so the Valkey Helm release fails at apply time with a validating-webhook error rather than anything this module's own plan surfaces. Lower the request, raise the limit, or leave the limit null so the pod floats above the request instead."
  }
}

resource "random_password" "valkey_default" {
  count   = local.valkey_enabled ? 1 : 0
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "valkey_auth" {
  count = local.valkey_enabled ? 1 : 0

  metadata {
    name      = local.valkey_secret_name
    namespace = local.namespace_name
  }

  # Two keys, same value:
  #  - "default"        : looked up by the valkey chart for its default ACL user
  #  - "redis-password" : looked up by n8n chart (redis.passwordSecret.key)
  data = {
    default          = random_password.valkey_default[0].result
    "redis-password" = random_password.valkey_default[0].result
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.n8n]
}

resource "helm_release" "valkey" {
  count = local.valkey_enabled ? 1 : 0

  name       = local.valkey_release
  repository = var.valkey_chart_repository
  chart      = "valkey"
  version    = var.valkey_chart_version
  namespace  = local.namespace_name

  create_namespace = false

  values = [
    yamlencode(merge(
      {
        auth = {
          enabled             = true
          usersExistingSecret = local.valkey_secret_name
          aclUsers = {
            default = {
              permissions = "~* &* +@all"
            }
          }
        }

        dataStorage = merge(
          {
            enabled       = true
            requestedSize = var.valkey_storage_size
          },
          length(var.valkey_storage_class) > 0 ? { className = var.valkey_storage_class } : {},
        )

        # Standalone by default (replica.enabled defaults to false in the chart).
        # Bull queue needs one endpoint; replication adds complexity without
        # queue-mode benefit. Enable via n8n_extra_helm_values if truly needed.

        # Not the chart default, which is RollingUpdate. In standalone mode the
        # chart renders a Deployment whose data PVC is ReadWriteOnce, so a
        # rolling update starts the new pod before the old one releases the
        # volume: the new pod deadlocks on a Multi-Attach error and the
        # rollout hangs until someone deletes a pod by hand. Recreate is the
        # only strategy that can work against a single-attach volume, so it is
        # not an input. Changing only a Deployment's strategy.type never
        # restarts anything by itself (Kubernetes rolls pods on a pod-template
        # change, not a strategy-preference change), so adopting this fix
        # alone is quiet; it only matters the next time something does change
        # the template.
        deploymentStrategy = "Recreate"

        service = {
          type = "ClusterIP"
          port = 6379
        }
      },

      # Appended after the chart's generated config, where last-wins applies.
      # The generated file carries no persistence directives at all, so
      # without this the server runs its built-in defaults: RDB snapshots
      # only, appendonly no, and a crash between snapshots silently drops
      # every queued job accepted since the last one. See
      # var.valkey_append_only_enabled for the full story; false (the
      # default) renders the chart's empty default and stays snapshot-only.
      var.valkey_append_only_enabled ? {
        valkeyConfig = "appendonly yes\nappendfsync everysec\n"
      } : {},

      # Restarts the server when the generated password rotates, so the new
      # ACL file is actually loaded. Valkey reads users.acl once at start; the
      # kubelet refreshing the Secret mount changes the file on disk and
      # nothing reloads it, so without this a rotation leaves the server on
      # the old ACL until an unrelated restart. The n8n release carries the
      # same checksum (local.k8s_values_pod_annotations), which is what makes
      # rotation one apply instead of a split-brain armed for the next restart
      # on either side. Top-level podAnnotations is documented in valkey-helm
      # 0.12.0, the pinned default. The hash, never the password: annotations
      # are world-readable to anyone who can get the pod.
      #
      # Opt-in (var.valkey_password_rotation_roll_enabled, default false), not
      # unconditional like deploymentStrategy above: introducing this key into
      # podAnnotations for the first time IS a pod-template change, and
      # deploymentStrategy = "Recreate" means that first change takes Valkey
      # fully down and back up rather than overlapping, since the standalone
      # PVC is ReadWriteOnce. A caller who has rotated nothing and asked for
      # nothing should not eat that outage as a side effect of a module
      # upgrade; one who wants rotation to roll pods turns this on and accepts
      # the same one-time cost deliberately.
      var.valkey_password_rotation_roll_enabled ? {
        podAnnotations = {
          "checksum/valkey-password" = sha256(random_password.valkey_default[0].result)
        }
      } : {},

      # Always rendered, never optional, once any of the four sizing inputs is
      # set. Kubernetes defaults an omitted request to its limit when only a
      # limit is given, so the pod only runs BestEffort, the first QoS class
      # the kubelet evicts under node pressure, while every n8n pod it serves
      # can carry one, when none of the four is set at all. An explicit
      # request is what pins a stronger class (Burstable, or Guaranteed when
      # every request equals its limit) rather than leaving it to that
      # default.
      local.valkey_resources != null ? { resources = local.valkey_resources } : {},
    ))
  ]

  depends_on = [
    kubernetes_namespace.n8n,
    kubernetes_secret_v1.valkey_auth,
  ]

  timeout = var.valkey_helm_timeout
  wait    = true

  # The same pair helm_release.n8n carries, and for the same reason. The two
  # flags cover different operations, and only one of them addresses the
  # failure this release actually hit, so they are worth telling apart rather
  # than treating as a pair that does one thing.
  #
  # atomic is the install-side fix, and does all of the work here. Without it
  # an install that exceeds the timeout leaves the release in the cluster while
  # Terraform records no state for it, so every later apply fails with "cannot
  # re-use a name that is still in use" and needs a manual `helm uninstall`
  # before it can proceed. atomic purges the failed install instead, leaving
  # nothing to collide with. The n8n release was given it after exactly that
  # happened; this one was left behind. helm_release.n8n sits behind an
  # explicit depends_on on this release, so a wedged Valkey does at least fail
  # loudly under its own name: the apply that strands it reports this
  # release's timeout, and every later one fails on the occupied release name
  # before the n8n release is attempted. What the stranding costs is that no
  # apply can proceed at all until someone runs the manual uninstall.
  #
  # The install-side fix has since been watched doing its job on a real
  # cluster: a deliberately failed install (a StorageClass that does not
  # exist, so the PVC sat Pending into the timeout) ended with Helm reporting
  # the release "uninstalled due to atomic being set", an empty
  # `helm list -a`, and the corrected apply creating the release in seconds
  # with no name collision.
  #
  # cleanup_on_fail is upgrade-only: "allow deletion of new resources created
  # in this upgrade when upgrade fails", in the provider's own words. Helm's
  # install action has no such option at all. It does nothing for the failure
  # above, and is set because a failed upgrade should not leave behind objects
  # belonging to a revision that was rolled back. Dropping atomic and keeping
  # this one would restore the original wedge in full.
  #
  # What atomic costs, since it is the one carrying the weight: it also rolls
  # a failed or timed-out upgrade back to the previous revision rather than
  # leaving it half-applied. That is the behaviour worth having on a queue, but
  # it is a trade rather than a cure. A rollback that itself fails or times
  # out is recorded by Helm as a failed revision: `helm history` shows the
  # sequence, and a manual `helm rollback` recovers it. The stuck
  # pending-rollback state, whose later applies fail with "another operation
  # (install/upgrade/rollback) is in progress", arises only when the process
  # is killed mid-rollback, not from the timeout. helm_release.n8n has carried
  # that same exposure since it got the pair, so this adds no new kind of
  # failure, only the same one on a second release.
  atomic          = true
  cleanup_on_fail = true
}
