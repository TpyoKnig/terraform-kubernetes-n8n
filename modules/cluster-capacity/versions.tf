# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Declares this submodule's own provider requirement so it plans correctly
# whether called from the root module (scaling.tf) or invoked directly by a
# caller who wants the same sizing diagnostic against their own numbers.

terraform {
  required_version = ">= 1.11"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}
