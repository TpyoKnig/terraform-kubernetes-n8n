# examples/homelab-godaddy

[`../homelab`](../homelab) plus one worked DNS strategy: an A record in a GoDaddy zone pointing at your ingress controller.

The base example stays DNS-neutral, and each DNS strategy gets its own runnable root. This is *a* worked answer, not the assumed one: a self-hosted cluster reaches the internet in as many ways as there are clusters.

## When this is the right example

You already run a public, routable ingress controller, a cloud LoadBalancer, a VPS, a port-forwarded static address, and GoDaddy holds the zone. The record simply names that address.

**When it is the wrong one:** if your ingress sits on a private address, a public A record for it resolves fine and then goes nowhere. That is the case [`../homelab-cloudflare`](../homelab-cloudflare) exists for: a tunnel gives you a public hostname without a routable address. If you have split-horizon DNS, a reverse proxy, or an overlay network, use [`../homelab`](../homelab) and create the record however that setup wants; nothing else changes.

## What this adds over `../homelab`

One `godaddy-dns_record`, and the provider to create it. Everything else, CloudNativePG, Valkey, the Ingress, autoscaling, is identical.

The record is **off unless `godaddy_domain` is set**, so this root still applies into a cluster whose DNS you manage elsewhere. `godaddy_domain` without `ingress_ip` is rejected at plan time rather than applied as a broken record.

## Prerequisites

Everything [`../homelab`](../homelab#prerequisites) needs, plus:

- **A GoDaddy API key and secret** from [developer.godaddy.com/keys](https://developer.godaddy.com/keys). Create a **production** key, not an OTE one - OTE keys authenticate against a sandbox and silently fail to touch your real zone.
- **The domain already in your GoDaddy account.** This example creates a record in an existing zone; it does not register or transfer anything.
- **A routable address for your ingress controller** - `kubectl get svc -n ingress-nginx`.

## Apply

```bash
export GODADDY_API_KEY="..."
export GODADDY_API_SECRET="..."

cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform apply
```

Prefer the environment variables over `terraform.tfvars`: the values are credentials for your whole domain, not just this record.

## Notes

**`godaddy_record_name` is relative to the domain.** `"n8n"` in a `example.com` zone creates `n8n.example.com`, which must match `ui_host`. `"@"` is the apex. Getting these out of step produces a deployment that resolves nothing useful and no error anywhere.

**TTL has a floor.** GoDaddy rejects anything under 600 seconds on most plans, so that is both the default and the validated minimum.

**There is no proxy in front of you.** Unlike the Cloudflare tunnel example, this record points straight at your ingress controller, so its configuration is the entire security boundary: there is no edge to absorb a scan or terminate TLS on your behalf. Consider an IP allowlist on the editor hostname, or the split-hostname topology in [`../homelab-split-ingress`](../homelab-split-ingress).

**TLS is still cert-manager's job**, and with GoDaddy it needs a decision before `cluster_issuer` works: see "Requirements for a trusted certificate" below.

## Requirements for a trusted certificate

The `ClusterIssuer` named by `cluster_issuer` must already exist (see [`../homelab`](../homelab#prerequisites)), and it must be able to solve a challenge for the zone `godaddy_domain` sits in. That is not automatic. cert-manager ships no built-in GoDaddy DNS-01 solver, so an issuer whose solvers only cover some other zone leaves the `Order` pending forever with an event like `no configured challenge solvers can be used`. Three ways to a trusted certificate:

1. **HTTP-01**, if `ingress_ip` is publicly routable and `ui_host` resolves to it from the internet. A record pointing at an RFC 1918 address cannot complete HTTP-01.
2. **A cert-manager DNS-01 webhook solver for GoDaddy.** Community webhooks exist (search for `cert-manager-webhook-godaddy`). Installing one adds a cluster-wide `APIService` and RBAC, and this module's tests do not exercise it.
3. **CNAME delegation of `_acme-challenge.<godaddy_record_name>` to a zone cert-manager can already solve.** Validation then happens against the other zone's TXT record while the certificate still names your GoDaddy host. GoDaddy needs no DNS-01 capability at all. This is the path validated live against a GoDaddy domain with a real Let's Encrypt certificate, below.

### Recipe: CNAME delegation

Three pieces, all outside Terraform and caller-owned like the rest of the cert-manager setup.

**1. One extra GoDaddy record**, alongside the `A` record this example creates: a CNAME from `_acme-challenge.<godaddy_record_name>` to `_acme-challenge.<godaddy_record_name>.<other-zone>`, TTL 600. If `godaddy_record_name` is the apex `"@"`, the challenge owner is just `_acme-challenge` (not `_acme-challenge.@`): substitute accordingly in both the record name and the target below.

```bash
curl -X PUT \
  -H "Authorization: sso-key $GODADDY_API_KEY:$GODADDY_API_SECRET" \
  -H "Content-Type: application/json" \
  "https://api.godaddy.com/v1/domains/<godaddy_domain>/records/CNAME/_acme-challenge.<godaddy_record_name>" \
  -d '[{"data":"_acme-challenge.<godaddy_record_name>.<other-zone>","ttl":600}]'
```

**2. An issuer** whose solver selects your GoDaddy zone with `dnsZones` and sets `cnameStrategy: Follow`. Use a `ClusterIssuer`, or a namespaced `Issuer` if your RBAC does not allow cluster-scoped objects:

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer            # or ClusterIssuer
metadata:
  name: <issuer-name>
  namespace: <namespace>  # omit for a ClusterIssuer
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: <you@example.com>
    privateKeySecretRef:
      name: <issuer-name>-account-key
    solvers:
      - selector:
          dnsZones:
            - <godaddy_domain>
        dns01:
          cnameStrategy: Follow
          cloudflare:           # whichever provider backs <other-zone>
            apiTokenSecretRef:
              name: <dns-provider-token-secret>
              key: api-token
```

**3. With a namespaced `Issuer` only:** set `cluster_issuer = ""` so the example adds no `cert-manager.io/cluster-issuer` annotation, and create the `Certificate` yourself, naming the TLS secret the rendered Ingress expects (`kubectl get ingress <release>-main -o jsonpath='{.spec.tls[0].secretName}'`):

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: <cert-name>
  namespace: <namespace>
spec:
  secretName: <secret-name-from-the-rendered-ingress>
  issuerRef:
    kind: Issuer
    name: <issuer-name>
  dnsNames:
    - <ui_host>
```

With a `ClusterIssuer`, skip step 3: set `cluster_issuer` to its name and cert-manager creates the `Certificate` from the Ingress annotation.

Validated live: the certificate was issued by Let's Encrypt production roughly 78 seconds after the challenge was presented, and `curl` verified it without `-k`. If a `Certificate` stays `Ready: False` for much longer, `kubectl describe challenge -n <namespace>` names the blocker, usually a CNAME that has not propagated or a solver token without write access to the target zone.

## Shared storage across the pods

Identical to [`../homelab`](../homelab#shared-storage-across-the-pods), including the inputs and the two settings that make it take effect. Set `shared_storage_class` to an RWX-capable class and this example creates a claim and mounts it into the main, worker and webhook-processor pods; leave it null and binary data stays in Postgres. Read that section rather than a copy of it here, so the two cannot drift.

## Reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_godaddy-dns"></a> [godaddy-dns](#requirement\_godaddy-dns) | ~> 0.3 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.14 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_godaddy-dns"></a> [godaddy-dns](#provider\_godaddy-dns) | ~> 0.3 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 3.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| godaddy-dns_record.n8n | resource |
| [kubernetes_namespace.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_persistent_volume_claim_v1.shared](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cluster_issuer"></a> [cluster\_issuer](#input\_cluster\_issuer) | cert-manager ClusterIssuer to use for the ingress TLS cert. | `string` | `"letsencrypt-prod"` | no |
| <a name="input_godaddy_api_key"></a> [godaddy\_api\_key](#input\_godaddy\_api\_key) | GoDaddy API key. Only read when godaddy\_domain is set. Prefer the GODADDY\_API\_KEY environment variable over terraform.tfvars. | `string` | `null` | no |
| <a name="input_godaddy_api_secret"></a> [godaddy\_api\_secret](#input\_godaddy\_api\_secret) | GoDaddy API secret. Only read when godaddy\_domain is set. Prefer the GODADDY\_API\_SECRET environment variable over terraform.tfvars. | `string` | `null` | no |
| <a name="input_godaddy_domain"></a> [godaddy\_domain](#input\_godaddy\_domain) | GoDaddy domain (the zone apex, e.g. example.com) that ui\_host sits under. Leave null (the default) to manage DNS yourself, the example creates no record then. Set it and the example creates an A record pointing godaddy\_record\_name at ingress\_ip. | `string` | `null` | no |
| <a name="input_godaddy_record_name"></a> [godaddy\_record\_name](#input\_godaddy\_record\_name) | Record name relative to godaddy\_domain. "@" is the apex; "n8n" creates n8n.example.com. Must correspond to ui\_host: the module advertises ui\_host, so a record at a different name resolves nothing useful. | `string` | `"n8n"` | no |
| <a name="input_godaddy_record_ttl"></a> [godaddy\_record\_ttl](#input\_godaddy\_record\_ttl) | TTL in seconds for the A record. GoDaddy enforces a 600-second minimum on most plans and rejects anything lower. | `number` | `600` | no |
| <a name="input_ingress_ip"></a> [ingress\_ip](#input\_ingress\_ip) | Address the A record points at: the external address of your ingress controller, not of any n8n pod. Required when godaddy\_domain is set. This must be reachable from wherever the record is resolved: a public record pointing at an RFC 1918 address resolves fine and then goes nowhere. | `string` | `null` | no |
| <a name="input_keda_installed"></a> [keda\_installed](#input\_keda\_installed) | Set true when the KEDA operator is already installed cluster-wide. Workers then scale on Redis queue depth rather than CPU, and the chart's CPU worker HPA is disabled so the two never both own the worker Deployment. Leave false if you are unsure: a ScaledObject with no operator behind it never reconciles and workers stay at their minimum replica count without anything failing. | `bool` | `false` | no |
| <a name="input_kubeconfig_path"></a> [kubeconfig\_path](#input\_kubeconfig\_path) | Path to kubeconfig used by the kubernetes, helm and kubectl providers (the kubectl one applies the CNPG Cluster CR). | `string` | `"~/.kube/config"` | no |
| <a name="input_metrics_lan_ip"></a> [metrics\_lan\_ip](#input\_metrics\_lan\_ip) | Address to publish the n8n main pod's /metrics endpoint on, for a Prometheus that runs outside the cluster and so cannot use in-cluster service discovery. Same allocator requirement as postgres\_lan\_ip. Leave null (the default) and no LoadBalancer Service is created; an in-cluster Prometheus or Alloy does not need this. | `string` | `null` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace to deploy into. Created by this example on every path rather than by the module, so that turning shared storage on later cannot move it between two resource addresses. An existing deployment upgrading to this needs one terraform state mv first, or the next apply plans to destroy the namespace; both commands are in storage.tf. | `string` | `"n8n"` | no |
| <a name="input_otel_endpoint"></a> [otel\_endpoint](#input\_otel\_endpoint) | Base URL of an OTLP HTTP collector to export traces to, e.g. http://otel-collector.observability.svc.cluster.local:4318 for a Grafana Alloy in the cluster. Point at the base URL, not the traces path: n8n appends /v1/traces itself. Defaults to this lab's own collector, matching what this example has always exported to; set it to a different collector or to null (tracing off entirely) to change that. The collector is yours to run; this example installs none and nothing verifies one is listening, so a wrong address means traces are exported into the void with no error anywhere. Metrics are unaffected either way: /metrics is scraped rather than pushed, so it needs no collector. | `string` | `"http://alloy-otlp.monitoring.svc.cluster.local:4318"` | no |
| <a name="input_postgres_lan_ip"></a> [postgres\_lan\_ip](#input\_postgres\_lan\_ip) | Address to publish the CNPG rw endpoint on, for LAN clients that are not in the cluster - a Grafana instance querying n8n's execution tables, a DB client. Rendered as an io.cilium/lb-ipam-ips annotation, so it pins the address on Cilium LB-IPAM only; other allocators (MetalLB, kube-vip) ignore that key and will allocate an arbitrary address instead. To pin on those, call the module directly and use cnpg\_lan\_expose.annotations / metrics\_lan\_expose.annotations with the key your allocator honours. Leave null (the default) and no LoadBalancer Service is created. Postgres is exposed without a proxy in front of it, so only set this on a network you trust. | `string` | `null` | no |
| <a name="input_shared_mount_path"></a> [shared\_mount\_path](#input\_shared\_mount\_path) | Where the shared volume is mounted in the n8n container on all three pod types. Binary data goes to `shared_mount_path`/storage. Kept out of /home/node/.n8n deliberately: the chart already mounts its own data volume there on main, and nesting one mount inside another is a way to lose track of which pod sees what. Note the task-runner sidecar does not get this mount; n8n\_extra\_volume\_mounts reaches the n8n container only. | `string` | `"/opt/n8n-shared"` | no |
| <a name="input_shared_storage_class"></a> [shared\_storage\_class](#input\_shared\_storage\_class) | An RWX-capable StorageClass for a volume shared across the main, worker and webhook-processor pods (Longhorn RWX, NFS, SMB, CephFS, or whatever the cluster offers). Longhorn does serve ReadWriteMany, through a share-manager pod that exports the volume over NFSv4, so every node that may run an n8n pod needs an NFSv4 client installed first: on Talos that is a system extension, not something present by default, and without it the volume never mounts. The module does not wait for the claim, so the symptom is pods stuck pending a mount rather than anything naming storage. Leave null and no claim is created, in which case binary data stays in Postgres, which is n8n's default in queue mode. Set it and binary data moves to the shared volume instead. Check the class can actually reclaim before trusting it: with the NFS CSI driver against an NFSv3-only appliance the PV is deleted while every byte stays on the server, which reads as automatic cleanup and is not. | `string` | `null` | no |
| <a name="input_shared_storage_size"></a> [shared\_storage\_size](#input\_shared\_storage\_size) | Size of the shared RWX claim. Only used when shared\_storage\_class is set. Binary data from every execution lands here, so size it against retention rather than against one workflow. | `string` | `"20Gi"` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass for the CNPG and Valkey PVCs. Empty uses whatever the cluster's default StorageClass is. | `string` | `""` | no |
| <a name="input_ui_host"></a> [ui\_host](#input\_ui\_host) | Hostname served by ingress. This example creates an A record for it when godaddy\_domain is set. Leave that null and this example behaves exactly like examples/homelab: the record is yours. | `string` | `"n8n.example.com"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_backing_services"></a> [backing\_services](#output\_backing\_services) | Which backend provides Postgres and Redis for this deployment, and the in-cluster endpoints for each. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that points kubectl at the cluster this example deployed to. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once the ingress controller has published the host. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace the n8n release and its backing services were deployed into. |
<!-- END_TF_DOCS -->
