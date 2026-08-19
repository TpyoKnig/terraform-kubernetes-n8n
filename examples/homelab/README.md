# Homelab example

Deploys the module onto a cluster you already run, with CNPG for PostgreSQL, Valkey for the queue, and an ingress-nginx `Ingress`. These are the module's defaults, so this is the shortest complete configuration there is. Start here.

**Community edition, with no licence path.** One main pod, plus the worker and webhook-processor pools that queue mode brings: which is the reason to run this topology at all. Nothing here is lab-only, so what you tune on a small cluster carries over to a large one by changing values, not structure.

Full operational guide: [../../docs/operations.md](../../docs/operations.md).

## What it creates

- Namespace `n8n` (change via `namespace`)
- CNPG `Cluster/n8n-pg` - single-instance PostgreSQL on the cluster's default `StorageClass` (or set `storage_class`)
- Valkey (BSD-licensed Redis fork) via the `valkey-io/valkey-helm` chart - single standalone instance, auth on
- The n8n Helm release in queue mode, with worker and webhook-processor pools and their HPAs, an ingress-nginx `Ingress` for `ui_host`, TLS from the `cluster_issuer` `ClusterIssuer`, and filesystem binary storage
- Optional LAN-exposed `LoadBalancer` Services for the CNPG rw endpoint (Grafana / db-tool access) and the n8n `/metrics` endpoint (off-cluster Prometheus)

## The layers, and how to swap them

Every piece below is a slot. The defaults are what this lab runs: chosen because the research behind them did not turn up a better-supportable option, not because the module requires them. Each row is one input away from being something else.

| Layer | Default here | Why this default | Swap it |
|---|---|---|---|
| **PostgreSQL** | CloudNativePG, in-cluster (`postgres_backend = "cnpg"`) | The same packaging problem as Redis, one layer up: the obvious in-cluster Postgres was the Bitnami chart, and Bitnami's free Docker Hub catalog moved to `bitnamilegacy` and stopped being updated in August 2025. With the default chart gone, the choice is an operator or a hand-rolled `StatefulSet`, and Postgres is the piece with the most operational surface, failover, PITR, major-version upgrades, so an operator that owns all three wins. CNPG gives that via a `Cluster` CR the module renders directly, with PITR through `barmanObjectStore`. | `postgres_backend = "external"` + `db_host` / `db_password` (or `db_password_secret_ref`) for an existing Postgres anywhere. |
| **Redis** | Valkey, in-cluster (`redis_backend = "valkey"`) | Redis stopped being open source at 7.4 - Redis Ltd relicensed to RSALv2/SSPLv1 in March 2024. Valkey is the Linux Foundation fork that stayed BSD, is wire-compatible with what n8n's Bull queue speaks, and is where the packaging ecosystem went. | `redis_backend = "external"` + `redis_host` (+ optional `redis_auth_token` / `redis_auth_token_secret_ref`). |
| **Ingress controller** | ingress-nginx (`k8s_ingress_class_name = "nginx"`) | Whatever the cluster already runs. The module only sets a class name and annotations; it installs no controller. | Any `IngressClass` - set `k8s_ingress_class_name` and pass controller-specific annotations via `k8s_ingress_extra_annotations`. Or `create_ingress = false` and route it yourself, as [`../homelab-split-ingress`](../homelab-split-ingress) does. |
| **LoadBalancer / IP allocation** | The cluster's own (Cilium LB-IPAM, MetalLB, kube-vip) | The module creates no `LoadBalancer` for n8n at all - the ingress controller owns that. MetalLB, kube-vip and a cloud LB controller all work the same way. | Nothing to change here. Only the optional `postgres_lan_ip` / `metrics_lan_ip` Services need an allocator. |
| **TLS** | cert-manager `ClusterIssuer` (`cluster_issuer`) | cert-manager is the one thing everything else assumes. The module names an issuer and never inspects the certificate. | [`../../modules/tls-letsencrypt`](../../modules/tls-letsencrypt/) creates a Let's Encrypt issuer if you have none. Or name a different `ClusterIssuer`, or bring a pre-made Secret with `k8s_ingress_tls_secret_name`. |
| **DNS** | **None. Yours.** | How a name reaches a self-hosted cluster depends entirely on the setup - tunnel, public LoadBalancer, split-horizon on the LAN, reverse proxy on a VPS, Tailscale. There is no default that is not wrong for most readers. | [`../homelab-cloudflare`](../homelab-cloudflare) is one worked version (a Cloudflare Tunnel CNAME). Otherwise create the record however your setup wants. |
| **Storage** | The cluster's default `StorageClass` | Whatever the cluster already provides. | `storage_class` names one explicitly - worth doing for a database rather than inheriting whatever the default happens to be. |
| **Worker autoscaling** | CPU-based HPA from the chart | KEDA is not installed by this module, and a `ScaledObject` with no operator behind it silently pins workers at their floor. | `keda_installed = true` once KEDA is running cluster-wide; workers then scale on Redis queue depth. |

## Prerequisites

- A running Kubernetes cluster and a kubeconfig for it (default path `~/.kube/config`, override with `kubeconfig_path`)
- **CloudNativePG operator** installed cluster-wide:
  ```bash
  helm install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
  ```
- **ingress-nginx** and **cert-manager**, with the `ClusterIssuer` named in `cluster_issuer` already present
- A `LoadBalancer` IP allocator (Cilium LB-IPAM, MetalLB, kube-vip) if you set `postgres_lan_ip` or `metrics_lan_ip`
- A DNS record for `ui_host` reaching the cluster's ingress. **This example creates none** - there is no Route 53 equivalent on a self-hosted cluster, and the right way to publish a name depends on your setup. [`../homelab-cloudflare`](../homelab-cloudflare) is one worked version if you front the cluster with a Cloudflare Tunnel.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set ui_host

terraform init
terraform apply
```

To reach the UI: `open $(terraform output -raw n8n_url)`.

## Post-deployment

See [../../docs/post-deployment.md](../../docs/post-deployment.md) for the backend-independent steps.

## Scaling it up

The main pod stays at one replica: that is fixed, because leader election among mains is licensed. What you raise is the pools that do the work:

```hcl
n8n_worker_keda_max_replicas   = 20
n8n_webhook_hpa_max_replicas   = 10
cnpg_instances                 = 3
```

`terraform plan` warns if the ceilings together exceed the CPU your nodes can actually allocate.

## Teardown

```bash
terraform destroy
```

CNPG and Valkey PVCs are removed or retained according to their `StorageClass` reclaim policy, not by Terraform. Check for orphaned `PersistentVolume`s after destroying.

## Production considerations

This example is a reference deployment sized for a lab. Review before promoting it:

| Where | Setting | Current | Production |
|---|---|---|---|
| `main.tf` | `cnpg_instances` | `1` | `3` (one primary, two replicas) |
| `main.tf` | `cnpg_storage_class` | cluster default | an explicitly named, backed-up class |
| `main.tf` | `redis_backend = "valkey"` | single standalone instance, no failover | an external HA Redis, or accept the queue-loss window |
| `variables.tf` | `postgres_lan_ip` / `metrics_lan_ip` | `LoadBalancer`, no auth in front | leave both null (the default), or keep off-cluster access on a trusted VLAN |

CNPG takes no backups by default: configure `barmanObjectStore` on the operator, or back the cluster up out-of-band, before putting real workflows on it.

<!-- The block below is auto-generated by terraform-docs. Run `terraform-docs markdown table --output-file README.md --output-mode inject .` to refresh it. -->
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

- **This example owns the namespace on every path**, claim or not. It has to on the claim path, because the claim must exist before the Helm release and the claim needs the namespace: a pod referencing a missing PVC stays `Pending` and the release never goes ready. It does so on the other path too, because making ownership conditional meant the namespace changed resource address the moment you set `shared_storage_class`, which Terraform had no reason to sequence safely. `create_namespace = false` is passed unconditionally. An existing deployment needs one `terraform state mv` before its next apply, written out in `storage.tf`.
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
| [kubernetes_namespace.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_persistent_volume_claim_v1.shared](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cluster_issuer"></a> [cluster\_issuer](#input\_cluster\_issuer) | cert-manager ClusterIssuer to use for the ingress TLS cert. | `string` | `"letsencrypt-prod"` | no |
| <a name="input_keda_installed"></a> [keda\_installed](#input\_keda\_installed) | Set true when the KEDA operator is already installed cluster-wide. Workers then scale on Redis queue depth rather than CPU, and the chart's CPU worker HPA is disabled so the two never both own the worker Deployment. Leave false if you are unsure: a ScaledObject with no operator behind it never reconciles and workers stay at their minimum replica count without anything failing. | `bool` | `false` | no |
| <a name="input_kubeconfig_path"></a> [kubeconfig\_path](#input\_kubeconfig\_path) | Path to kubeconfig used by the kubernetes + helm providers. | `string` | `"~/.kube/config"` | no |
| <a name="input_metrics_lan_ip"></a> [metrics\_lan\_ip](#input\_metrics\_lan\_ip) | Address to publish the n8n main pod's /metrics endpoint on, for a Prometheus that runs outside the cluster and so cannot use in-cluster service discovery. Same allocator requirement as postgres\_lan\_ip. Leave null (the default) and no LoadBalancer Service is created; an in-cluster Prometheus or Alloy does not need this. | `string` | `null` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace to deploy into. Created by this example on every path rather than by the module, so that turning shared storage on later cannot move it between two resource addresses. An existing deployment upgrading to this needs one terraform state mv first, or the next apply plans to destroy the namespace; both commands are in storage.tf. | `string` | `"n8n"` | no |
| <a name="input_postgres_lan_ip"></a> [postgres\_lan\_ip](#input\_postgres\_lan\_ip) | Address to publish the CNPG rw endpoint on, for LAN clients that are not in the cluster - a Grafana instance querying n8n's execution tables, a DB client. Rendered as an io.cilium/lb-ipam-ips annotation, so it pins the address on Cilium LB-IPAM only; other allocators (MetalLB, kube-vip) ignore that key and will allocate an arbitrary address instead. To pin on those, call the module directly and use cnpg\_lan\_expose.annotations / metrics\_lan\_expose.annotations with the key your allocator honours. Leave null (the default) and no LoadBalancer Service is created. Postgres is exposed without a proxy in front of it, so only set this on a network you trust. | `string` | `null` | no |
| <a name="input_shared_mount_path"></a> [shared\_mount\_path](#input\_shared\_mount\_path) | Where the shared volume is mounted in the n8n container on all three pod types. Binary data goes to `shared_mount_path`/storage. Kept out of /home/node/.n8n deliberately: the chart already mounts its own data volume there on main, and nesting one mount inside another is a way to lose track of which pod sees what. Note the task-runner sidecar does not get this mount; n8n\_extra\_volume\_mounts reaches the n8n container only. | `string` | `"/opt/n8n-shared"` | no |
| <a name="input_shared_storage_class"></a> [shared\_storage\_class](#input\_shared\_storage\_class) | An RWX-capable StorageClass for a volume shared across the main, worker and webhook-processor pods (NFS, SMB, CephFS, or whatever the cluster offers). Leave null and no claim is created, in which case binary data stays in Postgres, which is n8n's default in queue mode. Set it and binary data moves to the shared volume instead. Check the class can actually reclaim before trusting it: with the NFS CSI driver against an NFSv3-only appliance the PV is deleted while every byte stays on the server, which reads as automatic cleanup and is not. | `string` | `null` | no |
| <a name="input_shared_storage_size"></a> [shared\_storage\_size](#input\_shared\_storage\_size) | Size of the shared RWX claim. Only used when shared\_storage\_class is set. Binary data from every execution lands here, so size it against retention rather than against one workflow. | `string` | `"20Gi"` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass for the CNPG and Valkey PVCs. Empty uses whatever the cluster's default StorageClass is. | `string` | `""` | no |
| <a name="input_ui_host"></a> [ui\_host](#input\_ui\_host) | Hostname served by ingress. A DNS record for it has to reach the cluster's ingress controller, and creating that record is yours to do - this example manages no DNS, because how a name reaches a self-hosted cluster depends entirely on the setup (a tunnel, a public LoadBalancer, split-horizon DNS on the LAN, a reverse proxy). See examples/homelab-cloudflare for one worked version. | `string` | `"n8n.example.com"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_backing_services"></a> [backing\_services](#output\_backing\_services) | Which backend provides Postgres and Redis for this deployment, and the in-cluster endpoints for each. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that points kubectl at the cluster this example deployed to. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once the ingress controller has published the host. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace the n8n release and its backing services were deployed into. |
<!-- END_TF_DOCS -->
