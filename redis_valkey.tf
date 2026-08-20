# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Valkey (BSD-licensed Redis fork) ──────────────────────────────────────────
# Only rendered when redis_backend = "valkey". Wire-compatible with Redis so
# n8n's Bull queue works unchanged. Image source is docker.io/valkey/valkey,
# not tied to Bitnami's deprecated Docker Hub distribution.

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
    yamlencode({
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

      service = {
        type = "ClusterIP"
        port = 6379
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.n8n,
    kubernetes_secret_v1.valkey_auth,
  ]

  timeout = 600
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
