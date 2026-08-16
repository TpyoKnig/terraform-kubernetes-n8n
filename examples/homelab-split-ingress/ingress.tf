# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Split Ingress, ingress-nginx flavour ──────────────────────────────────────
# Two Ingresses on one controller instead of the chart's single-host pair:
#
#   webhook_host → n8n-webhook-processor   webhook/form/waiting/MCP only
#   editor_host  → n8n-main                editor UI, REST API, test webhooks
#
# There is one load balancer here, not two: a homelab has no internal/external
# split to draw. The split is by hostname, and what it buys is the
# ability to put an authentication policy in front of the editor without
# breaking webhook delivery. n8n's own SSO is licensed and this module deploys
# the Community edition, so that policy has to live at the ingress. Cloudflare
# Access on editor_host is the usual shape: every request to that hostname needs
# an identity, while webhook_host stays open, because the systems calling it are
# machines that cannot complete an interactive login. Applied to a single
# hostname serving both, either the editor is unauthenticated or webhooks
# break.
#
# The prefixes come from the module output rather than being hardcoded, so this
# example cannot drift as n8n adds endpoints.

locals {
  ingress_annotations = merge(
    {
      "cert-manager.io/cluster-issuer" = var.cluster_issuer

      # n8n accepts large binary payloads and holds long-running requests; the
      # nginx defaults (1m body, 60s read) truncate and time them out. Same
      # values the module sets on the Ingress it owns.
      "nginx.ingress.kubernetes.io/proxy-body-size"    = "32m"
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600"
      "nginx.ingress.kubernetes.io/proxy-send-timeout" = "3600"
    },
    var.ingress_extra_annotations,
  )
}

# ── Webhook host: webhook traffic, plus the agents callback prefix ────────────
# No catch-all rule, deliberately. A request to any path not listed below gets
# the controller's default 404 and never reaches the editor. That is the point
# of the second hostname: it is the one that faces the internet, so the only
# things reachable on it are the surfaces that have to be.
#
# /rest/projects is one of them, which was not obvious. See the note on the
# rule itself.

resource "kubernetes_ingress_v1" "webhook" {
  metadata {
    name      = "n8n-webhook"
    namespace = module.n8n.namespace

    annotations = merge(
      local.ingress_annotations,
      var.webhook_ingress_extra_annotations,
    )
  }

  spec {
    ingress_class_name = var.ingress_class_name

    rule {
      host = var.webhook_host
      http {
        dynamic "path" {
          for_each = module.n8n.n8n_webhook_path_prefixes

          content {
            path      = path.value
            path_type = "Prefix"
            backend {
              service {
                name = module.n8n.n8n_webhook_service_name
                port { number = module.n8n.n8n_service_port }
              }
            }
          }
        }

        # Agents chat integrations, and the reason this hostname serves more
        # than webhooks. n8n builds the Slack app-install URL and the platform
        # event callbacks by appending /rest/projects/<id>/agents/... onto
        # getWebhookBaseUrl(), which is WEBHOOK_URL, which is this hostname.
        # Those are main-pod routes, so without this rule connecting a Slack
        # agent 404s at the end of the OAuth flow, after the user has already
        # granted consent. It is upstream n8n's construction and has nothing to
        # do with N8N_EDITOR_BASE_URL, so no amount of module configuration
        # fixes it: the path has to be routed for OAuth to complete at all.
        #
        # Scoped to /rest/projects rather than /rest, because that is the
        # whole surface those three constructions use and it is a literal
        # prefix, so it needs no regex and no controller-specific annotation.
        # /rest/login, /rest/credentials and the rest of the REST API stay off
        # this hostname, which is what the no-catch-all rule above is for.
        #
        # It has to be reachable from the internet, not just from inside the
        # cluster: the OAuth callback is a browser redirect the admin follows,
        # and the platform webhooks are server-to-server POSTs from Slack and
        # Telegram. Telegram in particular inspects this base URL and silently
        # drops to polling mode if it is not a public https:// name.
        path {
          path      = "/rest/projects"
          path_type = "Prefix"
          backend {
            service {
              name = module.n8n.n8n_service_name
              port { number = module.n8n.n8n_service_port }
            }
          }
        }
      }
    }

    # One Certificate per hostname, because the two Ingresses are separate
    # objects and cert-manager keys its Certificate off the Ingress it annotates.
    tls {
      hosts       = [var.webhook_host]
      secret_name = replace("${var.webhook_host}-tls", ".", "-")
    }
  }

  depends_on = [module.n8n]
}

# ── Editor host: the full surface ─────────────────────────────────────────────
# Serves the editor and REST API at /, and routes the webhook prefixes to the
# webhook processors ahead of that catch-all.
#
# Routing the prefixes here is not cosmetic. The module runs the chart with
# disableProductionWebhooksOnMainProcess = true, so the main pods serve none of
# them. Without these rules the catch-all hands /webhook to a main pod, the
# request falls through to the editor's SPA handler, and the caller gets HTTP
# 200 with an HTML body, a delivery that reads as success while nothing
# executed. Test webhooks (/webhook-test) do stay on the mains, and are covered
# by the catch-all, which is correct: manual executions run there.

resource "kubernetes_ingress_v1" "editor" {
  metadata {
    name      = "n8n-editor"
    namespace = module.n8n.namespace

    annotations = merge(
      local.ingress_annotations,
      var.editor_ingress_extra_annotations,
    )
  }

  spec {
    ingress_class_name = var.ingress_class_name

    rule {
      host = var.editor_host
      http {
        dynamic "path" {
          for_each = module.n8n.n8n_webhook_path_prefixes

          content {
            path      = path.value
            path_type = "Prefix"
            backend {
              service {
                name = module.n8n.n8n_webhook_service_name
                port { number = module.n8n.n8n_service_port }
              }
            }
          }
        }

        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = module.n8n.n8n_service_name
              port { number = module.n8n.n8n_service_port }
            }
          }
        }
      }
    }

    tls {
      hosts       = [var.editor_host]
      secret_name = replace("${var.editor_host}-tls", ".", "-")
    }
  }

  depends_on = [module.n8n]
}
