# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── CNPG-managed Postgres cluster ─────────────────────────────────────────────
# Only created when postgres_backend = "cnpg". Requires the CloudNativePG
# operator installed cluster-wide (the module does not install it, CNPG is a
# cluster capability, not an app dependency). CNPG bootstraps the app-user
# credentials into a Secret named "<cluster>-app" which the k8s-backend n8n
# chart consumes via database.passwordSecret (see local.k8s_values_database
# in locals.tf).
#
# Applied through gavinbunney/kubectl rather than hashicorp/kubernetes_manifest,
# which is this module's default for every custom resource (see AGENTS.md).
# kubernetes_manifest resolves the resource's schema against a live cluster API
# at *plan* time, so `terraform plan` fails outright wherever the API is
# unreachable, CI, a laptop off the LAN, any review that isn't sitting on the
# cluster, and it reverts the CNPG mutating webhook's own defaults unless every
# injected subtree is enumerated in `computed_fields`. kubectl_manifest defers
# schema resolution to apply time and diffs only the fields this manifest
# actually sets, so the operator's writes are left alone without an allowlist to
# maintain against every CNPG release.

resource "kubectl_manifest" "cnpg_cluster" {
  count = local.cnpg_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.cnpg_cluster_name
      namespace = local.namespace_name
    }
    spec = {
      instances = var.cnpg_instances
      imageName = "ghcr.io/cloudnative-pg/postgresql:${var.cnpg_postgres_image_tag}"

      bootstrap = {
        initdb = {
          database = var.cnpg_database_name
          owner    = var.cnpg_database_owner
        }
      }

      storage = merge(
        { size = var.cnpg_storage_size },
        length(var.cnpg_storage_class) > 0 ? { storageClass = var.cnpg_storage_class } : {},
      )

      postgresql = {
        parameters = {
          max_connections = "200"
        }
      }
    }
  })

  # Server-side apply keeps the operator as the field manager for everything
  # this manifest does not set, which is what makes the computed_fields
  # allowlist unnecessary.
  server_side_apply = true

  # CRD must exist before this applies. The module does not install the CNPG
  # operator; that is a cluster-wide prerequisite the caller confirms via
  # existing_eks_cluster_prerequisites_confirmed (analogously to the
  # BYO-cluster path).
  depends_on = [kubernetes_namespace.n8n]
}
