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
  # An explicit cloudflare_api_token always wins, even with cloudflare_zone_id
  # null: toggling the zone ID off while a record from an earlier apply is
  # still in state schedules a destroy of that record (dns.tf's count drops to
  # 0), and the provider needs a real token to send that delete. Feeding it
  # the placeholder there, as an earlier version of this file did, makes
  # Cloudflare reject the call and strands the record in state.
  #
  # Only when no explicit token is set AND the zone ID is null does the
  # plugin get the placeholder, purely so it can configure at all on the
  # genuine no-DNS path; dns.tf creates no record there, so the placeholder is
  # never sent to Cloudflare. The plugin format-checks the token as well, so
  # the placeholder is exactly 40 characters of [A-Za-z0-9_-] to pass that
  # too. A caller who relies on CLOUDFLARE_API_TOKEN instead of
  # cloudflare_api_token still hits that placeholder on a destroy with the
  # zone ID already null, because the env var is invisible here: pass the
  # token through terraform.tfvars for that one apply, or `terraform state
  # rm` the record.
  #
  # Null (rather than a placeholder default) on the explicit-token branch is
  # what lets the plugin fall back to CLOUDFLARE_API_TOKEN: an explicit
  # api_token takes precedence over the environment variable, so defaulting
  # the variable to a placeholder would shadow it.
  api_token = var.cloudflare_api_token != null ? var.cloudflare_api_token : (
    var.cloudflare_zone_id == null ? "placeholder_unused_no_dns_record_managed" : null
  )
}
