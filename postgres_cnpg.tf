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

# Resource requests/limits for the Cluster pod and, when enabled, the Pooler's
# pgbouncer container. Every quantity defaults to null, which renders no key
# at all: today's BestEffort scheduling, unchanged for a caller who sets
# nothing. Built as locals rather than inline so a single null check decides
# whether "resources" is rendered at all, never an empty {} that would still
# zero out the Cluster's inherited defaults.
locals {
  cnpg_resources_requests = merge(
    var.cnpg_cpu_request != null ? { cpu = var.cnpg_cpu_request } : {},
    var.cnpg_memory_request != null ? { memory = var.cnpg_memory_request } : {},
  )
  cnpg_resources_limits = merge(
    var.cnpg_cpu_limit != null ? { cpu = var.cnpg_cpu_limit } : {},
    var.cnpg_memory_limit != null ? { memory = var.cnpg_memory_limit } : {},
  )
  cnpg_resources = (length(local.cnpg_resources_requests) > 0 || length(local.cnpg_resources_limits) > 0) ? merge(
    length(local.cnpg_resources_requests) > 0 ? { requests = local.cnpg_resources_requests } : {},
    length(local.cnpg_resources_limits) > 0 ? { limits = local.cnpg_resources_limits } : {},
  ) : null

  cnpg_pooler_resources_requests = merge(
    var.cnpg_pooler_cpu_request != null ? { cpu = var.cnpg_pooler_cpu_request } : {},
    var.cnpg_pooler_memory_request != null ? { memory = var.cnpg_pooler_memory_request } : {},
  )
  cnpg_pooler_resources_limits = merge(
    var.cnpg_pooler_cpu_limit != null ? { cpu = var.cnpg_pooler_cpu_limit } : {},
    var.cnpg_pooler_memory_limit != null ? { memory = var.cnpg_pooler_memory_limit } : {},
  )
  cnpg_pooler_resources = (length(local.cnpg_pooler_resources_requests) > 0 || length(local.cnpg_pooler_resources_limits) > 0) ? merge(
    length(local.cnpg_pooler_resources_requests) > 0 ? { requests = local.cnpg_pooler_resources_requests } : {},
    length(local.cnpg_pooler_resources_limits) > 0 ? { limits = local.cnpg_pooler_resources_limits } : {},
  ) : null

  # Normalized to a common unit so a request can be compared against its
  # limit below: millicores for CPU, bytes for memory, using the same
  # suffix-multiplier maps redis_valkey.tf defines (locals are
  # module-scoped, not file-scoped). Both variables' own regex validation
  # has already rejected anything but the shapes handled here.
  cnpg_cpu_request_millicores = var.cnpg_cpu_request == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.cnpg_cpu_request)) *
    lookup({ m = 1 }, regex("[A-Za-z]*$", var.cnpg_cpu_request), 1000)
  )
  cnpg_cpu_limit_millicores = var.cnpg_cpu_limit == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.cnpg_cpu_limit)) *
    lookup({ m = 1 }, regex("[A-Za-z]*$", var.cnpg_cpu_limit), 1000)
  )
  cnpg_memory_request_bytes = var.cnpg_memory_request == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.cnpg_memory_request)) *
    lookup(local.memory_quantity_suffix_bytes, regex("[A-Za-z]*$", var.cnpg_memory_request), 1)
  )
  cnpg_memory_limit_bytes = var.cnpg_memory_limit == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.cnpg_memory_limit)) *
    lookup(local.memory_quantity_suffix_bytes, regex("[A-Za-z]*$", var.cnpg_memory_limit), 1)
  )

  cnpg_pooler_cpu_request_millicores = var.cnpg_pooler_cpu_request == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.cnpg_pooler_cpu_request)) *
    lookup({ m = 1 }, regex("[A-Za-z]*$", var.cnpg_pooler_cpu_request), 1000)
  )
  cnpg_pooler_cpu_limit_millicores = var.cnpg_pooler_cpu_limit == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.cnpg_pooler_cpu_limit)) *
    lookup({ m = 1 }, regex("[A-Za-z]*$", var.cnpg_pooler_cpu_limit), 1000)
  )
  cnpg_pooler_memory_request_bytes = var.cnpg_pooler_memory_request == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.cnpg_pooler_memory_request)) *
    lookup(local.memory_quantity_suffix_bytes, regex("[A-Za-z]*$", var.cnpg_pooler_memory_request), 1)
  )
  cnpg_pooler_memory_limit_bytes = var.cnpg_pooler_memory_limit == null ? null : (
    tonumber(regex("^[0-9]+(?:\\.[0-9]+)?", var.cnpg_pooler_memory_limit)) *
    lookup(local.memory_quantity_suffix_bytes, regex("[A-Za-z]*$", var.cnpg_pooler_memory_limit), 1)
  )

  # Whether cnpg_plugins declares at least one plugin with isWALArchiver =
  # true, the CNPG-I signal that a plugin claims the WAL archive command
  # (and is therefore a backup route, not just any entry on the list).
  # Shared between the collision check below and the no-backup-configured
  # check further down, which previously only tested cnpg_plugins != null.
  cnpg_has_wal_archiving_plugin = var.cnpg_plugins == null ? false : try(anytrue([for p in var.cnpg_plugins : try(p.isWALArchiver == true, false)]), false)
}

check "cnpg_resource_request_not_above_limit" {
  assert {
    # Outer guard ? body : true (local.cnpg_enabled), per AGENTS.md, wraps an
    # inner null guard ? true : body: on the external backend these four
    # inputs reach no Cluster or Pooler at all (variables.tf documents each
    # as "only used when postgres_backend = cnpg" / "cnpg_pooler_enabled"),
    # so a mismatched pair there is inert, not a real Kubernetes API
    # rejection, and must not fail the plan. Matches the gating every other
    # CNPG check in this file already uses (cnpg_pdb_blocks_the_postgres_node_drain,
    # cnpg_backup_needs_the_cnpg_backend, and the rest below).
    condition = alltrue([
      local.cnpg_enabled ? (
        (local.cnpg_cpu_request_millicores == null || local.cnpg_cpu_limit_millicores == null) ? true : (
          local.cnpg_cpu_request_millicores <= local.cnpg_cpu_limit_millicores
        )
      ) : true,
      local.cnpg_enabled ? (
        (local.cnpg_memory_request_bytes == null || local.cnpg_memory_limit_bytes == null) ? true : (
          local.cnpg_memory_request_bytes <= local.cnpg_memory_limit_bytes
        )
      ) : true,
      local.cnpg_enabled ? (
        (local.cnpg_pooler_cpu_request_millicores == null || local.cnpg_pooler_cpu_limit_millicores == null) ? true : (
          local.cnpg_pooler_cpu_request_millicores <= local.cnpg_pooler_cpu_limit_millicores
        )
      ) : true,
      local.cnpg_enabled ? (
        (local.cnpg_pooler_memory_request_bytes == null || local.cnpg_pooler_memory_limit_bytes == null) ? true : (
          local.cnpg_pooler_memory_request_bytes <= local.cnpg_pooler_memory_limit_bytes
        )
      ) : true,
    ])
    error_message = "One of cnpg_cpu_request/cnpg_cpu_limit, cnpg_memory_request/cnpg_memory_limit, cnpg_pooler_cpu_request/cnpg_pooler_cpu_limit or cnpg_pooler_memory_request/cnpg_pooler_memory_limit sets a request above its own limit. The Kubernetes API rejects that pod spec outright (\"must be less than or equal to cpu limit\" / the memory equivalent), so the Cluster or Pooler fails to reconcile at apply time rather than anything this module's own plan surfaces. Lower the request, raise the limit, or leave the limit null so the pod floats above the request instead."
  }
}

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

      # Always rendered, never optional, once any of the four sizing inputs is
      # set: without a request the database runs BestEffort, the first QoS
      # class the kubelet evicts under node pressure, while every n8n pod it
      # serves can carry one. Null at every input (the default) renders no
      # resources key at all, identical to today.
      local.cnpg_resources != null ? { resources = local.cnpg_resources } : {},

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

      # CNPG-I plugin declarations, passed through verbatim for the same
      # reason cnpg_backup is: this is the surface CNPG's backup story is
      # actively moving onto, and a typed input would freeze one snapshot of
      # it. The Barman Cloud Plugin's ObjectStore resource and the plugin's
      # own installation stay with the caller; the module renders only what
      # the Cluster spec itself carries. The whole path has been exercised
      # end to end against a real 1.30.0 operator: the list renders verbatim
      # on the Cluster, ContinuousArchiving goes True through the plugin, and
      # a `method: plugin` Backup completes into the bucket, all following
      # the docs/operations.md worked example with no deviation.
      var.cnpg_plugins == null ? {} : { plugins = var.cnpg_plugins },
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

# ── Postgres readiness barrier ────────────────────────────────────────────────
# kubectl_manifest applies the Cluster and returns. It does not wait, and it
# cannot: gavinbunney/kubectl 1.19 offers `wait` (deletion only) and
# `wait_for_rollout`, which speaks Deployment, StatefulSet and DaemonSet, and a
# CNPG Cluster is none of those. So `depends_on = [kubectl_manifest.cnpg_cluster]`
# on the n8n release is an edge that orders the two API calls and proves
# nothing about the database behind them.
#
# On a first apply that leaves n8n racing initdb. n8n pods start against a
# host with no endpoints, CrashLoopBackOff, and recover on their own once
# Postgres finishes, which is why this mostly goes unnoticed. When it does not
# finish in time (cold storage, a busy cluster, a slow image pull for the
# operand) the release's own wait expires instead, and because the release is
# atomic the whole install rolls back and reports a Helm timeout. The cause, a
# database that was still starting, appears nowhere in that error.
#
# This Job is the barrier the graph was missing. It polls the Cluster's rw
# Service with pg_isready until Postgres answers, so the n8n release cannot
# begin until the database is genuinely accepting connections. It also fails
# with a sentence naming Postgres rather than leaving the release to time out
# and blame Helm.
#
# The operand image is reused deliberately: pg_isready is in it, the cluster
# has already pulled it onto the node, and it introduces no image this
# deployment was not going to run anyway.
#
# Not a time_sleep. A sleep long enough to be safe on the slowest cluster is
# waste on every other one, and it would still be a guess rather than a
# condition: unlike the Pooler-Service-creation window n8n.tf's own comment
# on kubectl_manifest.cnpg_pooler argues a sleep is the wrong fix for, this
# barrier polls a real condition (pg_isready) rather than guessing a
# duration, so the objection there does not apply here. The ceiling on how
# long it polls before giving up is cnpg_ready_timeout, independent of
# n8n_helm_timeout: this Job completes, one way or the other, before
# helm_release.n8n's own wait even starts, so raising n8n_helm_timeout alone
# cannot buy a slow bootstrap more time here.
#
# Additive on every CNPG-backed deployment's first apply after adopting this:
# one new Job object, no change to any existing resource. Near-instant
# wherever CNPG is already up, since pg_isready then succeeds on the first
# attempt; it costs real wait time only on a genuinely cold cluster, which is
# exactly the race this closes.
resource "kubernetes_job_v1" "cnpg_ready" {
  count = local.cnpg_enabled ? 1 : 0

  metadata {
    name      = "${local.cnpg_cluster_name}-ready"
    namespace = local.namespace_name
  }

  spec {
    # One attempt. The container carries its own retry loop and its own
    # deadline, so a Job-level retry would only multiply a wait that has
    # already concluded the database is not coming.
    backoff_limit = 0

    # No ttl_seconds_after_finished, deliberately. The TTL controller deletes
    # the Job OBJECT, not just its completed pod, and a Job Terraform manages
    # but Kubernetes deletes is a permanent diff: some time after every apply
    # the refresh finds nothing and the next plan wants to create the Job
    # again, forever. The completed Job and its pod persist until a spec
    # change replaces them, which is one line of kubectl-get clutter in
    # exchange for a plan that stays at No changes.
    template {
      metadata {}

      spec {
        restart_policy = "Never"

        container {
          name  = "wait-for-postgres"
          image = "ghcr.io/cloudnative-pg/postgresql:${var.cnpg_postgres_image_tag}"

          command = [
            "/bin/sh",
            "-c",
            # replace() strips carriage returns, and it is load-bearing rather
            # than tidy. A heredoc carries this file's own line endings into
            # the string verbatim, and a CRLF checkout (e.g. git's default
            # core.autocrlf=true on Windows) would otherwise feed the
            # container's dash a `then\r` it does not recognise as the
            # keyword, dying on the script's own first `if`.
            replace(<<-EOT
              attempt=0
              until pg_isready -q -h '${local.cnpg_service_host}' -p 5432; do
                attempt=$((attempt + 1))
                if [ "$attempt" -ge ${floor(var.cnpg_ready_timeout / 2)} ]; then
                  echo "Postgres at ${local.cnpg_service_host} did not accept connections within ${var.cnpg_ready_timeout}s (cnpg_ready_timeout). The CloudNativePG Cluster ${local.cnpg_cluster_name} is still not serving: check 'kubectl get cluster -n ${local.namespace_name}' and the operator's logs. Raise cnpg_ready_timeout if this is a healthy cluster that bootstraps slowly rather than a wedged one." >&2
                  exit 1
                fi
                sleep 2
              done
            EOT
            , "\r", "")
          ]

          # Sized for a shell loop around pg_isready, and declared rather than
          # omitted so the Job still schedules in a namespace whose
          # ResourceQuota requires every container to state requests.
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          # Runs unprivileged so the Job still schedules if the caller puts a
          # restricted Pod Security Standard on the namespace. 26 is the
          # postgres user in the operand image.
          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 26
            capabilities { drop = ["ALL"] }
            seccomp_profile { type = "RuntimeDefault" }
          }
        }
      }
    }
  }

  wait_for_completion = true

  # Matches the script's own deadline (cnpg_ready_timeout) plus a 5-minute
  # buffer for Job scheduling and the image pull, the same margin the
  # original fixed 15m carried over the script's original fixed 10m.
  timeouts {
    create = "${var.cnpg_ready_timeout + 300}s"
  }

  depends_on = [kubectl_manifest.cnpg_cluster]
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
    spec = merge(
      {
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
      },

      # CNPG merges this template over the pod it generates, so naming the
      # pgbouncer container with only resources set sizes it without touching
      # anything else. Null at every pooler sizing input (the default)
      # renders no template key at all, identical to today's BestEffort
      # pooler. Once the pooler is on, every database connection runs through
      # these pods, which is why it is worth sizing deliberately.
      local.cnpg_pooler_resources != null ? {
        template = {
          spec = {
            containers = [
              {
                name      = "pgbouncer"
                resources = local.cnpg_pooler_resources
              },
            ]
          }
        }
      } : {},
    )
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

# The same shape of silence as cnpg_backup on the external path, for the same
# reason: the caller has declared a plugin, nothing renders a Cluster to carry
# it, and no error says so.
check "cnpg_plugins_need_the_cnpg_backend" {
  assert {
    condition     = var.cnpg_plugins != null ? local.cnpg_enabled : true
    error_message = "cnpg_plugins is set but postgres_backend is \"${var.postgres_backend}\", so this module renders no CloudNativePG Cluster and the value reaches nothing. Set postgres_backend = \"cnpg\" to use this input, or clear it to silence this warning."
  }
}

# The in-tree spec.backup.barmanObjectStore path works by running barman-cloud
# binaries inside the operand image, and upstream ships those only in the
# deprecated bare-tag `system` images. The minimal and standard images, which
# is what every qualified tag names and what the default tag now is, do not
# carry them: WAL archiving fails on every attempt, continuously, and the
# Cluster reports it only in its status conditions. The tag string is the one
# plan-time signal there is, so warn on the pairing rather than let the
# configuration read as done. Gated on barmanObjectStore being present, not on
# cnpg_backup alone: a backup stanza carrying only volumeSnapshot settings
# runs no barman-cloud and is fine on any image type.
#
# The first two halves of that story have been watched happen on a real
# cluster: ContinuousArchiving goes True on a bare-tag system image with the
# base backup and WAL segments landing in the bucket, and the default minimal
# tag fails every attempt with `"barman-cloud-check-wal-archive": executable
# file not found in $PATH`, reported in exactly that status condition and
# nowhere else while the database itself runs fine. The volumeSnapshot-only
# case is the one that same live pass caught the old over-broad condition
# mis-firing on — which is why the gate reads barmanObjectStore rather than
# cnpg_backup alone; its warning-free plan is pinned by the mocked suite.
check "cnpg_backup_needs_barman_in_the_image" {
  assert {
    condition     = local.cnpg_enabled && try(var.cnpg_backup.barmanObjectStore != null, false) ? !can(regex("-(minimal|standard)(-|$)", var.cnpg_postgres_image_tag)) : true
    error_message = "cnpg_backup carries barmanObjectStore, the in-tree form that archives WAL by running barman-cloud binaries inside the Postgres image, and cnpg_postgres_image_tag = \"${var.cnpg_postgres_image_tag}\" names a minimal or standard image that does not carry them. Archiving will fail on every attempt, visible only in the Cluster's status conditions. Either use the Barman Cloud Plugin instead (cnpg_plugins, plus its ObjectStore resource), or pin a deprecated bare-tag system image such as \"16\" for as long as upstream still publishes it."
  }
}

# The other half of the same collision, checked rather than only documented:
# barmanObjectStore in spec.backup and a plugin declaring isWALArchiver both
# claim the WAL archive command, and which one the operator ends up running
# is not a choice the caller gets to make. Nothing at apply time refuses the
# combination either; it just resolves somehow.
check "cnpg_backup_and_a_wal_archiving_plugin_conflict" {
  assert {
    condition     = !(local.cnpg_enabled && try(var.cnpg_backup.barmanObjectStore != null, false) && local.cnpg_has_wal_archiving_plugin)
    error_message = "cnpg_backup carries barmanObjectStore and cnpg_plugins declares a plugin with isWALArchiver = true; both claim the WAL archive command, and which one wins is not yours to choose. Keep exactly one: clear barmanObjectStore from cnpg_backup to archive through the plugin, or drop the plugin's isWALArchiver to stay on the in-tree path."
  }
}

# ── Diagnostic: Postgres connection budget vs. known max_connections ─────────
# Opt-in (postgres_connection_budget_check_enabled, default false): the
# module's own default autoscaler ceilings already exceed the stock
# PostgreSQL default of 100, so this stays off until a caller has settled on
# both a database size and replica ceilings and wants this advisory guard
# against a later regression.
#
# Unlike the GCP and Azure siblings, this module never has to guess
# max_connections from an instance-type or SKU table: on the cnpg path the
# Cluster this file renders always sets spec.postgresql.parameters.
# max_connections to cnpg_max_connections (see kubectl_manifest.cnpg_cluster
# above), so that input IS the known value, exactly. On the external path the
# module manages nothing on the server, so the model falls back to
# PostgreSQL's own stock default of 100 rather than staying silent, which is
# the one place this check departs from its siblings: it still gives an
# answer instead of declining to guess.
#
# db_postgresdb_pool_size's own description already asks callers to budget
# this arithmetic by hand: pool size times the modeled replica ceiling,
# against max_connections. This check does that arithmetic at plan time.
#
# Reused directly from scaling.tf's own demand model rather than duplicated:
# main never scales past 1 (no multiMain, no hpa.main in this module's
# always-single-main topology), worker's ceiling is
# n8n_worker_keda_max_replicas regardless of whether KEDA or the chart's CPU
# HPA is driving it, and webhook processor's is n8n_webhook_hpa_max_replicas
# regardless of n8n_webhook_hpa_enabled, matching
# local.n8n_peak_cpu_request_millis's own unconditional use of both.
#
# Gaps that make a silent check not proof the ceilings fit:
#   - The CNPG Cluster is managed without ignore_changes on postgresql.parameters,
#     so a max_connections set outside Terraform is overwritten on the next
#     apply rather than invisible, but a value changed and not yet re-applied
#     disagrees with this model until the next plan.
#   - PostgreSQL carves superuser_reserved_connections out of max_connections
#     (3 by default), and CNPG's own instance manager, replication and
#     metrics connections take more; none of that is subtracted here.
#   - The model counts configured steady-state ceilings, not a rolling
#     update's transient extra pod.
#   - With n8n_webhook_hpa_enabled = false the chart's own autoscaling is
#     replaced by nothing this module tracks; a caller-owned autoscaler can
#     scale past n8n_webhook_hpa_max_replicas, and the model still uses it as
#     the ceiling.
#   - The model assumes every pod connects directly to the Cluster. Behind
#     cnpg_pooler_enabled, the Pooler sets the number of real server
#     connections (cnpg_pooler_pool_size x cnpg_pooler_instances, itself
#     validated against cnpg_max_connections above), so this model does not
#     apply and the check should stay off.
locals {
  postgres_known_max_connections = local.cnpg_enabled ? var.cnpg_max_connections : 100

  n8n_postgres_peak_connections = var.db_postgresdb_pool_size * (
    1 +
    var.n8n_worker_keda_max_replicas +
    var.n8n_webhook_hpa_max_replicas
  )
}

check "postgres_pool_size_fits_known_max_connections" {
  assert {
    condition = (var.postgres_connection_budget_check_enabled && !local.cnpg_pooler_enabled) ? (
      local.n8n_postgres_peak_connections <= local.postgres_known_max_connections
    ) : true
    error_message = join("", [
      "db_postgresdb_pool_size (${var.db_postgresdb_pool_size}) times the modeled replica ceiling ",
      "(1 main + ${var.n8n_worker_keda_max_replicas} worker + ${var.n8n_webhook_hpa_max_replicas} webhook processor) ",
      "demands up to ${local.n8n_postgres_peak_connections} connections at full scale-out, more than ",
      local.cnpg_enabled ? "cnpg_max_connections (${local.postgres_known_max_connections})." : "PostgreSQL's own stock default max_connections (100) on the external path, which this module does not manage and cannot raise for you.",
      " Lower db_postgresdb_pool_size, lower the replica ceilings (n8n_worker_keda_max_replicas, n8n_webhook_hpa_max_replicas), ",
      local.cnpg_enabled ? "or raise cnpg_max_connections (or turn on cnpg_pooler_enabled, which removes pod count from the arithmetic entirely)." : "or raise max_connections on the external server and keep it in sync with this check by hand.",
      " This diagnostic is advisory and does not fail the plan.",
    ])
  }
}

# Advisory, never failing a plan: docs/operations.md has said "no backups by
# default" since the Backups section existed, and a warning in the docs is
# read once while a warning in the plan is read every time. Silenced by
# fixing the thing (either backup input) or by cnpg_backup_acknowledged,
# which records that the trade was deliberate.
#
# cnpg_plugins is checked for a declared WAL archiver specifically, not just
# non-null: the CNPG-I plugin interface covers more than backups, so a
# plugin list with none of its entries carrying isWALArchiver = true leaves
# a cluster exactly as unbacked as an empty one, and silently passing it
# here would be the worse failure mode cubic flagged.
check "cnpg_has_no_backup_configured" {
  assert {
    condition = local.cnpg_enabled && var.cnpg_backup_acknowledged == null ? !(
      var.cnpg_backup == null && !local.cnpg_has_wal_archiving_plugin
    ) : true
    error_message = "postgres_backend = \"cnpg\" with neither cnpg_backup nor a WAL-archiving entry in cnpg_plugins (isWALArchiver = true) set, so this deployment has no backups. The database's only copy is its PVC, and between you and every workflow, credential and execution it holds are a `terraform destroy` and a StorageClass whose reclaim policy is probably Delete. Losing the node or the volume loses the instance. Set cnpg_backup for the in-tree barmanObjectStore path, or cnpg_plugins for the Barman Cloud Plugin, which is where CloudNativePG's backup surface is moving; docs/operations.md has a worked example of both, including the Backup or ScheduledBackup resource that takes the base backup and stays yours to create. If the volumes are snapshotted by something outside this module, or this is a scratch deployment where losing the database costs nothing, set cnpg_backup_acknowledged to true or false to silence this without configuring either backup input."
  }
}
