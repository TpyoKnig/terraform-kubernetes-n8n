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
          max_connections = tostring(var.cnpg_max_connections)
        }
      }
    }
  })

  # Server-side apply keeps the operator as the field manager for everything
  # this manifest does not set, which is what makes the computed_fields
  # allowlist unnecessary.
  server_side_apply = true

  # The Cluster CRD must exist before this applies. The module does not install
  # the CloudNativePG operator, for the reason AGENTS.md gives for every
  # cluster-wide operator: it is a singleton serving every workload on the
  # cluster, and a module that installed one would own upgrading and destroying
  # it on behalf of workloads it cannot see.
  #
  # Unlike KEDA there is no attestation input for it either, and the two
  # failures are worth telling apart. With nothing installed at all the CRD is
  # missing too, so this apply fails outright with the API server naming the
  # unknown kind, and the error already says what is wrong. With the CRD
  # present but the operator absent or unavailable, the manifest applies
  # cleanly and nothing reconciles it, and the apply reports success. On a
  # Cluster being created for the first time that means no Postgres pods and no
  # Service at all; on one the operator had already reconciled, the running
  # pods and Service stay up and it is changes that stop being acted on. That
  # case looks exactly like the KEDA one and this module does not detect it.
  # The tell is a Cluster whose status does not match its spec, and no running
  # controller pod in the operator's namespace (`kubectl get pods -n
  # cnpg-system`; the deployment's name depends on how it was installed).
  #
  # (An earlier version of this comment cited
  # existing_eks_cluster_prerequisites_confirmed, an input that belongs to this
  # module's AWS sibling and has never existed here.)
  depends_on = [kubernetes_namespace.n8n]
}

# ── PgBouncer connection pooler ───────────────────────────────────────────────
# Only created when cnpg_pooler_enabled and the CNPG backend is selected. The
# Pooler is a CloudNativePG resource attached to the Cluster above: the caller
# owns the operator, the module owns what that operator reconciles for this
# workload. Same split as the worker ScaledObject and KEDA.
#
# What it is for. Every n8n pod holds db_postgresdb_pool_size persistent
# connections, so the connection budget is pod count times pool size, and pod
# count is set by an autoscaler. The Cluster above runs cnpg_max_connections,
# less superuser_reserved_connections, so a worker tier scaling to 16 beside a
# webhook-processor tier scaling to 8, at the default pool size of 10, asks for
# 250 against roughly 197 available. Past that limit new pods do not degrade,
# they fail to initialise their pool, exit non-zero and CrashLoop, and in-flight
# webhook requests stall rather than erroring. Raising max_connections moves the
# wall to the next scale-up; lowering the per-pod pool trades it for less
# per-pod concurrency. A pooler removes the coupling instead: Postgres sees
# cnpg_pooler_pool_size x cnpg_pooler_instances connections no matter how far
# the tiers scale.
#
# Measured on a 5-node lab cluster before and after, at the same offered rate:
# peak backends went from pinning at exactly the 197 available to a flat 61-63
# regardless of load, and delivered throughput rose about 1.5x.
resource "kubectl_manifest" "cnpg_pooler" {
  count = local.cnpg_pooler_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Pooler"
    metadata = {
      name      = local.cnpg_pooler_name
      namespace = local.namespace_name
    }
    spec = {
      cluster   = { name = local.cnpg_cluster_name }
      instances = var.cnpg_pooler_instances
      type      = "rw"

      pgbouncer = {
        poolMode = var.cnpg_pooler_mode

        # PgBouncer wants strings, and yamlencode would otherwise render these
        # as YAML integers against a field CNPG types as map[string]string.
        parameters = {
          max_client_conn   = tostring(var.cnpg_pooler_max_client_conn)
          default_pool_size = tostring(var.cnpg_pooler_pool_size)
        }
      }
    }
  })

  server_side_apply = true

  # CNPG provisions the cnpg_pooler_pgbouncer auth role into the Cluster when
  # the Pooler appears, so the Cluster has to exist first.
  depends_on = [kubectl_manifest.cnpg_cluster]
}
