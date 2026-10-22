# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Optional Cloudflare DNS record ────────────────────────────────────────────
# DNS is caller-owned: the root module creates no records, because how a name
# reaches a self-hosted cluster depends entirely on the setup. This example
# creates the one record it needs, and keeps to the convention that a DNS
# provider lives in an example, never in the root module.
#
# Off unless cloudflare_zone_id is set, so the example still applies into a
# cluster whose DNS is managed elsewhere (or by hand).
#
# This creates a CNAME to a Cloudflare Tunnel, not an A record to the ingress
# LoadBalancer IP. A homelab's ingress usually sits on a private address that
# public DNS cannot route to, and publishing it would be wrong even where it
# resolves. The tunnel already terminates at ingress-nginx, so the record only
# has to name it.
#
# The record MUST be proxied: an unproxied CNAME to <id>.cfargotunnel.com does
# not resolve, because the tunnel hostname only exists inside Cloudflare's edge.
#
# Cloudflare API token needs Zone:DNS:Edit on the zone. The tunnel itself is not
# managed here, it is long-lived cluster infrastructure that outlives any one
# n8n deployment, and adopting it into this example's state would mean a
# terraform destroy of n8n could take every other service on the tunnel with it.

# Renamed from cloudflare_record in the provider's v5 rewrite; this moved
# block carries the existing state across without a destroy/recreate. Safe
# to drop once every caller has applied past this change (moved blocks are
# a courtesy to existing state, not a permanent fixture).
moved {
  from = cloudflare_record.n8n
  to   = cloudflare_dns_record.n8n
}

resource "cloudflare_dns_record" "n8n" {
  count = var.cloudflare_zone_id != null ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = var.ui_host
  type    = "CNAME"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  # Required in v5 (was computed/optional in v4, which always sent 1 for a
  # proxied record). 1 means "automatic": Cloudflare ignores TTL on a
  # proxied record regardless, but the field still has to be sent.
  ttl = 1

  comment = "n8n editor + webhooks, managed by terraform-kubernetes-n8n examples/homelab-cloudflare"
}
