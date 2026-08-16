# Homelab split-ingress example

Two hostnames instead of one, on the same Kubernetes-native backend as [`../homelab`](../homelab): the editor on one, production webhooks on the other. Routing belongs to this example (`create_ingress = false`), so it renders both `Ingress` objects itself and points them at the Services the module builds.

```
editor_host   →  n8n-main                editor UI, REST API, /webhook-test
webhook_host  →  n8n-webhook-processor   /webhook, /webhook-waiting, /form,
                                         /form-waiting, /mcp
              →  n8n-main                /rest/projects (Agents chat
                                         integrations)
```

**No license required.** Splitting webhook processors off the main process is queue-mode behaviour, and n8n ships queue mode in the Community edition. See [compare editions](https://docs.n8n.io/deploy/host-n8n/community-edition-features), which lists queue mode among what is included.

## Why split at all

Not for load. Both hostnames land on the same ingress controller, and the webhook processors are already separate pods in `../homelab`: that part is the module's queue-mode wiring, not the ingress.

The split buys **one authentication boundary you can actually use**. n8n's own SSO is a licensed feature and this module deploys the Community edition, so the identity boundary has to sit in front of n8n rather than inside it: and it cannot cover the whole deployment, because webhook senders are machines that cannot complete an interactive login. With two hostnames you can put Cloudflare Access (or an OIDC proxy, or an IP allowlist) in front of `editor_host` while `webhook_host` stays open. `webhook_host` serves the webhook prefixes plus `/rest/projects`, and nothing else: everything not routed gets the controller's 404, so an unauthenticated caller reaching it cannot get to the editor or to `/rest/login`. `/rest/projects` is there because n8n's Agents chat integrations build their OAuth callbacks and platform webhooks onto the webhook hostname; see [Why the webhook host also routes /rest/projects](#why-the-webhook-host-also-routes-restprojects).

The secondary benefit is that rate limiting, WAF rules and request-size limits can be applied to the untrusted hostname alone, where they belong.

## What it creates

Everything [`../homelab`](../homelab) creates, minus the module's own `Ingress` pair, plus:

- `Ingress/n8n-webhook` - `webhook_host`, the five webhook path prefixes plus `/rest/projects`, no catch-all
- `Ingress/n8n-editor` - `editor_host`, `/` to the mains, with the same webhook prefixes routed to the webhook processors ahead of it

The webhook prefixes come from the module's `n8n_webhook_path_prefixes` output rather than being hardcoded, so neither `Ingress` drifts as n8n adds endpoint families.

## Why the editor host also routes the webhook prefixes

The module runs the chart with `disableProductionWebhooksOnMainProcess = true`, so the main pods serve none of those five prefixes. Without those rules on the editor `Ingress`, the catch-all hands `/webhook/...` to a main pod, the request falls through to the editor's SPA handler, and the caller gets **HTTP 200 with an HTML body**: a delivery that reads as success while nothing executed.

`/webhook-test` is deliberately *not* in that list: manual "listen for test event" executions run on the mains, so it stays on the catch-all.

## Why the webhook host also routes /rest/projects

n8n's Agents chat integrations build the Slack app-install URL and the platform event callbacks by appending `/rest/projects/<id>/agents/...` onto `getWebhookBaseUrl()`, which is `WEBHOOK_URL`, which is `webhook_host`. Those are main-pod routes, so without the rule, connecting a Slack agent returns **404 at the end of the OAuth flow**, after the user has already granted consent, and nothing in n8n logs it.

This is upstream n8n's construction and unrelated to `N8N_EDITOR_BASE_URL`, so no module configuration avoids it. The path has to be routed for those OAuth flows to complete at all.

It is scoped to `/rest/projects` rather than all of `/rest`, because that is the entire surface those three constructions use. `/rest/login`, `/rest/credentials` and the rest of the REST API stay off this hostname. It is a literal prefix, so it needs no regex and no controller-specific annotation, and it works the same on any ingress controller.

It does have to be reachable from the internet rather than only from inside the cluster: the OAuth callback is a redirect the admin's browser follows, and the platform webhooks are server-to-server POSTs from Slack and Telegram. Telegram inspects this base URL and silently drops to polling mode if it is not a public `https://` name.

If you do not use Agents chat integrations, deleting the `/rest/projects` block in `ingress.tf` restores the smaller surface. The OAuth2 *credential* callback is unaffected either way: that one lives on `editor_host`, built from `N8N_EDITOR_BASE_URL`, and is exposed as the `oauth_callback_url` output.

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

Where identity is more than you need, an IP allowlist is enough:

```hcl
editor_ingress_extra_annotations = {
  "nginx.ingress.kubernetes.io/whitelist-source-range" = "203.0.113.7/32,192.168.1.0/24"
}
```

This works behind a tunnel or CDN as well as on a direct LAN path, but only if the controller derives the client address from `X-Forwarded-For`. On ingress-nginx that is two settings:

```yaml
controller:
  config:
    use-forwarded-headers: "true"
    compute-full-forwarded-for: "true"
```

Without them nginx compares the allowlist against the tunnel's own source address, which is the same for every request, so the rule admits everyone or no one. With them it sees the real client and the allowlist behaves as written. Set `proxy_hops` to match the same chain, since n8n counts it independently of nginx.

## Fronting this with a tunnel or CDN

Three things bite here, and none of them are visible from a `terraform apply` that succeeds.

**Count the hops again.** `proxy_hops` defaults to `1`, which is ingress-nginx alone. A Cloudflare Tunnel, a CDN, a WAF or an outer reverse proxy each add one, so the common Cloudflare case is `2`. Too low and n8n treats a proxy address as the client; too high and it trusts a value the client could have forged. Nothing errors either way.

**Check what your provider's certificate actually covers.** Cloudflare's Universal SSL covers `example.com` and `*.example.com`, one label only. A webhook host at `hooks.n8n.example.com` is two labels deep and fails TLS at the edge unless Advanced Certificate Manager is on. Either keep both hostnames single-level (`n8n.example.com` and `n8n-hooks.example.com`) or budget for the certificate. cert-manager will happily issue for the deeper name, which makes this look fine in-cluster right up until you test from outside.

**A hostname can be silently refused.** Providers run brand and abuse filters on DNS names. A record can be accepted by the API, return success, and never publish to the authoritative nameservers. If a new hostname does not resolve, query the zone's authoritative NS directly and compare against a throwaway name created at the same moment: if the throwaway publishes and yours does not, the name is filtered and no amount of waiting fixes it. Pick another.

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

## Shared storage across the pods

Queue mode runs main, worker and webhook-processor pods, and they do not share a filesystem. The chart mounts its own `data` volume on main only, and this module leaves persistence at the chart default, so that volume is an `emptyDir`.

That matters as soon as a workflow moves a file: a webhook arrives on one pod, the execution runs on a worker, and the editor renders the result on a third. Anything written to local disk by one is invisible to the other two.

Set `shared_storage_class` to an RWX-capable class and this example creates a claim and mounts it into all three:

```hcl
shared_storage_class = "nfs-csi"    # or smb, cephfs, whatever the cluster offers
shared_storage_size  = "20Gi"
```

**Two settings make it take effect, and the second is the one people miss.** n8n defaults binary data to `filesystem` in regular mode but to `database` in scaling mode, and this module always runs queue mode. Mount the volume without `N8N_DEFAULT_BINARY_DATA_MODE=filesystem` and every payload still goes to Postgres: the mount is there, empty, and nothing reports a problem. The example sets both.

Leave `shared_storage_class` null and no claim is created, binary data stays in Postgres, and this still applies on a cluster with no RWX class. That is fine until payloads get large.

Two consequences worth knowing:

- **The namespace moves from the module to this example** when a claim exists, because the claim has to be created before the Helm release. A pod referencing a missing PVC stays `Pending` and the release never goes ready. `create_namespace = false` exists for this.
- **`terraform destroy` takes the claim** along with the namespace. If the data matters, set the class's `reclaimPolicy` to `Retain` or keep the claim in a separate configuration.

**Check the class can actually reclaim before trusting it.** With the NFS CSI driver the controller mounts the share itself to remove a released PVC's directory, and where that mount fails, an appliance serving only NFSv3 being the common case, the PV is deleted while every byte stays on the server. It reads as automatic cleanup and is not. Create a throwaway PVC against the class, delete it, and look at the server.

The task-runner sidecar does not get the mount: `n8n_extra_volume_mounts` reaches the n8n container only.

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
| [kubernetes_namespace.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_persistent_volume_claim_v1.shared](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cluster_issuer"></a> [cluster\_issuer](#input\_cluster\_issuer) | cert-manager ClusterIssuer that signs both Ingress certificates. Must already exist in the cluster - this example does not install cert-manager. Each hostname gets its own Certificate, so an issuer scoped to a single DNS zone needs both names inside it. | `string` | `"letsencrypt-prod"` | no |
| <a name="input_editor_host"></a> [editor\_host](#input\_editor\_host) | Hostname serving the editor UI, the REST API and test webhooks. This is n8n's canonical hostname (N8N\_HOST). Put your authentication policy in front of this name, Cloudflare Access, an OIDC proxy, an IP allowlist, none of which breaks webhook delivery, because production webhooks are advertised on webhook\_host instead. | `string` | `"n8n.example.com"` | no |
| <a name="input_editor_ingress_extra_annotations"></a> [editor\_ingress\_extra\_annotations](#input\_editor\_ingress\_extra\_annotations) | Annotations added to the editor Ingress only, on top of ingress\_extra\_annotations. Where an IP allowlist goes when the editor has no identity-aware proxy in front of it: {"nginx.ingress.kubernetes.io/whitelist-source-range" = "192.168.1.0/24"}. An allowlist works behind a tunnel or CDN as well as on a direct path, but only if the controller derives the client address from X-Forwarded-For: on ingress-nginx that means use-forwarded-headers and compute-full-forwarded-for. Without them nginx compares against the tunnel's own source address, which is identical for every request, so the rule admits everyone or no one. Set proxy\_hops to match the same chain. | `map(string)` | `{}` | no |
| <a name="input_ingress_class_name"></a> [ingress\_class\_name](#input\_ingress\_class\_name) | IngressClass both Ingresses are created with. The cluster must already run a controller for it. | `string` | `"nginx"` | no |
| <a name="input_ingress_extra_annotations"></a> [ingress\_extra\_annotations](#input\_ingress\_extra\_annotations) | Annotations added to both Ingresses. Merged over this example's own (cert-manager issuer, body size, proxy timeouts), so a key set here wins. | `map(string)` | `{}` | no |
| <a name="input_keda_installed"></a> [keda\_installed](#input\_keda\_installed) | Set true when the KEDA operator is already installed cluster-wide. Workers then scale on Redis queue depth rather than CPU. Leave false if unsure: a ScaledObject with no operator behind it never reconciles and workers stay at their minimum replica count without anything failing. | `bool` | `false` | no |
| <a name="input_kubeconfig_path"></a> [kubeconfig\_path](#input\_kubeconfig\_path) | Path to kubeconfig used by the kubernetes, helm and kubectl providers. | `string` | `"~/.kube/config"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace to deploy into. Created by the module by default, or by this example when shared\_storage\_class is set, because the shared claim has to exist before the Helm release. | `string` | `"n8n"` | no |
| <a name="input_proxy_hops"></a> [proxy\_hops](#input\_proxy\_hops) | How many proxies append to X-Forwarded-For between the client and an n8n pod (N8N\_PROXY\_HOPS). The default of 1 counts ingress-nginx alone, which is what this example assumes and what the module itself uses when it owns the Ingress. Count your own chain and raise it: a Cloudflare Tunnel, a CDN, a WAF or an outer reverse proxy each add one, so fronting this example with Cloudflare makes it 2. A wrong count is as bad as none: too low and n8n reads a proxy address as the client, too high and it reads a value the client could have forged. Every rate limit, audit log line and IP-based restriction depends on it. | `number` | `1` | no |
| <a name="input_shared_mount_path"></a> [shared\_mount\_path](#input\_shared\_mount\_path) | Where the shared volume is mounted in the n8n container on all three pod types. Binary data goes to `shared_mount_path`/storage. Kept out of /home/node/.n8n deliberately: the chart already mounts its own data volume there on main, and nesting one mount inside another is a way to lose track of which pod sees what. Note the task-runner sidecar does not get this mount; n8n\_extra\_volume\_mounts reaches the n8n container only. | `string` | `"/opt/n8n-shared"` | no |
| <a name="input_shared_storage_class"></a> [shared\_storage\_class](#input\_shared\_storage\_class) | An RWX-capable StorageClass for a volume shared across the main, worker and webhook-processor pods (NFS, SMB, CephFS, or whatever the cluster offers). Leave null and no claim is created, in which case binary data stays in Postgres, which is n8n's default in queue mode. Set it and binary data moves to the shared volume instead. Setting it also moves namespace creation from the module to this example, because the claim has to exist before the Helm release. Check the class can actually reclaim before trusting it: with the NFS CSI driver against an NFSv3-only appliance the PV is deleted while every byte stays on the server, which reads as automatic cleanup and is not. | `string` | `null` | no |
| <a name="input_shared_storage_size"></a> [shared\_storage\_size](#input\_shared\_storage\_size) | Size of the shared RWX claim. Only used when shared\_storage\_class is set. Binary data from every execution lands here, so size it against retention rather than against one workflow. | `string` | `"20Gi"` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass for the CNPG and Valkey PVCs. Empty uses whatever the cluster's default StorageClass is. | `string` | `""` | no |
| <a name="input_timezone"></a> [timezone](#input\_timezone) | Timezone n8n schedules Cron triggers in (GENERIC\_TIMEZONE). | `string` | `"UTC"` | no |
| <a name="input_webhook_host"></a> [webhook\_host](#input\_webhook\_host) | Hostname serving production webhooks, forms, waiting webhooks and MCP. Passed to the module as n8n\_webhook\_url, so it is what n8n hands out in every generated webhook URL. Also routes /rest/projects to the main pods, which n8n's Agents chat integrations require because they build their OAuth callbacks and platform webhooks onto this hostname; see the example README. Nothing else is routed on this name: a request to any other path gets the ingress controller's 404. | `string` | `"hooks.example.com"` | no |
| <a name="input_webhook_ingress_extra_annotations"></a> [webhook\_ingress\_extra\_annotations](#input\_webhook\_ingress\_extra\_annotations) | Annotations added to the webhook Ingress only, on top of ingress\_extra\_annotations. Rate limiting belongs here if the controller is doing it rather than an upstream WAF: {"nginx.ingress.kubernetes.io/limit-rps" = "20"}. This is the hostname exposed to unauthenticated callers, so it is the one worth bounding. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_backing_services"></a> [backing\_services](#output\_backing\_services) | Which backend provides Postgres and Redis for this deployment, and the in-cluster endpoints for each. |
| <a name="output_editor_url"></a> [editor\_url](#output\_editor\_url) | URL for the n8n editor UI and REST API. Put your authentication policy in front of this hostname. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that points kubectl at the cluster this example deployed to. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | Editor URL under the name tests/scripts/smoke-test.sh reads. Points at editor\_host: the smoke test checks the editor's health endpoint, which the webhook hostname deliberately does not serve. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace the n8n release and its backing services were deployed into. |
| <a name="output_oauth_callback_url"></a> [oauth\_callback\_url](#output\_oauth\_callback\_url) | Redirect URI to register with any OAuth2 provider a credential will use. It sits on editor\_host, never on webhook\_host: n8n builds this one from N8N\_EDITOR\_BASE\_URL, which is the editor hostname. The webhook Ingress does route /rest/projects, but for the Agents chat integrations, which is a different flow. Read it from the module rather than building it here, so the value stays whatever n8n was actually configured with. |
| <a name="output_webhook_base_url"></a> [webhook\_base\_url](#output\_webhook\_base\_url) | Public base URL for webhooks, forms, waiting webhooks and MCP. This is what n8n hands out in generated webhook URLs (passed to the module as n8n\_webhook\_url). |
| <a name="output_webhook_path_prefixes"></a> [webhook\_path\_prefixes](#output\_webhook\_path\_prefixes) | Path prefixes routed to the webhook processors on both hostnames. Read from the module rather than hardcoded, so the Ingresses cannot drift as n8n adds endpoints. |
<!-- END_TF_DOCS -->
