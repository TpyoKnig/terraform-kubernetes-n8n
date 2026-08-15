# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Issuer ────────────────────────────────────────────────────────────────────

output "cluster_issuer_name" {
  description = "Name of the ClusterIssuer created. Pass this straight into the root module's k8s_ingress_cluster_issuer so the Ingress annotation and the issuer cannot drift apart - which is the failure this module exists to prevent."
  value       = kubectl_manifest.letsencrypt.name
}

output "acme_server" {
  description = "ACME directory endpoint in use. Staging when staging = true, which is signed by an untrusted root: browsers will reject certificates issued from it, by design."
  value       = local.acme_server
}

output "is_staging" {
  description = "Whether this issuer points at Let's Encrypt staging. Useful as an assertion in a caller's own tests, so a deployment cannot reach production still pointed at staging and serve untrusted certificates."
  value       = var.staging
}
