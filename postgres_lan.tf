# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Optional LAN-exposed Service for the CNPG rw endpoint ─────────────────────
# Off by default. Enables Grafana / db-tool access without kubectl port-forward
# on the k8s backend. CNPG creates a Service named "<cluster>-rw" of type
# ClusterIP; this resource adds a peer Service of type LoadBalancer with the
# same selector and requests the given IP from Cilium's LB pool.

resource "kubernetes_service_v1" "cnpg_lan" {
  count = local.cnpg_enabled && coalesce(var.cnpg_lan_expose.enabled, false) ? 1 : 0

  metadata {
    name      = coalesce(var.cnpg_lan_expose.service_name, "${local.cnpg_cluster_name}-lan")
    namespace = local.namespace_name
    # ip is a convenience for Cilium LB-IPAM, the allocator this was written
    # against. Every other allocator spells the same request differently
    # (metallb.universe.tf/loadBalancerIPs, kube-vip.io/loadbalancerIPs), so
    # annotations is the general form and is merged last, it can override the
    # Cilium key, or carry a different one entirely. Without it, a MetalLB user
    # setting ip got an annotation their allocator ignores and an arbitrary
    # address, with nothing reporting that the request was dropped.
    annotations = merge(
      length(var.cnpg_lan_expose.ip) > 0 ? { "io.cilium/lb-ipam-ips" = var.cnpg_lan_expose.ip } : {},
      var.cnpg_lan_expose.annotations,
    )
  }

  spec {
    type = "LoadBalancer"

    # Match the pods CNPG labels as the rw endpoint (primary role).
    selector = {
      "cnpg.io/cluster"      = local.cnpg_cluster_name
      "cnpg.io/instanceRole" = "primary"
    }

    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }

    external_traffic_policy = "Local"
  }

  depends_on = [kubectl_manifest.cnpg_cluster]
}
