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
  description = "Annotations added to the editor Ingress only, on top of ingress_extra_annotations. Where an IP allowlist goes when the editor has no identity-aware proxy in front of it: {\"nginx.ingress.kubernetes.io/whitelist-source-range\" = \"192.168.1.0/24\"}. An allowlist works behind a tunnel or CDN as well as on a direct path, but only if the controller derives the client address from X-Forwarded-For: on ingress-nginx that means use-forwarded-headers and compute-full-forwarded-for. Without them nginx compares against the tunnel's own source address, which is identical for every request, so the rule admits everyone or no one. Set proxy_hops to match the same chain."
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

variable "proxy_hops" {
  description = "How many proxies append to X-Forwarded-For between the client and an n8n pod (N8N_PROXY_HOPS). Defaults to 2 here, where ../homelab-split-ingress defaults to 1: that topology has ingress-nginx alone, this one puts the Cloudflare edge in front of it. Raise it again for anything further out, a WAF or a second reverse proxy. A wrong count is as bad as none: too low and n8n reads a proxy address as the client, too high and it reads a value the client could have forged. Every rate limit, audit log line and IP-based restriction depends on it, and nothing errors when it is wrong."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.proxy_hops >= 0 && floor(var.proxy_hops) == var.proxy_hops
    error_message = "proxy_hops must be a non-negative whole number. It is a count of proxies, and n8n reads N8N_PROXY_HOPS as an integer."
  }
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the zone both hostnames sit under. Leave null (the default) to manage DNS yourself, in which case the example creates no records. Set it and the example creates one proxied CNAME per hostname pointing at the Cloudflare Tunnel named by cloudflare_tunnel_id. The API token needs Zone:DNS:Edit on this zone."
  type        = string
  default     = null

  validation {
    condition     = var.cloudflare_zone_id == null || var.cloudflare_tunnel_id != null
    error_message = "cloudflare_zone_id requires cloudflare_tunnel_id: the records are CNAMEs to <tunnel-id>.cfargotunnel.com, so there is nothing to point them at otherwise. Find it with `cloudflared tunnel list` or in the Cloudflare Zero Trust dashboard."
  }
}

variable "cloudflare_tunnel_id" {
  description = "UUID of the Cloudflare Tunnel that fronts the cluster's ingress controller. Each DNS record created when cloudflare_zone_id is set is a proxied CNAME to <this>.cfargotunnel.com. The tunnel itself is not managed by this example: it is long-lived cluster infrastructure serving every other hostname too, so a terraform destroy here must not be able to take it down."
  type        = string
  default     = null
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit on cloudflare_zone_id. Only read when cloudflare_zone_id is set. Prefer the CLOUDFLARE_API_TOKEN environment variable over putting it in terraform.tfvars."
  type        = string
  default     = null
  sensitive   = true
}

variable "shared_storage_class" {
  description = "An RWX-capable StorageClass for the volume shared across the main, worker and webhook-processor pods (NFS, SMB, CephFS, or whatever the cluster offers). Leave null and no claim is created, in which case binary data stays in Postgres, which is n8n's default in queue mode and is fine until payloads get large. Set it and binary data moves to the shared volume instead. Check the class can actually reclaim before trusting it: with the NFS CSI driver against an NFSv3-only appliance the PV is deleted while every byte stays on the server, which reads as automatic cleanup and is not."
  type        = string
  default     = null
}

variable "shared_storage_size" {
  description = "Size of the shared RWX claim. Only used when shared_storage_class is set. Binary data from every execution lands here, so size it against retention rather than against one workflow."
  type        = string
  default     = "20Gi"
  nullable    = false
}

variable "shared_mount_path" {
  description = "Where the shared volume is mounted in the n8n container on all three pod types. Binary data goes to <this>/storage. Kept out of /home/node/.n8n deliberately: the chart already mounts its own data volume there on main, and nesting one mount inside another is a way to lose track of which pod sees what."
  type        = string
  default     = "/opt/n8n-shared"
  nullable    = false

  validation {
    condition     = startswith(var.shared_mount_path, "/")
    error_message = "shared_mount_path must be an absolute path."
  }
}
