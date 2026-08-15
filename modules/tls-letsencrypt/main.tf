# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# A Let's Encrypt ClusterIssuer, solving HTTP-01 through the caller's ingress
# controller.
#
# This exists because every example names an issuer (`letsencrypt-prod`) that
# nothing created. The module renders `cert-manager.io/cluster-issuer` onto the
# Ingress, and if no issuer by that name exists cert-manager does not fail
# loudly: it never issues, and the ingress controller keeps serving its own
# default self-signed certificate. The deployment looks up, the browser warns,
# and nothing in Terraform said a word. A named prerequisite that is silently
# optional is the worst kind, so the module now ships the one-object answer.
#
# It stays a SEPARATE submodule rather than a toggle on the root module, for the
# same reason the root installs no operators: a ClusterIssuer is cluster-scoped
# and shared. Two n8n deployments in one cluster both wanting TLS must not both
# own it, and `terraform destroy` on one must not take the other's issuer with
# it. Calling this once from wherever the cluster's shared configuration lives
# is the right shape; calling it from every n8n deployment is not.
#
# cert-manager itself is still a prerequisite. This creates a custom resource
# that its CRDs define; it does not install the operator.

locals {
  # Staging is signed by an untrusted root but has far higher rate limits, which
  # is the whole reason to reach for it while iterating on DNS and ingress.
  acme_server = var.staging ? "https://acme-staging-v02.api.letsencrypt.org/directory" : "https://acme-v02.api.letsencrypt.org/directory"

  # Default the key Secret's name off the issuer name so two issuers (a staging
  # and a production one, the common pairing) cannot collide on one account key.
  private_key_secret = coalesce(var.private_key_secret_name, "${var.name}-account-key")
}

# Applied through gavinbunney/kubectl rather than hashicorp/kubernetes_manifest,
# which is this module's default for every custom resource (see AGENTS.md).
# kubernetes_manifest resolves a resource's schema against a live cluster API at
# *plan* time, so `terraform plan` would fail wherever the API is unreachable:
# and that is especially wrong here, because a ClusterIssuer is often applied to
# a cluster in the same run that installs cert-manager, when the CRD defining it
# does not exist yet at plan time either.
resource "kubectl_manifest" "letsencrypt" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = var.name
      labels = {
        "app.kubernetes.io/managed-by" = "terraform-kubernetes-n8n"
      }
    }
    spec = {
      acme = {
        server = local.acme_server
        email  = var.email
        privateKeySecretRef = {
          name = local.private_key_secret
        }
        solvers = [
          {
            # HTTP-01, not DNS-01, deliberately. DNS-01 needs a provider-specific
            # solver and credentials for the zone, which would drag this module
            # back into having a DNS opinion, the one thing the rest of it
            # refuses to have. HTTP-01 needs only that the hostname already
            # resolves to this ingress controller, which is a prerequisite the
            # deployment has anyway.
            #
            # The trade-off worth knowing: HTTP-01 cannot issue wildcards, and it
            # requires the name to be reachable from Let's Encrypt's validation
            # servers on port 80. A cluster reachable only over a private network
            # or behind an authenticating proxy cannot use this issuer, and needs
            # a DNS-01 solver configured out of band instead.
            http01 = {
              ingress = {
                ingressClassName = var.ingress_class_name
              }
            }
          }
        ]
      }
    }
  })

  # The issuer is cluster-scoped shared configuration. Leaving it behind on
  # destroy would orphan an object nothing owns; taking it down while another
  # deployment still references it would silently stop that deployment's
  # renewals. That tension is exactly why this is its own module: whoever calls
  # it owns that decision explicitly.
  server_side_apply = true
  wait              = false
}
