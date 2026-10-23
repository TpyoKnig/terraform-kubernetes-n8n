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
      version = "~> 3.3"
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
    #
    # Source is the fully qualified registry.terraform.io hostname, not the
    # shorthand "veksh/godaddy-dns": OpenTofu resolves an unqualified source
    # against registry.opentofu.org by default, which does not mirror this
    # provider ("provider registry registry.opentofu.org does not have a
    # provider named ... veksh/godaddy-dns"), failing `tofu init` outright.
    # registry.terraform.io is already Terraform's own default for an
    # unqualified source, so this is a no-op there and a real fix for
    # OpenTofu, not a workaround.
    godaddy-dns = {
      source  = "registry.terraform.io/veksh/godaddy-dns"
      version = "~> 0.3"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}
