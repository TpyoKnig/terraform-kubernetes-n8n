# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Shared storage across the three pod types ─────────────────────────────────
# Queue mode runs main, worker and webhook-processor pods, and they do not share
# a filesystem. The chart mounts its own `data` volume on main only, and this
# module leaves persistence at the chart default, so that volume is an emptyDir.
#
# Split routing makes the gap concrete. A webhook arrives at a webhook-processor
# pod, the execution runs on a worker, and the editor renders results on main.
# Three pods, three filesystems: anything one writes to local disk is invisible
# to the other two.
#
# An RWX claim mounted into all three closes it.
#
# ── Why the namespace is created here ────────────────────────────────────────
# The claim has to exist before the Helm release, because a pod referencing a
# missing PVC stays Pending and the release never goes ready. The claim in turn
# needs a namespace. So the ordering is namespace, claim, module, which means
# the caller owns the namespace and the module is told not to create one.
#
# This is a supported path rather than a workaround: create_namespace = false
# exists for it. The cost is that `terraform destroy` removes the namespace and
# everything in it, this claim included.

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

  # A claim that binds immediately is the normal case. One that stays Pending
  # usually means the class is not actually RWX-capable, which wants a human
  # rather than a longer wait.
  timeouts {
    create = "5m"
  }
}

# Note on destroy: this claim holds binary data, and `terraform destroy` takes
# it along with the namespace. If that data matters, either set the class's
# reclaimPolicy to Retain so the underlying volume survives the PVC, or keep the
# claim in a separate configuration from the workload. prevent_destroy is not
# the answer here: it would make `terraform destroy` fail outright rather than
# protect anything, since the namespace deletion removes the claim regardless.

