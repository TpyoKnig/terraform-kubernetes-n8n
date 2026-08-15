# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Plan-time tests for the Let's Encrypt ClusterIssuer.
#
# The manifest is built with yamlencode() from locals, so it is fully known at
# plan time and can be decoded and asserted on directly. That is the point of
# assembling it in a local rather than inline: the contract is checkable without
# a cluster.
#
# Run: terraform test
#   (from modules/tls-letsencrypt/, requires terraform >= 1.11)

mock_provider "kubectl" {}

variables {
  email = "ops@example.com"
}

run "defaults_target_production" {
  command = plan

  assert {
    condition     = local.acme_server == "https://acme-v02.api.letsencrypt.org/directory"
    error_message = "The default must be production: staging certificates are signed by an untrusted root, and defaulting to them would ship a deployment browsers reject."
  }

  assert {
    condition     = output.is_staging == false
    error_message = "is_staging must report false on the default path."
  }
}

run "staging_switches_the_acme_endpoint" {
  command = plan

  variables {
    staging = true
  }

  assert {
    condition     = local.acme_server == "https://acme-staging-v02.api.letsencrypt.org/directory"
    error_message = "staging = true must point at the staging directory; that is the only thing separating a rate-limited iteration loop from burning the production limit."
  }
}

run "the_account_key_secret_follows_the_issuer_name" {
  command = plan

  variables {
    name = "letsencrypt-staging"
  }

  # Two issuers in one cluster (the staging/production pairing) must not share
  # an account key Secret, or the second silently reuses the first's ACME
  # account.
  assert {
    condition     = local.private_key_secret == "letsencrypt-staging-account-key"
    error_message = "The account key Secret name must default off the issuer name so a staging and a production issuer cannot collide."
  }
}

run "an_explicit_key_secret_name_wins" {
  command = plan

  variables {
    private_key_secret_name = "my-acme-account"
  }

  assert {
    condition     = local.private_key_secret == "my-acme-account"
    error_message = "private_key_secret_name must override the derived default."
  }
}

run "the_manifest_is_a_cert_manager_cluster_issuer" {
  command = plan

  assert {
    condition     = yamldecode(kubectl_manifest.letsencrypt.yaml_body).kind == "ClusterIssuer"
    error_message = "The rendered manifest must be a ClusterIssuer; a namespaced Issuer would not be visible to an Ingress in another namespace."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.letsencrypt.yaml_body).apiVersion == "cert-manager.io/v1"
    error_message = "apiVersion must be cert-manager.io/v1."
  }
}

run "the_solver_is_http01_on_the_configured_ingress_class" {
  command = plan

  variables {
    ingress_class_name = "traefik"
  }

  # The challenge Ingress has to be picked up by the controller that actually
  # serves the hostname. If it is not, validation times out with nothing in the
  # n8n deployment indicating why.
  assert {
    condition = yamldecode(kubectl_manifest.letsencrypt.yaml_body
    ).spec.acme.solvers[0].http01.ingress.ingressClassName == "traefik"
    error_message = "The HTTP-01 solver must use the caller's ingress class."
  }
}

run "an_invalid_email_is_rejected" {
  command = plan

  variables {
    email = "not-an-address"
  }

  # Let's Encrypt refuses account registration without a valid contact, and that
  # failure surfaces at apply against the ACME API rather than at plan.
  expect_failures = [var.email]
}
