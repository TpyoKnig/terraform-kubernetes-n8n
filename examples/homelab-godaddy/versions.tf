# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

terraform {
  # Matches every other example's floor and the module's own required_version.
  # See AGENTS.md → "The floor is >= 1.11" for the coupling to override_during
  # and the check-block short-circuit fix.
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
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    # Only used when godaddy_domain is set (dns.tf). GoDaddy has no official
    # Terraform provider; veksh/godaddy-dns is the maintained community one.
    #
    # Pinned to the 0.3.x line: it is a community provider on a 0.x release
    # train, so minor bumps may be breaking. Re-evaluate when 1.0 ships.
    godaddy-dns = {
      source  = "veksh/godaddy-dns"
      version = "~> 0.3"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
