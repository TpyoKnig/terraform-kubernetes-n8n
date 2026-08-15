# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Plan-time tests for the Cloudflare split-ingress example using mocked
# providers.
#
# The split routing itself is covered by ../homelab-split-ingress. What is
# distinctive here is everything the tunnel adds: two DNS records instead of
# one, the proxy-hop count, and the fact that DNS stays optional so the example
# still applies into a cluster whose zone is managed elsewhere.
#
# Run: terraform test
#   (from examples/homelab-cloudflare-split-ingress/, mocks require terraform >= 1.11)

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "cloudflare" {}

variables {
  editor_host  = "n8n.test.example.com"
  webhook_host = "n8n-hooks.test.example.com"
}

run "no_dns_records_without_a_zone" {
  command = plan

  # cloudflare_zone_id is null by default. The example has to stay applicable
  # against a cluster whose DNS lives somewhere else, so the records are opt-in
  # rather than required.
  assert {
    condition     = length(cloudflare_record.n8n) == 0
    error_message = "No DNS records should be planned when cloudflare_zone_id is null; got ${length(cloudflare_record.n8n)}."
  }
}

run "a_zone_produces_one_record_per_hostname" {
  command = plan

  variables {
    cloudflare_zone_id   = "0123456789abcdef0123456789abcdef"
    cloudflare_tunnel_id = "beb9653a-ec18-4811-a689-3a4e05fcf106"
    cloudflare_api_token = "test-token"
  }

  # Two hostnames, two records. The single-host cloudflare example creates one;
  # publishing only the editor here would leave every production webhook
  # unresolvable while the deployment looked healthy.
  assert {
    condition     = length(cloudflare_record.n8n) == 2
    error_message = "Expected one record per hostname (2); got ${length(cloudflare_record.n8n)}."
  }

  assert {
    condition = alltrue([
      for r in cloudflare_record.n8n : r.proxied == true
    ])
    error_message = "Every record must be proxied: an unproxied CNAME to cfargotunnel.com does not resolve, because that hostname exists only inside Cloudflare's edge."
  }

  assert {
    condition = alltrue([
      for r in cloudflare_record.n8n : endswith(r.content, ".cfargotunnel.com")
    ])
    error_message = "Records must be CNAMEs at the tunnel, not A records at the ingress LoadBalancer: a homelab ingress address is usually private."
  }

  assert {
    condition     = length(setsubtract([for r in cloudflare_record.n8n : r.name], [var.editor_host, var.webhook_host])) == 0
    error_message = "The records must name exactly the two hostnames the Ingresses serve."
  }
}

run "a_zone_without_a_tunnel_is_rejected" {
  command = plan

  variables {
    cloudflare_zone_id = "0123456789abcdef0123456789abcdef"
  }

  # There is nothing to point a CNAME at without the tunnel UUID, and the
  # failure would otherwise be a record whose content is ".cfargotunnel.com".
  expect_failures = [var.cloudflare_zone_id]
}

run "proxy_hops_defaults_to_two_behind_the_tunnel" {
  command = plan

  # One hop is ingress-nginx. The Cloudflare edge is the second. The sibling
  # example defaults to 1 because it has no tunnel; inheriting that here would
  # make n8n read cloudflared's address as the client on every request.
  assert {
    condition     = var.proxy_hops == 2
    error_message = "proxy_hops should default to 2 in the tunnel topology; got ${var.proxy_hops}."
  }
}

run "proxy_hops_rejects_a_fractional_count" {
  command = plan

  variables {
    proxy_hops = 2.5
  }

  expect_failures = [var.proxy_hops]
}

run "webhooks_are_advertised_on_the_webhook_host" {
  command = plan

  # The whole point of the split. If n8n advertised the editor host, every
  # generated webhook URL would name a host that serves the editor and refuses
  # production webhooks, and nothing would error.
  assert {
    condition     = module.n8n.n8n_url == "https://${var.editor_host}"
    error_message = "Editor URL should be the editor host; got ${module.n8n.n8n_url}."
  }
}

run "one_hostname_for_both_roles_is_rejected" {
  command = plan

  variables {
    editor_host  = "n8n.test.example.com"
    webhook_host = "N8N.Test.Example.com"
  }

  # Case-insensitive on purpose: DNS is, and two Ingresses claiming the same
  # host differing only in case is the single-hostname topology with extra
  # steps.
  expect_failures = [var.webhook_host]
}

run "no_shared_claim_without_a_class" {
  command = plan

  # Binary data stays in Postgres, which is n8n's own default in queue mode.
  # The example has to stay applicable on a cluster with no RWX class.
  assert {
    condition     = length(kubernetes_persistent_volume_claim_v1.shared) == 0
    error_message = "No claim should be planned when shared_storage_class is null."
  }
}

run "a_class_produces_one_rwx_claim" {
  command = plan

  variables {
    shared_storage_class = "nfs-csi"
  }

  assert {
    condition     = length(kubernetes_persistent_volume_claim_v1.shared) == 1
    error_message = "Expected exactly one shared claim."
  }

  # ReadWriteOnce would bind to one node and leave the other two pod types
  # unable to mount it, which is the failure this whole file exists to avoid.
  # Membership rather than equality: access_modes is a set, and comparing a set
  # to a list literal fails on type before it ever compares contents.
  assert {
    condition = (
      contains(kubernetes_persistent_volume_claim_v1.shared[0].spec[0].access_modes, "ReadWriteMany") &&
      length(kubernetes_persistent_volume_claim_v1.shared[0].spec[0].access_modes) == 1
    )
    error_message = "The shared claim must be exactly ReadWriteMany; three pod types mount it."
  }
}

run "shared_mount_path_must_be_absolute" {
  command = plan

  variables {
    shared_storage_class = "nfs-csi"
    shared_mount_path    = "opt/n8n-shared"
  }

  expect_failures = [var.shared_mount_path]
}
