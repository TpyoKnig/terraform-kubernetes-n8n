# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Optional GoDaddy DNS record ───────────────────────────────────────────────
# DNS is caller-owned on this platform, the root module creates no records.
# This example creates the one record it needs, following the convention that
# the DNS provider lives in the example and never in the root module.
#
# Off unless godaddy_domain is set, so the example still applies into a cluster
# whose DNS is managed elsewhere (or by hand).
#
# Unlike examples/homelab-cloudflare, this is a plain A record straight to an
# address you supply. There is no tunnel in front of it, which has two
# consequences worth being deliberate about:
#
#   1. The address must be reachable from wherever the record is resolved. A
#      record in public DNS pointing at an RFC 1918 address resolves fine and
#      then goes nowhere, which is a confusing failure. Use this when your
#      ingress has a routable address, or when the zone is only resolved on a
#      network that can reach it.
#   2. Nothing terminates or filters in front of your ingress controller. The
#      Cloudflare example gets an edge proxy for free; here the ingress
#      controller is directly exposed, so its own configuration is the whole
#      security boundary.
#
# TLS is cert-manager's job either way. This record only has to make the
# hostname resolve so an HTTP-01 challenge can complete.

resource "godaddy-dns_record" "n8n" {
  count = var.godaddy_domain != null ? 1 : 0

  domain = var.godaddy_domain

  # GoDaddy record names are relative to the domain. "@" is the apex.
  name = var.godaddy_record_name
  type = "A"
  data = var.ingress_ip
  ttl  = var.godaddy_record_ttl
}
