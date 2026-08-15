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
  description = "Hostname served by ingress. A DNS record for it has to reach the cluster's ingress controller, and creating that record is yours to do - this example manages no DNS, because how a name reaches a self-hosted cluster depends entirely on the setup (a tunnel, a public LoadBalancer, split-horizon DNS on the LAN, a reverse proxy). See examples/homelab-cloudflare for one worked version."
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
