# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

variable "kubeconfig_path" {
  description = "Path to kubeconfig used by the kubernetes, helm and kubectl providers."
  type        = string
  default     = "~/.kube/config"
  nullable    = false
}

variable "namespace" {
  description = "Namespace to deploy into. Created by the module."
  type        = string
  default     = "n8n"
  nullable    = false
}

variable "editor_host" {
  description = "Hostname serving the editor UI, the REST API and test webhooks. This is n8n's canonical hostname (N8N_HOST). Put your authentication policy in front of this name, Cloudflare Access, an OIDC proxy, an IP allowlist, none of which breaks webhook delivery, because production webhooks are advertised on webhook_host instead."
  type        = string
  default     = "n8n.example.com"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.editor_host))
    error_message = "editor_host must be a fully qualified domain name (e.g. n8n.example.com)."
  }
  nullable = false
}

variable "webhook_host" {
  description = "Hostname serving production webhooks, forms, waiting webhooks and MCP. Passed to the module as n8n_webhook_url, so it is what n8n hands out in every generated webhook URL. Nothing else is routed on this name: a request to any other path gets the ingress controller's 404, which is what makes it safe to leave open to the internet."
  type        = string
  default     = "hooks.example.com"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.webhook_host))
    error_message = "webhook_host must be a fully qualified domain name (e.g. hooks.example.com)."
  }

  validation {
    condition     = lower(var.webhook_host) != lower(var.editor_host)
    error_message = "webhook_host must differ from editor_host. Pointing both at one name is the single-Ingress topology - use examples/homelab for that, which does it with one Ingress pair instead of two."
  }
  nullable = false
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer that signs both Ingress certificates. Must already exist in the cluster - this example does not install cert-manager. Each hostname gets its own Certificate, so an issuer scoped to a single DNS zone needs both names inside it."
  type        = string
  default     = "letsencrypt-prod"
  nullable    = false
}

variable "ingress_class_name" {
  description = "IngressClass both Ingresses are created with. The cluster must already run a controller for it."
  type        = string
  default     = "nginx"
  nullable    = false
}

variable "ingress_extra_annotations" {
  description = "Annotations added to both Ingresses. Merged over this example's own (cert-manager issuer, body size, proxy timeouts), so a key set here wins."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "editor_ingress_extra_annotations" {
  description = "Annotations added to the editor Ingress only, on top of ingress_extra_annotations. Where an IP allowlist goes when the editor is reached directly on the LAN rather than through an identity-aware proxy: {\"nginx.ingress.kubernetes.io/whitelist-source-range\" = \"192.168.1.0/24\"}. Note that a request arriving through a tunnel or reverse proxy carries that proxy's source address, so an allowlist is meaningful only on the path that reaches nginx directly."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "webhook_ingress_extra_annotations" {
  description = "Annotations added to the webhook Ingress only, on top of ingress_extra_annotations. Rate limiting belongs here if the controller is doing it rather than an upstream WAF: {\"nginx.ingress.kubernetes.io/limit-rps\" = \"20\"}. This is the hostname exposed to unauthenticated callers, so it is the one worth bounding."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "storage_class" {
  description = "StorageClass for the CNPG and Valkey PVCs. Empty uses whatever the cluster's default StorageClass is."
  type        = string
  default     = ""
  nullable    = false
}

variable "timezone" {
  description = "Timezone n8n schedules Cron triggers in (GENERIC_TIMEZONE)."
  type        = string
  default     = "UTC"
  nullable    = false
}

variable "keda_installed" {
  description = "Set true when the KEDA operator is already installed cluster-wide. Workers then scale on Redis queue depth rather than CPU. Leave false if unsure: a ScaledObject with no operator behind it never reconciles and workers stay at their minimum replica count without anything failing."
  type        = bool
  default     = false
  nullable    = false
}
