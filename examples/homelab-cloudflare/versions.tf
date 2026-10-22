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
      version = "~> 3.0"
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
    # Only used when cloudflare_zone_id is set (dns.tf). The 4.0-4.52.6 cap
    # that used to live here (matching examples/cloudflare: 4.52.7 was
    # thought to break api_token sourced from a sensitive Terraform
    # variable) was live-tested stale against a real zone on 2026-10-21:
    # 4.52.7 through 4.52.9 all configure and apply correctly with a
    # sensitive-variable api_token. The module moved straight past the dead
    # cap to the v5 rewrite instead of re-pinning a live 4.x floor.
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}
