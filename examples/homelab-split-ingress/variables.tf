# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

variable "kubeconfig_path" {
  description = "Path to kubeconfig used by the kubernetes, helm and kubectl providers."
  type        = string
  default     = "~/.kube/config"
  nullable    = false

  validation {
    condition     = var.kubeconfig_path != "" && var.kubeconfig_path != "~/" && !can(regex("[\"`$]", var.kubeconfig_path)) && !endswith(var.kubeconfig_path, "\\")
    error_message = "kubeconfig_path must not be empty, must not contain a double quote, a backtick or a dollar sign, and must not end in a backslash. It is interpolated into kubectl_config_command, which tests/scripts/smoke-test.sh evaluates as a shell command: the first three characters escape the quoting around it, and a trailing backslash escapes the closing quote itself, which leaves the command unterminated and the export silently skipped. An empty path is rejected because it resolves to the example directory rather than to a file, and the smoke test would export a directory as KUBECONFIG; a bare \"~/\" is rejected for the same reason, resolving to the home directory itself."
  }

}

variable "namespace" {
  description = "Namespace to deploy into. Created by this example on every path rather than by the module, so that turning shared storage on later cannot move it between two resource addresses. An existing deployment upgrading to this needs one terraform state mv first, or the next apply plans to destroy the namespace; both commands are in storage.tf."
  type        = string
  default     = "n8n"
  nullable    = false
}

variable "editor_host" {
  description = "Hostname serving the editor UI, the REST API and test webhooks. This is n8n's canonical hostname (N8N_HOST). Put your authentication policy in front of this name, Cloudflare Access, an OIDC proxy, an IP allowlist, none of which breaks webhook delivery, because production webhooks are advertised on webhook_host instead."
  type        = string
  default     = "n8n.example.com"

  validation {
    condition     = can(regex("^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,}$", var.editor_host))
    error_message = "editor_host must be a fully qualified domain name (e.g. n8n.example.com)."
  }
  nullable = false
}

variable "webhook_host" {
  description = "Hostname serving production webhooks, forms, waiting webhooks and MCP. Passed to the module as n8n_webhook_url, so it is what n8n hands out in every generated webhook URL. Also routes /rest/projects to the main pods, which n8n's Agents chat integrations require because they build their OAuth callbacks and platform webhooks onto this hostname; see the example README. Nothing else is routed on this name: a request to any other path gets the ingress controller's 404."
  type        = string
  default     = "hooks.example.com"

  validation {
    condition     = can(regex("^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,}$", var.webhook_host))
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
  description = "How many proxies append to X-Forwarded-For between the client and an n8n pod (N8N_PROXY_HOPS). The default of 1 counts ingress-nginx alone, which is what this example assumes and what the module itself uses when it owns the Ingress. Count your own chain and raise it: a Cloudflare Tunnel, a CDN, a WAF or an outer reverse proxy each add one, so fronting this example with Cloudflare makes it 2. A wrong count is as bad as none: too low and n8n reads a proxy address as the client, too high and it reads a value the client could have forged. Every rate limit, audit log line and IP-based restriction depends on it."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.proxy_hops >= 1 && floor(var.proxy_hops) == var.proxy_hops
    error_message = "proxy_hops must be a whole number of at least 1. This example creates its own Ingresses, so ingress-nginx is always in the chain and there is always a hop to count. 0 would tell n8n to treat the controller's own address as the client, which silently defeats every IP allowlist, rate limit and audit log line."
  }
}

variable "shared_storage_class" {
  description = "An RWX-capable StorageClass for a volume shared across the main, worker and webhook-processor pods (NFS, SMB, CephFS, or whatever the cluster offers). Leave null and no claim is created, in which case binary data stays in Postgres, which is n8n's default in queue mode. Set it and binary data moves to the shared volume instead. Check the class can actually reclaim before trusting it: with the NFS CSI driver against an NFSv3-only appliance the PV is deleted while every byte stays on the server, which reads as automatic cleanup and is not."
  type        = string
  default     = null

  validation {
    condition     = var.shared_storage_class == null || (length(var.shared_storage_class) > 0 && var.shared_storage_class == trimspace(var.shared_storage_class))
    error_message = "shared_storage_class must be null to disable shared storage, or a class name with no leading or trailing whitespace to enable it. An empty string is neither: it enables the claim and then asks Kubernetes for no class at all, rather than for the default one. A padded name is the same failure wearing a disguise, because the claim is created with the value as given and no class matches it. Either way the claim sits Pending with nothing explaining why."
  }
}

variable "shared_storage_size" {
  description = "Size of the shared RWX claim. Only used when shared_storage_class is set. Binary data from every execution lands here, so size it against retention rather than against one workflow."
  type        = string
  default     = "20Gi"
  nullable    = false
}

variable "shared_mount_path" {
  description = "Where the shared volume is mounted in the n8n container on all three pod types. Binary data goes to `shared_mount_path`/storage. Kept out of /home/node/.n8n deliberately: the chart already mounts its own data volume there on main, and nesting one mount inside another is a way to lose track of which pod sees what. Note the task-runner sidecar does not get this mount; n8n_extra_volume_mounts reaches the n8n container only."
  type        = string
  default     = "/opt/n8n-shared"
  nullable    = false

  validation {
    condition     = startswith(var.shared_mount_path, "/")
    error_message = "shared_mount_path must be an absolute path."
  }
}
