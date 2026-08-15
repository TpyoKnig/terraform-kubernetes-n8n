# Homelab + Cloudflare Tunnel example

[`../homelab`](../homelab) with the DNS record filled in. Identical module configuration; the only addition is `dns.tf`, which creates one **proxied CNAME** for `ui_host` pointing at a Cloudflare Tunnel that already fronts your cluster.

The base example stays DNS-neutral and each DNS strategy gets its own runnable root, so this is *a* worked answer rather than the assumed one: a self-hosted cluster reaches the internet in as many ways as there are clusters. [`../homelab-godaddy`](../homelab-godaddy) is the other one that ships.

## When this shape fits

You already run `cloudflared` in the cluster (or on a host that can reach ingress-nginx), and you want a public hostname without exposing an address. If instead you have a public LoadBalancer, split-horizon DNS on the LAN, a reverse proxy on a VPS, or Tailscale, use [`../homelab`](../homelab) and create the record however that setup wants: nothing else changes.

## Why a CNAME to the tunnel, not an A record

- **A homelab's ingress address is usually private.** Publishing `192.168.x.y` in public DNS is wrong even where it resolves. The tunnel already terminates at ingress-nginx, so the record only has to name it.
- **It must be proxied.** An unproxied CNAME to `<id>.cfargotunnel.com` does not resolve at all - that hostname only exists inside Cloudflare's edge.

## What is not managed here

**The tunnel itself.** It is long-lived cluster infrastructure serving every other hostname you run, so a `terraform destroy` of one n8n deployment must not be able to take it down. Create it once with `cloudflared tunnel create`, or in a separate configuration, and pass its UUID as `cloudflare_tunnel_id`.

The tunnel's own ingress rules are likewise yours: this example assumes the tunnel already routes to the ingress controller.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: ui_host, cloudflare_zone_id, cloudflare_tunnel_id

export CLOUDFLARE_API_TOKEN=...   # needs Zone:DNS:Edit on that zone

terraform init
terraform apply
```

The token is read from `CLOUDFLARE_API_TOKEN` in preference to `terraform.tfvars`, so it never lands in a file you might commit.

Leaving `cloudflare_zone_id` unset makes this example behave exactly like `../homelab`: no record is created and nothing else changes.

## Everything else

Prerequisites, what gets created, the backing-service choices, scaling, teardown and production considerations are all identical to [`../homelab`](../homelab). Read that README first; this one only covers the DNS layer.

For the two-hostname topology (editor and webhooks on separate names, so an identity policy can sit in front of the editor), see [`../homelab-split-ingress`](../homelab-split-ingress) and copy `dns.tf` from here: it needs one record per hostname.

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

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [cloudflare_record.n8n](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/record) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cloudflare_api_token"></a> [cloudflare\_api\_token](#input\_cloudflare\_api\_token) | Cloudflare API token with Zone:DNS:Edit on cloudflare\_zone\_id. Only read when cloudflare\_zone\_id is set. Prefer the CLOUDFLARE\_API\_TOKEN environment variable over putting it in terraform.tfvars. | `string` | `null` | no |
| <a name="input_cloudflare_tunnel_id"></a> [cloudflare\_tunnel\_id](#input\_cloudflare\_tunnel\_id) | UUID of the Cloudflare Tunnel that fronts the cluster's ingress controller. The DNS record created when cloudflare\_zone\_id is set is a proxied CNAME to <this>.cfargotunnel.com. The tunnel itself is not managed by this example: it is long-lived cluster infrastructure serving every other hostname too, so a terraform destroy here must not be able to take it down. | `string` | `null` | no |
| <a name="input_cloudflare_zone_id"></a> [cloudflare\_zone\_id](#input\_cloudflare\_zone\_id) | Cloudflare zone ID for the zone ui\_host sits under. Leave null (the default) to manage DNS yourself - the example creates no record then. Set it and the example creates a proxied CNAME for ui\_host pointing at the Cloudflare Tunnel named by cloudflare\_tunnel\_id. The API token needs Zone:DNS:Edit on this zone. | `string` | `null` | no |
| <a name="input_cluster_issuer"></a> [cluster\_issuer](#input\_cluster\_issuer) | cert-manager ClusterIssuer to use for the ingress TLS cert. | `string` | `"letsencrypt-prod"` | no |
| <a name="input_keda_installed"></a> [keda\_installed](#input\_keda\_installed) | Set true when the KEDA operator is already installed cluster-wide. Workers then scale on Redis queue depth rather than CPU, and the chart's CPU worker HPA is disabled so the two never both own the worker Deployment. Leave false if you are unsure: a ScaledObject with no operator behind it never reconciles and workers stay at their minimum replica count without anything failing. | `bool` | `false` | no |
| <a name="input_kubeconfig_path"></a> [kubeconfig\_path](#input\_kubeconfig\_path) | Path to kubeconfig used by the kubernetes + helm providers. | `string` | `"~/.kube/config"` | no |
| <a name="input_metrics_lan_ip"></a> [metrics\_lan\_ip](#input\_metrics\_lan\_ip) | Address to publish the n8n main pod's /metrics endpoint on, for a Prometheus that runs outside the cluster and so cannot use in-cluster service discovery. Same allocator requirement as postgres\_lan\_ip. Leave null (the default) and no LoadBalancer Service is created; an in-cluster Prometheus or Alloy does not need this. | `string` | `null` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace to deploy into. | `string` | `"n8n"` | no |
| <a name="input_postgres_lan_ip"></a> [postgres\_lan\_ip](#input\_postgres\_lan\_ip) | Address to publish the CNPG rw endpoint on, for LAN clients that are not in the cluster - a Grafana instance querying n8n's execution tables, a DB client. Rendered as an io.cilium/lb-ipam-ips annotation, so it pins the address on Cilium LB-IPAM only; other allocators (MetalLB, kube-vip) ignore that key and will allocate an arbitrary address instead. To pin on those, call the module directly and use cnpg\_lan\_expose.annotations / metrics\_lan\_expose.annotations with the key your allocator honours. Leave null (the default) and no LoadBalancer Service is created. Postgres is exposed without a proxy in front of it, so only set this on a network you trust. | `string` | `null` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass for the CNPG and Valkey PVCs. Empty uses whatever the cluster's default StorageClass is. | `string` | `""` | no |
| <a name="input_ui_host"></a> [ui\_host](#input\_ui\_host) | Hostname served by ingress. This example creates the DNS record for it, a proxied CNAME to the Cloudflare Tunnel named by cloudflare\_tunnel\_id, when cloudflare\_zone\_id is set. Leave that null and this example behaves exactly like examples/homelab: the record is yours. | `string` | `"n8n.example.com"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_backing_services"></a> [backing\_services](#output\_backing\_services) | Which backend provides Postgres and Redis for this deployment, and the in-cluster endpoints for each. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that points kubectl at the cluster this example deployed to. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once the ingress controller has published the host. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace the n8n release and its backing services were deployed into. |
<!-- END_TF_DOCS -->
