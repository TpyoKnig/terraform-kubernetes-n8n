# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Declares this submodule's own provider requirement so it plans correctly
# whether called from the root module or invoked directly by a caller who wants
# a ClusterIssuer without deploying n8n at all.

terraform {
  required_version = ">= 1.11"

  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
  }
}
