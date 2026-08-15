# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Issuer identity ───────────────────────────────────────────────────────────

variable "name" {
  description = "Name of the ClusterIssuer this module creates. Pass the same value as the root module's k8s_ingress_cluster_issuer (or the examples' cluster_issuer), because that is what gets written into the Ingress annotation cert-manager reads. A mismatch is silent: cert-manager sees an annotation naming an issuer that does not exist, never issues, and the site serves the ingress controller's default self-signed certificate."
  type        = string
  default     = "letsencrypt-prod"
  nullable    = false
}

variable "email" {
  description = "Contact address registered with Let's Encrypt for this ACME account. Required: Let's Encrypt uses it for expiry warnings and for contact about problems with issued certificates. It is not published in the certificate, but it is recorded in the ACME account and in Certificate Transparency logs' surrounding metadata, so use an address you are willing to associate with the deployment."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s.]+\\.[^@\\s]+$", var.email))
    error_message = "email must be a valid address; Let's Encrypt rejects account registration without one."
  }
}

variable "staging" {
  description = "Issue from Let's Encrypt's staging endpoint instead of production. Staging certificates are signed by an untrusted root, so browsers reject them - the point is that staging has far higher rate limits than production's 5 duplicate certificates per week. Use it while getting DNS, ingress and the challenge path working, then flip to false. Getting this wrong in the other direction is the expensive mistake: a misconfigured ingress that fails validation repeatedly against production can exhaust the weekly limit and lock the hostname out of new certificates until it resets."
  type        = bool
  default     = false
  nullable    = false
}

# ── Solver ────────────────────────────────────────────────────────────────────

variable "ingress_class_name" {
  description = "IngressClass cert-manager uses when it creates the temporary Ingress that serves the HTTP-01 challenge response. Must match the class actually serving your hostname, otherwise the challenge Ingress is created and no controller picks it up, and validation times out with no obvious error on the n8n side."
  type        = string
  default     = "nginx"
  nullable    = false
}

variable "private_key_secret_name" {
  description = "Name of the Secret in cert-manager's namespace holding this ACME account's private key. cert-manager creates it; the module only names it. Changing this name after issuance registers a NEW ACME account rather than reusing the existing one, which restarts from zero against the rate limits, so treat it as fixed once set."
  type        = string
  default     = null

  validation {
    condition     = var.private_key_secret_name == null || can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.private_key_secret_name))
    error_message = "private_key_secret_name must be a valid Kubernetes object name (lowercase alphanumerics and dashes)."
  }
}
