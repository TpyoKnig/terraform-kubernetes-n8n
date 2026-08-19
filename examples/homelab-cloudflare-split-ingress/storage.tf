# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Shared storage across the three pod types ─────────────────────────────────
# Queue mode runs main, worker and webhook-processor pods, and they do not share
# a filesystem. The chart mounts its own `data` volume on main only, and this
# module leaves persistence at the chart default, so that volume is an emptyDir:
# it does not survive a restart and the other two pod types cannot see it.
#
# That matters as soon as a workflow moves a file. A webhook arrives on one pod,
# the execution runs on a worker, and the editor renders the result on a third.
# Anything written to local disk by one is invisible to the other two.
#
# An RWX claim mounted into all three closes it. Off unless shared_storage_class
# is set: leave it null and binary data stays in Postgres, which is n8n's own
# default in queue mode and is fine until payloads get large. Set it and main.tf
# switches n8n to filesystem mode against the shared volume.
#
# ── Why the namespace moves here when the claim exists ───────────────────────
# The claim has to exist before the Helm release: a pod referencing a missing
# PVC stays Pending and the release never goes ready. The claim needs a
# namespace, so the order is namespace, claim, module. create_namespace = false
# exists for exactly this, and the ordering is carried by the reference itself:
# main.tf passes this claim's name into n8n_extra_volumes, which is an edge
# Terraform cannot reorder. No depends_on on the module block, deliberately, for
# the reason spelled out there.
#
# With shared_storage_class unset, neither resource is created and the module
# creates the namespace itself as before.

# Owned here unconditionally, and that is the fix for a trap rather than a
# preference. It used to be created only when shared_storage_class was set, with
# the module creating it otherwise. Turning shared storage on for an existing
# deployment therefore moved the namespace between two resource addresses in one
# apply: Terraform has no reason to sequence that safely, so it either created
# the new one first and failed AlreadyExists, or destroyed the module-owned one
# first and took n8n, CloudNativePG, Valkey and every PVC in the namespace with
# it. Nothing in the plan output reads as "this deletes your database".
#
# One owner, always, and the flip has nothing left to move.
#
# Existing deployments migrate once, and only those that never set
# shared_storage_class, because the others already have the namespace here:
#
#   terraform state mv #     'module.n8n.kubernetes_namespace.n8n[0]' #     'kubernetes_namespace.n8n'
#
# Without it the first apply after upgrading plans exactly the destroy-and-
# recreate described above. Check for it: a plan that proposes to destroy a
# namespace is never routine.
resource "kubernetes_namespace" "n8n" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_persistent_volume_claim_v1" "shared" {
  count = var.shared_storage_class != null ? 1 : 0

  metadata {
    name      = "n8n-shared"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = var.shared_storage_class

    resources {
      requests = {
        storage = var.shared_storage_size
      }
    }
  }

  # A WaitForFirstConsumer class does not bind a claim until a pod consumes it,
  # and the pod cannot exist yet: the Helm release is downstream of this claim,
  # by way of the n8n_extra_volumes reference in main.tf. Waiting here is
  # therefore a deadlock against exactly the classes people reach for, and it
  # ends as a five minute timeout blaming the claim.
  #
  # Not waiting costs the diagnosis the old comment wanted. A class that never
  # binds now surfaces one step later, as pods stuck Pending and a release wait
  # that expires, which is a worse message than this resource could have given
  # but is at least reached on every class rather than on half of them. Check
  # VOLUMEBINDINGMODE before blaming the storage:
  #
  #   kubectl get storageclass <name> -o jsonpath='{.volumeBindingMode}'
  wait_until_bound = false

  timeouts {
    create = "5m"
  }
}

# Note on destroy: this claim holds binary data, and `terraform destroy` takes
# it along with the namespace. If that data matters, set the class's
# reclaimPolicy to Retain so the underlying volume survives the PVC, or keep the
# claim in a separate configuration from the workload. prevent_destroy is not
# the answer: it would make `terraform destroy` fail outright rather than
# protect anything, since the namespace deletion removes the claim regardless.
