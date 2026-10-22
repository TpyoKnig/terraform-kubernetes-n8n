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
  # A provider block cannot be made conditional, and the plugin refuses to
  # configure at all with no credential: "must provide exactly one of api_key,
  # api_token or api_user_service_key", raised before anything asks whether a
  # resource uses it. That failed every plan on the documented no-DNS path,
  # where the caller leaves cloudflare_zone_id null because their records are
  # managed elsewhere.
  #
  # So on that path the plugin is handed a placeholder purely to let it
  # configure. dns.tf creates no record without a zone ID, so the value is
  # never sent anywhere. The plugin format-checks the token as well, so the
  # placeholder is exactly 40 characters of [A-Za-z0-9_-] to pass that too.
  #
  # Gated on the zone ID rather than defaulting the variable, which would look
  # simpler and would break the line above this one: an explicit api_token
  # takes precedence over CLOUDFLARE_API_TOKEN, so a placeholder default would
  # shadow the environment variable the comment tells callers to prefer. Null
  # is what lets the plugin fall back to it.
  api_token = var.cloudflare_zone_id == null ? "placeholder_unused_no_dns_record_managed" : var.cloudflare_api_token
}
