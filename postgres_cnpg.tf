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
    spec = merge(
      {
        instances = var.cnpg_instances
        imageName = "ghcr.io/cloudnative-pg/postgresql:${var.cnpg_postgres_image_tag}"

        # CloudNativePG creates a PodDisruptionBudget over the primary unless
        # told not to, and at cnpg_instances = 1, this module's default, that
        # object is minAvailable = 1 against a single pod: allowedDisruptions
        # is 0 and the node hosting Postgres can never be drained. Found on a
        # live cluster after the chart's own main-pod PDB was disabled for
        # exactly the same reason; disabling one and leaving the other still
        # leaves a node that a Talos upgrade stalls on.
        #
        # The default follows the instance count rather than being a flat
        # false, because the two cases genuinely differ. With replicas, the
        # budget does what a budget is for: it stops a second Postgres node
        # being drained while the first is still coming back, and CNPG will
        # still let replicas be evicted. With one instance there is no second
        # copy to protect, so the object cannot preserve availability and can
        # only withhold it.
        enablePDB = var.cnpg_pdb_enabled != null ? var.cnpg_pdb_enabled : var.cnpg_instances > 1

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
      },

      # Continuous WAL archiving and the object store behind it, passed through
      # verbatim. Omitted entirely when null, which is the default and is what
      # this Cluster has always been: a database whose only copy is its PVC.
      #
      # Passthrough rather than a typed surface, which is a deliberate
      # exception to how this module treats every other input. CNPG is moving
      # this exact field from the in-tree spec.backup.barmanObjectStore to the
      # Barman Cloud Plugin, and the spelling that is correct depends on the
      # operator version the caller installed, which the module has no way to
      # read. A typed API here would encode one of the two and be confidently
      # wrong on the other half of the installed base. See var.cnpg_backup and
      # docs/operations.md for the two shapes and a worked example.
      var.cnpg_backup == null ? {} : { backup = var.cnpg_backup },
    )
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
  # Unlike KEDA there is no attestation input for it either, and the ways it
  # can be missing are worth telling apart, because only one of them is quiet.
  #
  #   - Nothing installed. The CRD is gone with the operator, so this apply
  #     fails outright with the API server naming the unknown kind. The error
  #     already says what is wrong.
  #   - Operator scaled down or crash-looping with its webhook configurations
  #     still registered. CNPG's admission webhooks fail closed, so the API
  #     server rejects this manifest with a webhook call failure rather than
  #     applying it. Loud, if cryptic.
  #   - CRD present and no webhook configuration to answer for it: an operator
  #     uninstalled leaving its CRDs behind, or a partial install. Here the
  #     manifest applies cleanly, nothing reconciles it, and the apply reports
  #     success. This is the KEDA-shaped failure, and this module does not
  #     detect it.
  #
  # In that last case a Cluster being created for the first time gets no
  # Postgres pods and no Service; a Cluster the operator had already reconciled
  # keeps its running pods and Service and simply stops having changes acted
  # on. The tell is the absence of a controller: no CNPG controller pod running
  # in whichever namespace the operator was installed into, cnpg-system by
  # convention rather than by rule. Check that directly rather than reading the
  # Cluster's status, because `status` is a persisted field on the resource and
  # nothing clears it when the operator goes: a cluster that was healthy when
  # the operator was removed still reports `readyInstances` equal to
  # `spec.instances` while nothing is reconciling it. A short or absent
  # `readyInstances` narrows it down on a Cluster that never came up, but its
  # being correct proves nothing.
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

# The same failure main_pdb_blocks_the_main_pod_node_drain warns about, one
# layer down. CNPG's budget is minAvailable = 1 over the primary, so forcing it
# on for a single-instance cluster is allowed disruptions of zero for the life
# of the deployment. Only the explicit true is warned about: the null default
# already resolves to false at one instance, so nobody arrives here by accident.
check "cnpg_pdb_blocks_the_postgres_node_drain" {
  assert {
    condition     = local.cnpg_enabled && var.cnpg_pdb_enabled == true ? var.cnpg_instances > 1 : true
    error_message = "cnpg_pdb_enabled is true with cnpg_instances = ${var.cnpg_instances}, so CloudNativePG maintains a PodDisruptionBudget of minAvailable = 1 over a single Postgres pod. Allowed disruptions is then zero permanently: `kubectl drain` on the node holding it never completes, and a Talos node upgrade stalls in drain rather than failing, which reads as a hung upgrade rather than a policy decision. A budget keeps N replicas up while a node goes away, and with one instance there is no N to keep. Leave cnpg_pdb_enabled null to let the instance count decide, or raise cnpg_instances above 1 so the budget has a replica to protect."
  }
}

# cnpg_backup is read only by the Cluster this file renders, and that Cluster is
# not created on the external path. Silence there costs more than most: the
# caller has written a destination and a credentials Secret, so the
# configuration reads as done, and what they have is a database with no
# archiving that nothing will tell them about until they need a restore.
check "cnpg_backup_needs_the_cnpg_backend" {
  assert {
    condition     = var.cnpg_backup != null ? local.cnpg_enabled : true
    error_message = "cnpg_backup is set but postgres_backend is \"${var.postgres_backend}\", so this module renders no CloudNativePG Cluster and the value reaches nothing. Backing up an external database is the operator's own business, whatever runs it. Set postgres_backend = \"cnpg\" to use this input, or clear it to silence this warning."
  }
}
