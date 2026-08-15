# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

variable "kubeconfig_path" {
  description = "Path to kubeconfig used by the kubernetes + helm providers."
  type        = string
  default     = "~/.kube/config"
  nullable    = false
}

variable "namespace" {
  description = "Namespace to deploy into."
  type        = string
  default     = "n8n"
  nullable    = false
}

variable "ui_host" {
  description = "Hostname served by ingress. This example creates an A record for it when godaddy_domain is set. Leave that null and this example behaves exactly like examples/homelab: the record is yours."
  type        = string
  default     = "n8n.example.com"
  nullable    = false
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer to use for the ingress TLS cert."
  type        = string
  default     = "letsencrypt-prod"
  nullable    = false
}

variable "storage_class" {
  description = "StorageClass for the CNPG and Valkey PVCs. Empty uses whatever the cluster's default StorageClass is."
  type        = string
  default     = ""
  nullable    = false
}

variable "postgres_lan_ip" {
  description = "Address to publish the CNPG rw endpoint on, for LAN clients that are not in the cluster - a Grafana instance querying n8n's execution tables, a DB client. Rendered as an io.cilium/lb-ipam-ips annotation, so it pins the address on Cilium LB-IPAM only; other allocators (MetalLB, kube-vip) ignore that key and will allocate an arbitrary address instead. To pin on those, call the module directly and use cnpg_lan_expose.annotations / metrics_lan_expose.annotations with the key your allocator honours. Leave null (the default) and no LoadBalancer Service is created. Postgres is exposed without a proxy in front of it, so only set this on a network you trust."
  type        = string
  default     = null
}

variable "metrics_lan_ip" {
  description = "Address to publish the n8n main pod's /metrics endpoint on, for a Prometheus that runs outside the cluster and so cannot use in-cluster service discovery. Same allocator requirement as postgres_lan_ip. Leave null (the default) and no LoadBalancer Service is created; an in-cluster Prometheus or Alloy does not need this."
  type        = string
  default     = null
}

variable "keda_installed" {
  description = "Set true when the KEDA operator is already installed cluster-wide. Workers then scale on Redis queue depth rather than CPU, and the chart's CPU worker HPA is disabled so the two never both own the worker Deployment. Leave false if you are unsure: a ScaledObject with no operator behind it never reconciles and workers stay at their minimum replica count without anything failing."
  type        = bool
  default     = false
  nullable    = false
}

variable "godaddy_domain" {
  description = "GoDaddy domain (the zone apex, e.g. example.com) that ui_host sits under. Leave null (the default) to manage DNS yourself, the example creates no record then. Set it and the example creates an A record pointing godaddy_record_name at ingress_ip."
  type        = string
  default     = null

  validation {
    condition     = var.godaddy_domain == null || var.ingress_ip != null
    error_message = "godaddy_domain requires ingress_ip: the record is an A record, so there is nothing to point it at otherwise. Find it with `kubectl get svc -n ingress-nginx`."
  }
}

variable "godaddy_record_name" {
  description = "Record name relative to godaddy_domain. \"@\" is the apex; \"n8n\" creates n8n.example.com. Must correspond to ui_host: the module advertises ui_host, so a record at a different name resolves nothing useful."
  type        = string
  default     = "n8n"
  nullable    = false
}

variable "godaddy_record_ttl" {
  description = "TTL in seconds for the A record. GoDaddy enforces a 600-second minimum on most plans and rejects anything lower."
  type        = number
  default     = 600
  nullable    = false

  validation {
    condition     = var.godaddy_record_ttl >= 600
    error_message = "godaddy_record_ttl must be at least 600: GoDaddy rejects lower values on most plans."
  }
}

variable "ingress_ip" {
  description = "Address the A record points at: the external address of your ingress controller, not of any n8n pod. Required when godaddy_domain is set. This must be reachable from wherever the record is resolved: a public record pointing at an RFC 1918 address resolves fine and then goes nowhere."
  type        = string
  default     = null
}

variable "godaddy_api_key" {
  description = "GoDaddy API key. Only read when godaddy_domain is set. Prefer the GODADDY_API_KEY environment variable over terraform.tfvars."
  type        = string
  default     = null
  sensitive   = true
}

variable "godaddy_api_secret" {
  description = "GoDaddy API secret. Only read when godaddy_domain is set. Prefer the GODADDY_API_SECRET environment variable over terraform.tfvars."
  type        = string
  default     = null
  sensitive   = true
}
