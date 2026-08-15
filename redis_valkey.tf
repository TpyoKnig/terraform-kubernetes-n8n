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
}
