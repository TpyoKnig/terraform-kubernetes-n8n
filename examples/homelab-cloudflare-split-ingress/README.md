# Homelab Cloudflare split-ingress example

Two hostnames behind a Cloudflare Tunnel: the editor on one, production webhooks on the other, with a proxied DNS record for each. It is [`../homelab-split-ingress`](../homelab-split-ingress) with the tunnel in front, and the differences that follow from that are the reason it exists separately.

```
                       n8n.example.com  ─┐   editor UI, REST API, /webhook-test
                                          │   (put a policy in front of this one)
                 n8n-hooks.example.com  ─┤   /webhook, /webhook-waiting, /form,
                                          │   /form-waiting, /mcp
                                   Cloudflare edge
                                          │
                                   cloudflared
                                          │
                                   ingress-nginx
```

**No license required.** Queue mode and separate webhook processors ship in the Community edition.

## What it adds over `../homelab-split-ingress`

None of it is cosmetic, and none of it announces itself when it is wrong.

| | `homelab-split-ingress` | this example |
|---|---|---|
| `proxy_hops` | `1`, ingress-nginx alone | `2`, the Cloudflare edge as well |
| DNS | yours to create | one proxied CNAME per hostname, opt-in |
| Ingress address | reachable directly | private, reached only through the tunnel |
| Shared filesystem | none | optional `ReadWriteMany` claim across all three pod types |
| Namespace | module-created | example-created, so the claim can exist first |

## One filesystem across three pod types

Queue mode runs main, worker and webhook-processor pods, and they do not share a filesystem. The chart mounts its own `data` volume on main only, and this module leaves persistence at the chart default, so that volume is an `emptyDir`.

Splitting the ingress makes the gap concrete. A webhook arrives at a webhook-processor pod, the execution runs on a worker, and the editor renders the result on main. Three pods, three filesystems.

Set `shared_storage_class` to an RWX-capable class and the example creates a claim and mounts it into all three:

```hcl
shared_storage_class = "nfs-csi"    # or smb, cephfs, whatever the cluster offers
shared_storage_size  = "20Gi"
```

**Two lines make it actually take effect, and the second is the one people miss.** n8n defaults binary data to `filesystem` in regular mode but to `database` in scaling mode, and this module always runs queue mode. Mount the volume without setting the mode and every payload still goes to Postgres: the mount is there, empty, and nothing reports a problem. The example sets both for you:

```hcl
{ name = "N8N_DEFAULT_BINARY_DATA_MODE", value = "filesystem" }
{ name = "N8N_STORAGE_PATH",             value = "/opt/n8n-shared/storage" }
```

Leave `shared_storage_class` null and no claim is created, binary data stays in Postgres, and the example still applies on a cluster with no RWX class. That is fine until payloads get large.

**Check the class can actually reclaim before you trust it.** With the NFS CSI driver, the controller mounts the share itself to remove a released PVC's directory. Where that mount fails, an appliance serving only NFSv3 being the common case, the PV is deleted and every byte stays on the server. It reads as automatic cleanup and is not. Create a throwaway PVC against the class, delete it, and look at the server.

**The namespace is created by this example, not the module.** The claim has to exist before the Helm release, because a pod referencing a missing PVC stays `Pending` and the release never goes ready. The claim needs a namespace, so the order is namespace, claim, module. `create_namespace = false` exists for this. The cost is that `terraform destroy` removes the namespace and everything in it, the claim included: if that data matters, set the class's `reclaimPolicy` to `Retain` or keep the claim in a separate configuration.

## Count the hops

`N8N_PROXY_HOPS` tells n8n how many proxies append to `X-Forwarded-For` before a request reaches a pod. Behind ingress-nginx alone that is `1`. Add the Cloudflare edge and it is `2`.

Get it wrong in either direction and nothing errors. Too low and n8n treats a proxy address as the client, so every rate limit, audit log line and IP-based restriction collapses onto one source. Too high and it trusts a value the client could have forged. Raise `proxy_hops` again for anything further out, a WAF or a second reverse proxy.

## Two records, not a wildcard

Set `cloudflare_zone_id` and `cloudflare_tunnel_id` and the example creates a proxied CNAME for each hostname at `<tunnel-id>.cfargotunnel.com`.

They must be proxied. An unproxied CNAME to `cfargotunnel.com` does not resolve, because that hostname exists only inside Cloudflare's edge.

A tunnel ingress rule matching `*.example.com` is **tunnel routing, not DNS**. Each hostname still needs its own record, or traffic never reaches the tunnel to be routed. This catches people who see the wildcard in their tunnel config and expect DNS to follow.

Leave `cloudflare_zone_id` null and no records are created, so the example still applies into a cluster whose zone is managed elsewhere.

The tunnel itself is not managed here. It is long-lived cluster infrastructure serving every other hostname too, so a `terraform destroy` of n8n must not be able to take it down.

## Two hostname traps worth knowing before you pick names

**Certificate coverage is one label deep.** Cloudflare Universal SSL covers `example.com` and `*.example.com`, and nothing further. A webhook host at `hooks.n8n.example.com` is two labels deep and fails TLS at the Cloudflare edge unless Advanced Certificate Manager is enabled. Keep both names single-level, as the defaults here do, or budget for the certificate. cert-manager will happily issue for the deeper name, so this looks correct in-cluster right up until you test from outside.

**A hostname can be silently refused.** Providers run brand and abuse filters over DNS names. A record can be accepted by the API, return `success: true`, and never publish to the authoritative nameservers. Names that pair a product with an official-sounding word are the ones to watch: `n8n-community.example.com` behaves this way where `community-n8n.example.com` does not.

If a new hostname does not resolve, do not wait it out. Query the zone's authoritative nameserver directly and compare against a throwaway name created at the same moment:

```bash
NS=$(dig +short NS example.com | head -1)
dig +short n8n.example.com @"$NS"        # yours
dig +short throwaway-xyz.example.com @"$NS"   # control, created just now
```

If the control publishes and yours does not, the name is filtered. Pick another.

## Prerequisites

Same as [`../homelab`](../homelab): a running cluster, the CloudNativePG operator, ingress-nginx, cert-manager with the `ClusterIssuer` named in `cluster_issuer`, and a kubeconfig. Additionally:

- A Cloudflare Tunnel already terminating at your ingress controller, and its UUID (`cloudflared tunnel list`).
- An API token with `Zone:DNS:Edit`, if you want the records created here.
- ingress-nginx configured to derive the client address from `X-Forwarded-For`, otherwise the editor allowlist below compares against cloudflared's own address and admits everyone or no one:

  ```yaml
  controller:
    config:
      use-forwarded-headers: "true"
      compute-full-forwarded-for: "true"
  ```

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: editor_host, webhook_host, cloudflare_*

export CLOUDFLARE_API_TOKEN=...    # preferred over putting it in tfvars

terraform init
terraform apply
```

Then check the split actually routes, which a successful apply does not tell you:

```bash
# Editor answers on the editor host
curl -sS -o /dev/null -w '%{http_code}\n' "$(terraform output -raw editor_url)/healthz"

# Webhook host returns JSON, never HTML. HTML means the prefixes reached a main
# pod and production webhooks are silently not executing.
curl -sS "$(terraform output -raw webhook_base_url)/webhook/nope" -w '\n%{content_type}\n'

# and the editor is NOT reachable there; 404 is the correct result
curl -sS -o /dev/null -w '%{http_code}\n' "$(terraform output -raw webhook_base_url)/"
```

## Putting a policy in front of the editor

Apply it to `editor_host` only. Applying it to `webhook_host` breaks every webhook, because the callers are machines that cannot complete an interactive login.

Cloudflare Access is the natural fit here, given the tunnel is already in place. Create it against `editor_host` in the Zero Trust dashboard or with `cloudflare_zero_trust_access_application` in a separate configuration: it is account-scoped identity configuration with its own lifecycle, not something a workload module should create and destroy alongside a deployment.

Where identity is more than you need, an IP allowlist works through the tunnel provided the controller settings above are in place:

```hcl
editor_ingress_extra_annotations = {
  "nginx.ingress.kubernetes.io/whitelist-source-range" = "203.0.113.7/32,192.168.1.0/24"
}
```

## Teardown

```bash
terraform destroy
```

Both `Ingress` objects and both DNS records go with it. The tunnel does not.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_cloudflare"></a> [cloudflare](#requirement\_cloudflare) | >= 4.0, < 4.52.7 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.12 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_cloudflare"></a> [cloudflare](#provider\_cloudflare) | >= 4.0, < 4.52.7 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [cloudflare_record.n8n](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/record) | resource |
| [kubernetes_ingress_v1.editor](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.webhook](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_namespace.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_persistent_volume_claim_v1.shared](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cloudflare_api_token"></a> [cloudflare\_api\_token](#input\_cloudflare\_api\_token) | Cloudflare API token with Zone:DNS:Edit on cloudflare\_zone\_id. Only read when cloudflare\_zone\_id is set. Prefer the CLOUDFLARE\_API\_TOKEN environment variable over putting it in terraform.tfvars. | `string` | `null` | no |
| <a name="input_cloudflare_tunnel_id"></a> [cloudflare\_tunnel\_id](#input\_cloudflare\_tunnel\_id) | UUID of the Cloudflare Tunnel that fronts the cluster's ingress controller. Each DNS record created when cloudflare\_zone\_id is set is a proxied CNAME to <this>.cfargotunnel.com. The tunnel itself is not managed by this example: it is long-lived cluster infrastructure serving every other hostname too, so a terraform destroy here must not be able to take it down. | `string` | `null` | no |
| <a name="input_cloudflare_zone_id"></a> [cloudflare\_zone\_id](#input\_cloudflare\_zone\_id) | Cloudflare zone ID for the zone both hostnames sit under. Leave null (the default) to manage DNS yourself, in which case the example creates no records. Set it and the example creates one proxied CNAME per hostname pointing at the Cloudflare Tunnel named by cloudflare\_tunnel\_id. The API token needs Zone:DNS:Edit on this zone. | `string` | `null` | no |
| <a name="input_cluster_issuer"></a> [cluster\_issuer](#input\_cluster\_issuer) | cert-manager ClusterIssuer that signs both Ingress certificates. Must already exist in the cluster - this example does not install cert-manager. Each hostname gets its own Certificate, so an issuer scoped to a single DNS zone needs both names inside it. | `string` | `"letsencrypt-prod"` | no |
| <a name="input_editor_host"></a> [editor\_host](#input\_editor\_host) | Hostname serving the editor UI, the REST API and test webhooks. This is n8n's canonical hostname (N8N\_HOST). Put your authentication policy in front of this name, Cloudflare Access, an OIDC proxy, an IP allowlist, none of which breaks webhook delivery, because production webhooks are advertised on webhook\_host instead. | `string` | `"n8n.example.com"` | no |
| <a name="input_editor_ingress_extra_annotations"></a> [editor\_ingress\_extra\_annotations](#input\_editor\_ingress\_extra\_annotations) | Annotations added to the editor Ingress only, on top of ingress\_extra\_annotations. Where an IP allowlist goes when the editor has no identity-aware proxy in front of it: {"nginx.ingress.kubernetes.io/whitelist-source-range" = "192.168.1.0/24"}. An allowlist works behind a tunnel or CDN as well as on a direct path, but only if the controller derives the client address from X-Forwarded-For: on ingress-nginx that means use-forwarded-headers and compute-full-forwarded-for. Without them nginx compares against the tunnel's own source address, which is identical for every request, so the rule admits everyone or no one. Set proxy\_hops to match the same chain. | `map(string)` | `{}` | no |
| <a name="input_ingress_class_name"></a> [ingress\_class\_name](#input\_ingress\_class\_name) | IngressClass both Ingresses are created with. The cluster must already run a controller for it. | `string` | `"nginx"` | no |
| <a name="input_ingress_extra_annotations"></a> [ingress\_extra\_annotations](#input\_ingress\_extra\_annotations) | Annotations added to both Ingresses. Merged over this example's own (cert-manager issuer, body size, proxy timeouts), so a key set here wins. | `map(string)` | `{}` | no |
| <a name="input_keda_installed"></a> [keda\_installed](#input\_keda\_installed) | Set true when the KEDA operator is already installed cluster-wide. Workers then scale on Redis queue depth rather than CPU. Leave false if unsure: a ScaledObject with no operator behind it never reconciles and workers stay at their minimum replica count without anything failing. | `bool` | `false` | no |
| <a name="input_kubeconfig_path"></a> [kubeconfig\_path](#input\_kubeconfig\_path) | Path to kubeconfig used by the kubernetes, helm and kubectl providers. | `string` | `"~/.kube/config"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace to deploy into. Created by this example on every path rather than by the module, so that turning shared storage on later cannot move it between two resource addresses. An existing deployment upgrading to this needs one terraform state mv first, or the next apply plans to destroy the namespace; both commands are in storage.tf. | `string` | `"n8n"` | no |
| <a name="input_proxy_hops"></a> [proxy\_hops](#input\_proxy\_hops) | How many proxies append to X-Forwarded-For between the client and an n8n pod (N8N\_PROXY\_HOPS). Defaults to 2 here, where ../homelab-split-ingress defaults to 1: that topology has ingress-nginx alone, this one puts the Cloudflare edge in front of it. Raise it again for anything further out, a WAF or a second reverse proxy. A wrong count is as bad as none: too low and n8n reads a proxy address as the client, too high and it reads a value the client could have forged. Every rate limit, audit log line and IP-based restriction depends on it, and nothing errors when it is wrong. | `number` | `2` | no |
| <a name="input_shared_mount_path"></a> [shared\_mount\_path](#input\_shared\_mount\_path) | Where the shared volume is mounted in the n8n container on all three pod types. Binary data goes to `shared_mount_path`/storage. Kept out of /home/node/.n8n deliberately: the chart already mounts its own data volume there on main, and nesting one mount inside another is a way to lose track of which pod sees what. | `string` | `"/opt/n8n-shared"` | no |
| <a name="input_shared_storage_class"></a> [shared\_storage\_class](#input\_shared\_storage\_class) | An RWX-capable StorageClass for the volume shared across the main, worker and webhook-processor pods (NFS, SMB, CephFS, or whatever the cluster offers). Leave null and no claim is created, in which case binary data stays in Postgres, which is n8n's default in queue mode and is fine until payloads get large. Set it and binary data moves to the shared volume instead. Check the class can actually reclaim before trusting it: with the NFS CSI driver against an NFSv3-only appliance the PV is deleted while every byte stays on the server, which reads as automatic cleanup and is not. | `string` | `null` | no |
| <a name="input_shared_storage_size"></a> [shared\_storage\_size](#input\_shared\_storage\_size) | Size of the shared RWX claim. Only used when shared\_storage\_class is set. Binary data from every execution lands here, so size it against retention rather than against one workflow. | `string` | `"20Gi"` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass for the CNPG and Valkey PVCs. Empty uses whatever the cluster's default StorageClass is. | `string` | `""` | no |
| <a name="input_timezone"></a> [timezone](#input\_timezone) | Timezone n8n schedules Cron triggers in (GENERIC\_TIMEZONE). | `string` | `"UTC"` | no |
| <a name="input_webhook_host"></a> [webhook\_host](#input\_webhook\_host) | Hostname serving production webhooks, forms, waiting webhooks and MCP. Passed to the module as n8n\_webhook\_url, so it is what n8n hands out in every generated webhook URL. Also routes /rest/projects to the main pods, which n8n's Agents chat integrations require because they build their OAuth callbacks and platform webhooks onto this hostname; see the example README. Nothing else is routed on this name: a request to any other path gets the ingress controller's 404. | `string` | `"hooks.example.com"` | no |
| <a name="input_webhook_ingress_extra_annotations"></a> [webhook\_ingress\_extra\_annotations](#input\_webhook\_ingress\_extra\_annotations) | Annotations added to the webhook Ingress only, on top of ingress\_extra\_annotations. Rate limiting belongs here if the controller is doing it rather than an upstream WAF: {"nginx.ingress.kubernetes.io/limit-rps" = "20"}. This is the hostname exposed to unauthenticated callers, so it is the one worth bounding. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_backing_services"></a> [backing\_services](#output\_backing\_services) | Which backend provides Postgres and Redis for this deployment, and the in-cluster endpoints for each. |
| <a name="output_dns_records"></a> [dns\_records](#output\_dns\_records) | Hostnames this example created proxied CNAMEs for. Empty when cloudflare\_zone\_id is null, in which case both names are yours to publish. |
| <a name="output_editor_url"></a> [editor\_url](#output\_editor\_url) | URL for the n8n editor UI and REST API. Put your authentication policy in front of this hostname. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that points kubectl at the cluster this example deployed to. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | Editor URL under the name tests/scripts/smoke-test.sh reads. Points at editor\_host: the smoke test checks the editor's health endpoint, which the webhook hostname deliberately does not serve. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace the n8n release and its backing services were deployed into. |
| <a name="output_oauth_callback_url"></a> [oauth\_callback\_url](#output\_oauth\_callback\_url) | Redirect URI to register with any OAuth2 provider a credential will use. It sits on editor\_host, never on webhook\_host: n8n builds this one from N8N\_EDITOR\_BASE\_URL, which is the editor hostname. The webhook Ingress does route /rest/projects, but for the Agents chat integrations, which is a different flow. Read it from the module rather than building it here, so the value stays whatever n8n was actually configured with. |
| <a name="output_webhook_base_url"></a> [webhook\_base\_url](#output\_webhook\_base\_url) | Public base URL for webhooks, forms, waiting webhooks and MCP. This is what n8n hands out in generated webhook URLs (passed to the module as n8n\_webhook\_url). |
| <a name="output_webhook_path_prefixes"></a> [webhook\_path\_prefixes](#output\_webhook\_path\_prefixes) | Path prefixes routed to the webhook processors on both hostnames. Read from the module rather than hardcoded, so the Ingresses cannot drift as n8n adds endpoints. |
<!-- END_TF_DOCS -->
