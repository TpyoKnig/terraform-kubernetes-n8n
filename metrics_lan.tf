# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Optional LAN-exposed Service for the n8n main pod's /metrics endpoint ─────
# Off by default. Lets an off-cluster Prometheus (e.g. a compose stack on a
# bastion) scrape metrics without k8s-API-proxy discovery or in-cluster
# Prometheus Operator. The n8n release otherwise sits behind the cluster's
# ingress controller, which does not route /metrics; this Service goes straight
# to the main pod instead.

resource "kubernetes_service_v1" "n8n_main_metrics_lan" {
  count = coalesce(var.metrics_lan_expose.enabled, false) ? 1 : 0

  metadata {
    name      = coalesce(var.metrics_lan_expose.service_name, "${local.cnpg_release_name}-main-metrics-lan")
    namespace = local.namespace_name
    # ip is a convenience for Cilium LB-IPAM, the allocator this was written
    # against. Every other allocator spells the same request differently
    # (metallb.universe.tf/loadBalancerIPs, kube-vip.io/loadbalancerIPs), so
    # annotations is the general form and is merged last, it can override the
    # Cilium key, or carry a different one entirely. Without it, a MetalLB user
    # setting ip got an annotation their allocator ignores and an arbitrary
    # address, with nothing reporting that the request was dropped.
    annotations = merge(
      length(var.metrics_lan_expose.ip) > 0 ? { "io.cilium/lb-ipam-ips" = var.metrics_lan_expose.ip } : {},
      var.metrics_lan_expose.annotations,
    )
  }

  spec {
    type = "LoadBalancer"

    selector = {
      "app.kubernetes.io/name"      = "n8n"
      "app.kubernetes.io/component" = "main"
    }

    port {
      name        = "metrics"
      port        = 5678
      target_port = 5678
      protocol    = "TCP"
    }

    external_traffic_policy = "Cluster"
  }

  depends_on = [helm_release.n8n]
}
