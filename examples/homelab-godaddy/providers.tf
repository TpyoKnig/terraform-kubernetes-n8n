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
  # An explicit godaddy_api_key/godaddy_api_secret always wins, even with
  # godaddy_domain null: toggling the domain off while a record from an
  # earlier apply is still in state schedules a destroy of that record
  # (dns.tf's count drops to 0), and the provider needs real credentials to
  # send that delete. Feeding it placeholders there, as an earlier version of
  # this file did, makes GoDaddy reject the call and strands the record in
  # state.
  #
  # Only when neither explicit value is set AND the domain is null do the
  # placeholders apply, purely so the plugin can configure at all on the
  # genuine no-DNS path; dns.tf creates no record there, so the placeholders
  # are never sent to GoDaddy. A caller who relies on GODADDY_API_KEY /
  # GODADDY_API_SECRET instead of the typed variables still hits those
  # placeholders on a destroy with the domain already null, because the env
  # vars are invisible here: pass the credentials through terraform.tfvars
  # for that one apply, or `terraform state rm` the record.
  #
  # Null (rather than a placeholder default) on the explicit-value branch is
  # what lets the plugin fall back to GODADDY_API_KEY / GODADDY_API_SECRET:
  # explicit values take precedence over the environment variables, so
  # defaulting the variables to placeholders would shadow them.
  api_key = var.godaddy_api_key != null ? var.godaddy_api_key : (
    var.godaddy_domain == null ? "placeholder_unused_no_dns_record_managed" : null
  )
  api_secret = var.godaddy_api_secret != null ? var.godaddy_api_secret : (
    var.godaddy_domain == null ? "placeholder_unused_no_dns_record_managed" : null
  )
}
