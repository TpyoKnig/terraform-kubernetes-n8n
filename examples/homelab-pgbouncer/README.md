# Homelab + PgBouncer example

The base [`homelab`](../homelab/) deployment with a PgBouncer connection pooler in front of PostgreSQL. Differs from `homelab` only in the four pooler inputs and the two connection inputs they imply; everything else is identical, so read that README first for the layers and how to swap them.

Use this one when the worker tier autoscales. Queue-mode n8n hits a connection limit before it hits a CPU limit, and the failure is not a slowdown.

## The problem it solves

Every n8n pod holds `db_postgresdb_pool_size` persistent PostgreSQL connections. That number gets multiplied by a pod count an autoscaler owns, and the CNPG `Cluster` this module creates runs `max_connections = 200`.

Work it through at the module defaults, which is the interesting part: it fits, and barely.

| | at module defaults | worker ceiling raised to 16 |
|---|---|---|
| `max_connections` | 200 | 200 |
| less `superuser_reserved_connections` | 197 usable | 197 usable |
| `db_postgresdb_pool_size` | 10 per pod | 10 per pod |
| worker tier at its KEDA ceiling | 10 pods | 16 pods |
| webhook-processor tier at its HPA ceiling | 8 pods | 8 pods |
| main | 1 pod | 1 pod |
| **demanded** | **190** | **250** |

So the stock configuration sits seven connections from the wall, and the first thing anyone does when the queue backs up is raise `n8n_worker_keda_max_replicas`. Six more workers is all it takes. Nothing warns you: the ceiling is a resource decision everywhere else, and this is the one place it is also a connection decision.

Past the limit, pods do not degrade. A new worker cannot initialise its pool, exits non-zero, and CrashLoops:

```
Initial database connection attempt 5 failed: remaining connection slots
are reserved for roles with the SUPERUSER attribute
There was an error initializing DB
```

The symptom at the edge is worse than the cause. Median latency stays flat and healthy while a fraction of requests hang until the client gives up, because most requests are served by workers that are fine and the rest arrive during a crash storm. Failure rate stops tracking load: it depends on how many crash storms happened to land in the window, not on how much traffic you sent. A latency graph of this looks like an intermittent network fault, not a database limit.

## Why a pooler rather than a bigger number

Raising `max_connections` moves the wall to the next scale-up, and every backend costs memory. Lowering `db_postgresdb_pool_size` trades the wall for less per-pod concurrency. Neither removes the coupling that pod count sets database load.

PgBouncer does. Pods connect to the pooler; the pooler holds `cnpg_pooler_pool_size` real connections per instance. Postgres sees `cnpg_pooler_pool_size x cnpg_pooler_instances` no matter how far the tiers scale, and pod count stops being a term in the arithmetic.

Measured on a 5-node lab cluster, same workload, before and after:

| | direct | pooled |
|---|---|---|
| peak Postgres backends | pinned at exactly 197 | flat 61-63 at every rate |
| clean throughput | 25/s | 50/s |
| delivered ceiling | ~48/s | ~70-80/s |
| failure mode | CrashLoop stalls, flat median | ordinary queueing, rising median |

The median is the tell. Before, `p50` sat at ~460ms at every offered rate while the tail pinned to the timeout, which is not saturation; after, `p50` climbs with load, which is. The system started failing the way a busy system should.

## What it creates

Everything [`homelab`](../homelab/) creates, plus:

- CNPG `Pooler/n8n-pg-pooler-rw` - two PgBouncer instances in transaction mode
- `Service/n8n-pg-pooler-rw`, which n8n connects to instead of the `-rw` Service

CloudNativePG provisions the `cnpg_pooler_pgbouncer` auth role into the cluster when the `Pooler` appears. Nothing to create by hand.

## Inputs that matter here

| Input | Here | Why |
|---|---|---|
| `cnpg_pooler_enabled` | `true` | The switch. Everything else is tuning. |
| `cnpg_pooler_instances` | `2` | So a pooler restart does not take the database path with it. Note this does not make the database HA: `cnpg_instances` governs that, and one Postgres behind two poolers is still one Postgres. |
| `cnpg_pooler_pool_size` | `25` | Real connections per instance. 25 x 2 = 50 against ~197 usable, leaving room for the operator, monitoring and an interactive `psql`. **This is the number to check against `max_connections`, not pod count.** |
| `cnpg_pooler_max_client_conn` | `500` | Client slots per instance. Cheap, unlike server connections. Keep well above `pods x db_postgresdb_pool_size`. |
| `db_postgresdb_pool_size` | `5` | Now connections to PgBouncer, not Postgres, so a lower value costs nothing. |
| `db_postgresdb_ssl_enabled` | `false` | **Required.** The module rejects the combination otherwise. |

That last one is not a preference. The CNPG `Pooler` serves clients in plaintext and encrypts its own leg to Postgres, so leaving TLS on has n8n negotiate against a listener that does not speak it, and the error names a connection failure rather than the pooler.

## Transaction mode, and what it costs

`cnpg_pooler_mode` defaults to `transaction`, which is the only mode that solves the problem. Session mode holds a server connection for the life of the client session, and n8n's TypeORM pool is long-lived, so it reproduces the original connection count and changes nothing.

Transaction mode gives up session-scoped state: server-side named prepared statements, `LISTEN`/`NOTIFY`, session-level advisory locks, and `SET`. n8n in queue mode uses Redis for queueing and leader election rather than Postgres `LISTEN`, and node-postgres issues unnamed portals by default, so the paths n8n actually takes are unaffected.

The case to watch is TypeORM migrations at startup. If n8n ever fails to boot after a version bump with a lock-related error, set `cnpg_pooler_enabled = false`, apply so the release points back at the `-rw` Service, let it migrate, then turn it on again. There is no per-boot override: `db_host` is ignored on the CNPG backend, and `backing_services.postgres_direct_host` is an output rather than a lever, for `psql` and for maintenance you run yourself.

That caveat is not theoretical. A session-scoped advisory lock taken through the pooler stayed held by a server backend after the client disconnected, and blocked a later direct connection until the backend was terminated.

## Sizing it

Two numbers, and only one of them is about pods.

1. **Server side.** `cnpg_pooler_pool_size x cnpg_pooler_instances` must fit inside `max_connections` less `superuser_reserved_connections`, with headroom for the CNPG operator, monitoring and a human. This is fixed regardless of scale.
2. **Client side.** `cnpg_pooler_max_client_conn x cnpg_pooler_instances` must exceed the worst-case `pods x db_postgresdb_pool_size`. This one does move with your ceilings, so recheck it when you raise them.

## Raising the worker ceiling

With a pooler in front, raising `n8n_worker_keda_max_replicas` is a resource question rather than a connection one. Without one it was neither: more workers meant more connections against the same limit, so raising the ceiling brought the CrashLoop on sooner.

Check per-node CPU before you raise it. The scheduler places whole worker pods on individual nodes, so a cluster-wide free-CPU total overstates what is actually reachable; a cluster with 13,000m free spread across five nodes may fit far fewer 700m pods than the division suggests.

## Throughput and sizing

**Read the workload caveat first.** Every number below was measured on one workflow: five JSON nodes, 50ms declared work each, five items, no Code node and no external HTTP call. It executes in roughly 500ms and is deliberately cheap, so it stresses the platform (queue, connections, scheduling) rather than the node runtime. A workflow that calls an API, runs Python, or moves binary data will land somewhere else entirely, and probably far lower. Treat these as the shape of the curve and the method for finding yours, not as a quote for your workload.

Hardware: five nodes, 6 vCPU and 32GB each, Talos, single-instance CNPG on local NVMe.

### What one worker is worth

| | executions/sec/worker | failure rate |
|---|---|---|
| Comfortable | **~3.1** | 0.70% |
| At the knee | ~4.4 | 23.66% |

Workers ran `--concurrency=10`, so 16 workers is 160 concurrent execution slots. Sizing on the comfortable figure rather than the knee is the whole point: at the knee, latency has already gone from 490ms to 9.8s at the median, and the tier has no capacity left to absorb a burst.

### Sizing from a target rate

Budget **3 executions/sec per worker** for this workflow, then check the two limits that are not about workers.

| Target | Workers | Worker CPU requests | Pods total | Client conns used |
|---|---|---|---|---|
| 15/s | 5 | 3,500m | ~14 | 70 |
| 30/s | 10 | 7,000m | ~19 | 95 |
| 50/s | 16 | 11,200m | ~25 | 125 |
| 75/s | 25 | 17,500m | ~34 | 170 |
| 100/s | 34 | 23,800m | ~43 | 215 |

Worker CPU requests are **700m per pod**, not 500m: this example sets `n8n_task_runners_enabled = true`, which adds a task-runner sidecar at the module's default `n8n_task_runner_cpu_request` of 200m on top of the worker's 500m. Sizing on 500m understates the tier by 40%, and the shortfall shows up as `Pending` replicas rather than as an error. Drop the sidecar or lower its request and the column shrinks accordingly. Pods total adds the webhook-processor tier at its ceiling of 8, plus main. Client connections are `pods x db_postgresdb_pool_size` at the 5 this example sets.

**The connection column is the point of this example.** It never approaches `cnpg_pooler_max_client_conn x cnpg_pooler_instances` (1,000 here), and n8n's real backends stay capped at `cnpg_pooler_pool_size x cnpg_pooler_instances` = 50 across every row. Total Postgres backends run a little above that, 61-63 measured, because CNPG's own instance manager, replication and metrics connections are not n8n's and do not come out of the pooler's budget. Without the pooler, that same 100/s row would demand 430 connections against 197 available, and the tier would CrashLoop somewhere around the 30/s row instead.

### The limit that actually bites: node CPU

Worker pods are scheduled whole, onto individual nodes. A cluster-wide free-CPU total overstates what is reachable, and the error is not small.

Worked example from the lab. Free CPU per node was 3436m, 2636m, 3566m, 2206m and 2086m: 13,930m in total, which divides to 19 pods at 700m. Per node it is 4 + 3 + 5 + 3 + 2 = **17 pods**, and that fills every node to the brim. Sizing from the total would have put the KEDA ceiling at a number the scheduler could never reach, and the surplus replicas sit `Pending` while the queue backs up. A queue draining slowly because replicas are Pending looks exactly like one draining slowly because workers are saturated.

So: divide per node, then leave a node's worth of headroom.

### Measuring your own workflow

The method matters more than the table, because one detail invalidated an entire earlier run here.

Drive a **fixed arrival rate**, not a fixed concurrency. A closed-loop harness that fires N requests, waits for all of them, then repeats makes throughput a function of its own tail latency (`N / (slowest + delay)`). It will draw you a clean saturation curve that describes the harness and not n8n. An earlier ramp here reported a confident 28/s ceiling that was reproducible from its own p95 alone, within 1-8%, at every concurrency level.

With `k6`, that is the `constant-arrival-rate` executor. Three things to check before quoting any number it gives you:

- **`dropped_iterations` must be zero.** Non-zero means k6 could not launch work at the requested rate, so you measured the generator.
- **Size the VU pool as `rate x request timeout`.** A VU is held for the life of its request, so a 30s timeout at 100/s needs 3,000 VUs in the worst case. Undersize it and the pool caps the rate from inside the generator, which looks identical to the target refusing load.
- **Watch the generator's own load average.** A 4-core box driving process-per-request load hit load 42 here, with nothing in the output saying so.

And one reading rule: **if the median does not move under load, you are not looking at saturation.** A flat p50 with the tail pinned to the timeout is something stalling episodically. That signature is what exposed the CrashLoop.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit ui_host, cluster_issuer, storage_class
terraform init
terraform apply
```

Prerequisites are [`homelab`](../homelab/)'s, unchanged. The CloudNativePG operator already had to be installed for the base example; the `Pooler` needs nothing beyond it.

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
| <a name="input_kubeconfig_path"></a> [kubeconfig\_path](#input\_kubeconfig\_path) | Path to kubeconfig used by the kubernetes, helm and kubectl providers (the kubectl one applies the CNPG Cluster CR). | `string` | `"~/.kube/config"` | no |
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
