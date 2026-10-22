# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Resource address history ──────────────────────────────────────────────────
# `moved` blocks live here, and nowhere else, so that the full history of every
# renamed or re-addressed resource is readable in one file.
#
# Why they matter: Terraform keys state by resource address, not by what the
# resource is. Rename a resource, move it into a submodule, or change a `count`
# to a `for_each`, and Terraform sees the old address disappear and a new one
# arrive. Its plan is then to destroy and recreate, which for anything in this
# module means deleting a namespace, a database Cluster, or a PersistentVolume
# and its contents. A `moved` block tells it the two addresses are the same
# object, and the plan becomes a no-op.
#
# Adding one:
#
#   moved {
#     from = kubernetes_secret.n8n
#     to   = kubernetes_secret.n8n_core
#   }
#
# Keep them forever, or at least across a major version. Removing one restores
# the destroy-and-recreate plan for anyone who has not yet applied since the
# rename, which is exactly the person the block exists to protect.
#
# The count-to-for_each case is the one to watch, because it does not look like
# a rename. `resource[0]` and `resource["name"]` are different addresses, so a
# gated resource that gains an index needs a block per instance.
#
# The file is empty by design: no resource in this module has been re-addressed
# since the Kubernetes port. It exists so that the convention is already in
# place the first time one is, rather than being invented under pressure during
# a rename.
