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

# Only contacted when godaddy_domain is set (dns.tf). Prefer the GODADDY_API_KEY
# and GODADDY_API_SECRET environment variables over putting either in
# terraform.tfvars.
provider "godaddy-dns" {
  # A provider block cannot be made conditional, and the plugin refuses to
  # configure without both halves of the credential, before anything asks
  # whether a resource uses them. That failed every plan on the documented
  # no-DNS path, where the caller leaves godaddy_domain null because their
  # records are managed elsewhere.
  #
  # So on that path the plugin is handed placeholders purely to let it
  # configure. dns.tf creates no record without a domain, so neither value is
  # ever sent anywhere.
  #
  # Gated on the domain rather than defaulting the variables, which would look
  # simpler and would break the lines above: explicit values take precedence
  # over GODADDY_API_KEY and GODADDY_API_SECRET, so placeholder defaults would
  # shadow the environment variables the comment tells callers to prefer. Null
  # is what lets the plugin fall back to them.
  api_key    = var.godaddy_domain == null ? "placeholder_unused_no_dns_record_managed" : var.godaddy_api_key
  api_secret = var.godaddy_domain == null ? "placeholder_unused_no_dns_record_managed" : var.godaddy_api_secret
}
