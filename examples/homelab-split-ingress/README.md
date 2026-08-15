# Homelab split-ingress example

Two hostnames instead of one, on the same Kubernetes-native backend as [`../homelab`](../homelab): the editor on one, production webhooks on the other. Routing belongs to this example (`create_ingress = false`), so it renders both `Ingress` objects itself and points them at the Services the module builds.

```
editor_host   →  n8n-main                editor UI, REST API, /webhook-test
webhook_host  →  n8n-webhook-processor   /webhook, /webhook-waiting, /form,
                                         /form-waiting, /mcp
```

**No license required.** Splitting webhook processors off the main process is queue-mode behaviour, and n8n ships queue mode in the Community edition. See [compare editions](https://docs.n8n.io/deploy/host-n8n/community-edition-features), which lists queue mode among what is included.

## Why split at all

Not for load. Both hostnames land on the same ingress controller, and the webhook processors are already separate pods in `../homelab`: that part is the module's queue-mode wiring, not the ingress.

The split buys **one authentication boundary you can actually use**. n8n's own SSO is a licensed feature and this module deploys the Community edition, so the identity boundary has to sit in front of n8n rather than inside it: and it cannot cover the whole deployment, because webhook senders are machines that cannot complete an interactive login. With two hostnames you can put Cloudflare Access (or an OIDC proxy, or an IP allowlist) in front of `editor_host` while `webhook_host` stays open: and `webhook_host` serves *only* the webhook prefixes, so an unauthenticated caller reaching it cannot get to the editor, the REST API, or anything else. Everything not routed gets the controller's 404.

The secondary benefit is that rate limiting, WAF rules and request-size limits can be applied to the untrusted hostname alone, where they belong.

## What it creates

Everything [`../homelab`](../homelab) creates, minus the module's own `Ingress` pair, plus:

- `Ingress/n8n-webhook` - `webhook_host`, the five webhook path prefixes only, no catch-all
- `Ingress/n8n-editor` - `editor_host`, `/` to the mains, with the same webhook prefixes routed to the webhook processors ahead of it

The webhook prefixes come from the module's `n8n_webhook_path_prefixes` output rather than being hardcoded, so neither `Ingress` drifts as n8n adds endpoint families.

## Why the editor host also routes the webhook prefixes

The module runs the chart with `disableProductionWebhooksOnMainProcess = true`, so the main pods serve none of those five prefixes. Without those rules on the editor `Ingress`, the catch-all hands `/webhook/...` to a main pod, the request falls through to the editor's SPA handler, and the caller gets **HTTP 200 with an HTML body**: a delivery that reads as success while nothing executed.

`/webhook-test` is deliberately *not* in that list: manual "listen for test event" executions run on the mains, so it stays on the catch-all.

## Prerequisites

Same as [`../homelab`](../homelab): a running cluster, the CloudNativePG operator, ingress-nginx, cert-manager with the `ClusterIssuer` named in `cluster_issuer`, and a kubeconfig. Additionally:

- Both hostnames resolvable to the cluster. DNS is yours to create - see [`../homelab-cloudflare/dns.tf`](../homelab-cloudflare/dns.tf) for one worked version if you front the cluster with a Cloudflare Tunnel.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: editor_host, webhook_host


terraform init
terraform apply
```

Then check both hostnames do what they should:

```bash
# Editor answers on the editor host
curl -sS -o /dev/null -w '%{http_code}\n' "$(terraform output -raw editor_url)/healthz"

# and does NOT answer on the webhook host, 404 is the correct result here
curl -sS -o /dev/null -w '%{http_code}\n' "$(terraform output -raw webhook_base_url)/"
```

## Putting a policy in front of the editor

This example deliberately does not create the policy. A Cloudflare Access application is account-scoped identity configuration with its own lifecycle, not something a workload module should create and destroy alongside a deployment. Create it against `editor_host` in the Zero Trust dashboard, or with `cloudflare_zero_trust_access_application` in a separate configuration.

Whatever you use, apply it to `editor_host` only. Applying it to `webhook_host` breaks every webhook.

For a LAN-reachable editor with no tunnel in front, an IP allowlist is enough:

```hcl
editor_ingress_extra_annotations = {
  "nginx.ingress.kubernetes.io/whitelist-source-range" = "192.168.1.0/24"
}
```

Note that a request arriving through a tunnel or reverse proxy carries *that proxy's* source address, so an allowlist only bites on the path that reaches nginx directly.

## Teardown

```bash
terraform destroy
```

Both `Ingress` objects go with it. DNS records are not managed here, so they stay.

## Differences from `../homelab`

| | `homelab` | `homelab-split-ingress` |
|---|---|---|
| Hostnames | one | two |
| `create_ingress` | `true` (module renders both `Ingress` objects) | `false` (this example renders them) |
| `n8n_webhook_url` | derived from the single host | `https://webhook_host` |
| Auth boundary | all-or-nothing | editor only |
| DNS records | one | two |

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.12 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [kubernetes_ingress_v1.editor](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.webhook](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cluster_issuer"></a> [cluster\_issuer](#input\_cluster\_issuer) | cert-manager ClusterIssuer that signs both Ingress certificates. Must already exist in the cluster - this example does not install cert-manager. Each hostname gets its own Certificate, so an issuer scoped to a single DNS zone needs both names inside it. | `string` | `"letsencrypt-prod"` | no |
| <a name="input_editor_host"></a> [editor\_host](#input\_editor\_host) | Hostname serving the editor UI, the REST API and test webhooks. This is n8n's canonical hostname (N8N\_HOST). Put your authentication policy in front of this name, Cloudflare Access, an OIDC proxy, an IP allowlist, none of which breaks webhook delivery, because production webhooks are advertised on webhook\_host instead. | `string` | `"n8n.example.com"` | no |
| <a name="input_editor_ingress_extra_annotations"></a> [editor\_ingress\_extra\_annotations](#input\_editor\_ingress\_extra\_annotations) | Annotations added to the editor Ingress only, on top of ingress\_extra\_annotations. Where an IP allowlist goes when the editor is reached directly on the LAN rather than through an identity-aware proxy: {"nginx.ingress.kubernetes.io/whitelist-source-range" = "192.168.1.0/24"}. Note that a request arriving through a tunnel or reverse proxy carries that proxy's source address, so an allowlist is meaningful only on the path that reaches nginx directly. | `map(string)` | `{}` | no |
| <a name="input_ingress_class_name"></a> [ingress\_class\_name](#input\_ingress\_class\_name) | IngressClass both Ingresses are created with. The cluster must already run a controller for it. | `string` | `"nginx"` | no |
| <a name="input_ingress_extra_annotations"></a> [ingress\_extra\_annotations](#input\_ingress\_extra\_annotations) | Annotations added to both Ingresses. Merged over this example's own (cert-manager issuer, body size, proxy timeouts), so a key set here wins. | `map(string)` | `{}` | no |
| <a name="input_keda_installed"></a> [keda\_installed](#input\_keda\_installed) | Set true when the KEDA operator is already installed cluster-wide. Workers then scale on Redis queue depth rather than CPU. Leave false if unsure: a ScaledObject with no operator behind it never reconciles and workers stay at their minimum replica count without anything failing. | `bool` | `false` | no |
| <a name="input_kubeconfig_path"></a> [kubeconfig\_path](#input\_kubeconfig\_path) | Path to kubeconfig used by the kubernetes, helm and kubectl providers. | `string` | `"~/.kube/config"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace to deploy into. Created by the module. | `string` | `"n8n"` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass for the CNPG and Valkey PVCs. Empty uses whatever the cluster's default StorageClass is. | `string` | `""` | no |
| <a name="input_timezone"></a> [timezone](#input\_timezone) | Timezone n8n schedules Cron triggers in (GENERIC\_TIMEZONE). | `string` | `"UTC"` | no |
| <a name="input_webhook_host"></a> [webhook\_host](#input\_webhook\_host) | Hostname serving production webhooks, forms, waiting webhooks and MCP. Passed to the module as n8n\_webhook\_url, so it is what n8n hands out in every generated webhook URL. Nothing else is routed on this name: a request to any other path gets the ingress controller's 404, which is what makes it safe to leave open to the internet. | `string` | `"hooks.example.com"` | no |
| <a name="input_webhook_ingress_extra_annotations"></a> [webhook\_ingress\_extra\_annotations](#input\_webhook\_ingress\_extra\_annotations) | Annotations added to the webhook Ingress only, on top of ingress\_extra\_annotations. Rate limiting belongs here if the controller is doing it rather than an upstream WAF: {"nginx.ingress.kubernetes.io/limit-rps" = "20"}. This is the hostname exposed to unauthenticated callers, so it is the one worth bounding. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_backing_services"></a> [backing\_services](#output\_backing\_services) | Which backend provides Postgres and Redis for this deployment, and the in-cluster endpoints for each. |
| <a name="output_editor_url"></a> [editor\_url](#output\_editor\_url) | URL for the n8n editor UI and REST API. Put your authentication policy in front of this hostname. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that points kubectl at the cluster this example deployed to. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | Editor URL under the name tests/scripts/smoke-test.sh reads. Points at editor\_host: the smoke test checks the editor's health endpoint, which the webhook hostname deliberately does not serve. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace the n8n release and its backing services were deployed into. |
| <a name="output_webhook_base_url"></a> [webhook\_base\_url](#output\_webhook\_base\_url) | Public base URL for webhooks, forms, waiting webhooks and MCP. This is what n8n hands out in generated webhook URLs (passed to the module as n8n\_webhook\_url). |
| <a name="output_webhook_path_prefixes"></a> [webhook\_path\_prefixes](#output\_webhook\_path\_prefixes) | Path prefixes routed to the webhook processors on both hostnames. Read from the module rather than hardcoded, so the Ingresses cannot drift as n8n adds endpoints. |
<!-- END_TF_DOCS -->
