# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Cloudflare DNS: one record per hostname ───────────────────────────────────
# DNS is caller-owned: the root module creates no records, because how a name
# reaches a self-hosted cluster has no portable answer. This example creates the
# two it needs, and keeps to the convention that a DNS provider lives in an
# example and never in the root module.
#
# Off unless cloudflare_zone_id is set, so the example still applies into a
# cluster whose DNS is managed elsewhere.
#
# These are CNAMEs to a Cloudflare Tunnel, not A records to the ingress
# LoadBalancer IP. A homelab's ingress usually sits on a private address that
# public DNS cannot route to, and publishing it would be wrong even where it
# resolves. The tunnel already terminates at ingress-nginx, so the records only
# have to name it.
#
# They MUST be proxied: an unproxied CNAME to <id>.cfargotunnel.com does not
# resolve, because that hostname exists only inside Cloudflare's edge.
#
# There is no wildcard here on purpose. A tunnel ingress rule may well match
# *.example.com, but that is tunnel routing, not DNS: each hostname still needs
# its own record or traffic never reaches the tunnel at all.
#
# The tunnel itself is not managed here. It is long-lived cluster
# infrastructure that outlives any one n8n deployment, and adopting it into this
# example's state would mean a terraform destroy of n8n could take every other
# service on the tunnel with it.
#
# The API token needs Zone:DNS:Edit on the zone.

locals {
  # Both hostnames, so the record set cannot drift from what the Ingresses
  # actually serve.
  dns_hostnames = var.cloudflare_zone_id != null ? {
    editor  = var.editor_host
    webhook = var.webhook_host
  } : {}
}

# Renamed from cloudflare_record in the provider's v5 rewrite; this moved
# block carries each for_each instance's existing state across by its
# existing key ("editor"/"webhook") without a destroy/recreate. Safe to drop
# once every caller has applied past this change (moved blocks are a
# courtesy to existing state, not a permanent fixture).
moved {
  from = cloudflare_record.n8n
  to   = cloudflare_dns_record.n8n
}

resource "cloudflare_dns_record" "n8n" {
  for_each = local.dns_hostnames

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "CNAME"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  # Required in v5 (was computed/optional in v4, which always sent 1 for a
  # proxied record). 1 means "automatic": Cloudflare ignores TTL on a
  # proxied record regardless, but the field still has to be sent.
  ttl = 1

  comment = "n8n ${each.key}, managed by terraform-kubernetes-n8n examples/homelab-cloudflare-split-ingress"
}
