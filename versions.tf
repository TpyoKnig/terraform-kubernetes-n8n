# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Terraform & provider requirements ──────────────────────────────────────
# Declares the minimum Terraform CLI and the providers this module needs.
# Provider configuration (region, auth, kube/helm wiring) is the caller's job
#, see examples/homelab/providers.tf.

terraform {
  # Two features set this floor, and the higher one wins:
  #
  #   1.9:  cross-variable references in validation blocks, e.g.
  #          n8n_encryption_key_secret_ref's validation referencing
  #          n8n_encryption_key. Used throughout variables.tf.
  #   1.11: override_resource's override_during attribute, needed to assert a
  #          plan-time value on a resource the same configuration creates.
  #          Silently ignored before 1.11 rather than rejected, so a caller
  #          below this floor gets a confusing assertion failure from
  #          `terraform test` instead of a version error.
  #
  # 1.10 is also load-bearing in passing: it added short-circuit evaluation of
  # && and ||, which this module's `check` blocks used to have to work around
  # by hand (see AGENTS.md). Declared as >= 1.11 in every versions.tf in the
  # repo and matched by CI's TF_VERSION pin, so the floor is a claim CI
  # actually exercises rather than one nobody checks.
  required_version = ">= 1.11"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    # The CNPG Cluster CR (postgres_cnpg.tf). hashicorp/kubernetes_manifest
    # resolves schemas against a live cluster API at plan time; kubectl_manifest
    # defers that to apply. This is the module's default for every custom
    # resource, not a one-off for CNPG: see AGENTS.md.
    kubectl = {
      source = "gavinbunney/kubectl"
      # Pessimistic like the other four, rather than the open ">= 1.14" this
      # carried. An unbounded constraint is an invitation for a future 2.0 to
      # arrive on an unrelated apply, and every custom resource this module
      # applies itself goes through it: the CNPG Cluster, the Pooler, and the
      # ClusterIssuer in modules/tls-letsencrypt. (The worker ScaledObject is a
      # custom resource too, but the chart renders it, so the Helm release owns
      # that one and this constraint has no bearing on it.)
      version = "~> 1.14"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
