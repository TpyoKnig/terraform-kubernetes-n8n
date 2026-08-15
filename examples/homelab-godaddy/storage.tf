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

resource "kubernetes_namespace" "n8n" {
  count = var.shared_storage_class != null ? 1 : 0

  metadata {
    name = var.namespace
  }
}

resource "kubernetes_persistent_volume_claim_v1" "shared" {
  count = var.shared_storage_class != null ? 1 : 0

  metadata {
    name      = "n8n-shared"
    namespace = kubernetes_namespace.n8n[0].metadata[0].name
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

  # A claim that binds immediately is the normal case. One that stays Pending
  # usually means the class is not actually RWX-capable, which wants a human
  # rather than a longer wait.
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
