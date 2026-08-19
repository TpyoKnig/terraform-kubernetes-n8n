# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

terraform {
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
    # Only used when cloudflare_zone_id is set (dns.tf). Pinned below 4.52.7 to
    # match examples/homelab-cloudflare: that release broke api_token when the
    # value comes from a sensitive Terraform variable.
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 4.0, < 4.52.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
