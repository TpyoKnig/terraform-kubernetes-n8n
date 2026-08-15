# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# All three providers read the same kubeconfig. Point var.kubeconfig_path at
# yours, or set KUBE_CONFIG_PATH and pass it in.
provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}

provider "helm" {
  kubernetes = {
    config_path = pathexpand(var.kubeconfig_path)
  }
}

# kubectl applies the CNPG Cluster CR. Unlike the kubernetes provider it does
# not read a kubeconfig implicitly, so load_config_file must be explicit.
provider "kubectl" {
  config_path      = pathexpand(var.kubeconfig_path)
  load_config_file = true
}

# Only contacted when cloudflare_zone_id is set (dns.tf). Pass the token via the
# CLOUDFLARE_API_TOKEN environment variable in preference to terraform.tfvars.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
