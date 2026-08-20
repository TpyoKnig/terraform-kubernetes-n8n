# Operating this module

The module targets a cluster you already run: Talos, kubeadm, k3s, or a managed
cluster from any cloud. It deploys queue-mode n8n with separate worker and
webhook-processor pools, autoscaling, and real backing services (CloudNativePG
for PostgreSQL, Valkey for Redis), and it leaves the cluster itself, the ingress
controller, cert-manager and DNS to you.

The premise is that this runs on hardware you already own as readily as on a
cloud bill, and that the same configuration scales from a lab to a production
cluster by changing values rather than rewriting the module call.

The [README](../README.md) is the input reference. This doc covers running it.

## Prerequisites

The module does not install operators it does not own. Before the first
apply the cluster needs:

| Component | Why | Notes |
| --- | --- | --- |
| **CloudNativePG operator** | Reconciles the `Cluster` CR this module renders | `helm install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace`. Only needed for `postgres_backend = "cnpg"`. |
| **ingress-nginx** (or another controller) | Serves the `Ingress` | Set `k8s_ingress_class_name` to match. |
| **cert-manager + a `ClusterIssuer`** | Issues the TLS certificate | Named via `k8s_ingress_cluster_issuer`. [`modules/tls-letsencrypt`](../modules/tls-letsencrypt/) creates a Let's Encrypt one if you have none. |
| **A default `StorageClass`** | Backs the CNPG and Valkey PVCs | Or name one explicitly with `cnpg_storage_class` / `valkey_storage_class`. |
| **DNS** | Resolves `k8s_ingress_host` to the ingress controller's address | Yours to manage; see below. |
| **A `LoadBalancer` IP allocator** | Only if you enable `cnpg_lan_expose` or `metrics_lan_expose` | Cilium LB-IPAM, MetalLB, kube-vip or a cloud controller. Any of them will allocate an address; *requesting a specific one* is allocator-specific - see below. |

None of these are installed for you. The module does not own cluster-wide
singletons on a caller's behalf, two n8n deployments in one cluster must not
fight over an ingress controller, and destroying one must not take the other's
operators down with it.

## Worker autoscaling

Workers scale on **CPU** by default, through the chart's own HPA, bounded by
`n8n_worker_keda_min_replicas` / `n8n_worker_keda_max_replicas`.

CPU is a lagging proxy for queue depth: a burst of queued executions does not
raise worker CPU until workers pick them up, so scale-up trails the burst rather
than anticipating it. A worker blocked on a slow HTTP call is idle by CPU while
its queue grows.

Set `k8s_keda_installed = true` to scale on queue depth instead. The chart then
renders a `ScaledObject` with two triggers, `bull:jobs:wait` for queued work and
`bull:jobs:active` for jobs held by a worker waiting on a task runner, KEDA
taking the maximum, bounded by the same `n8n_worker_keda_*` inputs. The chart's
CPU worker HPA is disabled so the two never both own the worker Deployment. The
Redis AUTH token reaches KEDA through `passwordFromEnv` on the worker pod, so it
never appears in the `ScaledObject`.

This input is an attestation, not a request: the module does not install KEDA.
Install it yourself first. If the flag is true and the operator is absent, the
`ScaledObject` applies and never reconciles, workers sit at their floor with
nothing failing, which is why `tests/scripts/smoke-test.sh` asserts its Ready
condition.

> **Switching an existing deployment from CPU to KEDA needs one manual step.**
> KEDA's validating webhook refuses a `ScaledObject` for a Deployment that is
> already owned by an HPA, and Helm creates the `ScaledObject` before removing
> the chart's old `n8n-worker` HPA in the same upgrade. The apply fails with
> `the workload 'n8n-worker' ... is already managed by the hpa 'n8n-worker'`.
> Delete the HPA first, then apply:
>
> ```bash
> kubectl delete hpa n8n-worker -n <namespace>
> terraform apply
> ```
>
> A fresh deployment with `k8s_keda_installed = true` from the start is
> unaffected: the CPU HPA is never created, so there is nothing to conflict
> with. Turning KEDA back off is also clean: the `ScaledObject` is removed and
> the CPU HPA recreated in the same apply.

## No licence, and one main pod

This module deploys Community-edition n8n. There is no licence input, the chart
values carry no `license` or `multiMain` block, and no `N8N_LICENSE_*` variable
reaches the pods.

The visible consequence is that `n8n-main` runs exactly one replica, with its
HPA disabled. Running more than one main needs leader election among them,
which n8n gates behind a licence; without it a second main is a second leader,
and both would fire the same schedule triggers and claim the same waiting
executions: duplicate runs, with nothing reporting an error.

That costs less than it sounds. The main pod serves the editor and the REST
API; it does not execute workflows in queue mode. Execution load is carried by
the worker and webhook-processor pools, and those are the ones that scale.

## Shared storage across the pods

Queue mode runs three pod types, and they do not share a filesystem. The chart
mounts its `data` volume at `/home/node/.n8n` on **main only**, and this module
leaves `persistence.enabled` at the chart default, so that volume is an
`emptyDir`: it does not survive a restart and workers cannot see it.

Where a workload genuinely needs one filesystem across all three, community
nodes loaded from disk rather than baked into an image is the usual case,
attach a `ReadWriteMany` claim yourself. `n8n_extra_volumes` and
`n8n_extra_volume_mounts` reach main, worker and webhook-processor pods alike,
which is exactly what the chart's own `persistence` does not do.

Create the claim outside the module, against an RWX-capable `StorageClass`
(SMB, NFS, CephFS, or whatever the cluster offers).

**Check that the class can actually reclaim before you trust it.** With the NFS
CSI driver the controller mounts the share itself to remove a released PVC's
directory, and where that mount fails, an appliance serving only NFSv3 is the
common case, because v3 needs a portmapper the controller cannot reach, the PV
is deleted and every byte stays on the server. It reads as automatic cleanup
and is not. Create a throwaway PVC against the class, delete it, and look at
the server; if the directory survives, set `reclaimPolicy: Retain` so the class
stops claiming otherwise, or use an SMB class instead, which has no such
dependency.

```hcl
resource "kubernetes_persistent_volume_claim_v1" "n8n_shared" {
  metadata {
    name      = "n8n-shared"
    namespace = "n8n"
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "rwx"    # whatever your cluster calls it
    resources { requests = { storage = "20Gi" } }
  }
}

module "n8n" {
  # ...

  n8n_extra_volumes = [{
    name                    = "shared"
    persistent_volume_claim = { claim_name = "n8n-shared" }
  }]

  n8n_extra_volume_mounts = [{
    name       = "shared"
    mount_path = "/opt/n8n-shared"
    read_only  = false
  }]

  n8n_custom_extensions_path = "/opt/n8n-shared/nodes"

  # Put binary data on the shared volume too. The mount alone does nothing:
  # n8n defaults binary data to "filesystem" in regular mode but to "database"
  # in scaling mode, and this module always runs queue mode, so without the
  # mode every payload still goes to Postgres while the volume sits there
  # empty and nothing reports a problem.
  n8n_binary_data_mode = "filesystem"
  n8n_binary_data_path = "/opt/n8n-shared"
}
```

The module refuses `n8n_binary_data_mode = "filesystem"` unless a writable
`n8n_extra_volume_mounts` entry covers `n8n_binary_data_path`, which is the
check that turns the silent version of this mistake into a plan error. Getting
it wrong used to cost an execution's payloads and say nothing.

These were two hand-written `n8n_extra_env` entries before the inputs existed.
Both names are reserved now, against `n8n_extra_env` and
`n8n_extra_env_from_secret` alike, and a plan that sets either is refused with a
message naming the input to use instead. Leaving them open meant the mode had
two doors and only one was checked: filesystem mode set through `extraEnv`
skipped the shared-mount validation, skipped `N8N_STORAGE_PATH`, and still had
`backing_services.binary_storage` report `filesystem` while the pods wrote to
per-pod local disk. Migrating is two lines, and the inputs are what the output
now reads.

The module renders `N8N_STORAGE_PATH`, not `N8N_BINARY_DATA_STORAGE_PATH`: the
latter still works but n8n's own deprecation list says "Use N8N_STORAGE_PATH
instead" (`packages/cli/src/deprecation/deprecation.service.ts`), and a
deprecated name is a warning in someone's logs later.

Verified on a three-node cluster: a worker on one node wrote a file, and the
main pod and a webhook processor on two *other* nodes read it back byte for
byte, with the file landing in the PV's subdirectory on the NFS server. Without
the shared volume, each of those pods sees a different empty directory and no
error anywhere says so.

Mount it anywhere except inside `/home/node/.n8n`, the module rejects that
path for `n8n_custom_extensions_path`, because the chart's `emptyDir` is
mounted over it on main pods and would hide whatever is underneath on some pod
types and not others.

**Do not point `cnpg_storage_class` or `valkey_storage_class` at NFS.**
PostgreSQL on NFS is a durability problem, not a performance one: CloudNativePG
expects block storage with working `fsync` and POSIX locking, and NFS gives
neither reliably: `nolock` mounts, common where the server serves NFSv3 only,
remove the locking Postgres relies on to keep two processes off one data
directory. Replicated block storage is the right home for the database;
`ReadWriteMany` is for files n8n reads and writes as files.

## DNS

The module creates no DNS records. Where a self-hosted cluster's ingress address
is usually a private one, there is no record the module could correctly write, so
DNS lives in the examples: `examples/homelab-cloudflare` and
`examples/homelab-godaddy` each show one worked strategy.

`examples/homelab` and `examples/homelab-split-ingress` are deliberately
DNS-neutral: they create no records at all. How a public name reaches a
self-hosted cluster is not something a module can assume: a tunnel, a public
`LoadBalancer`, split-horizon DNS on the LAN, a reverse proxy on a VPS and
Tailscale are all normal answers, and each wants different Terraform.

`examples/homelab-cloudflare` is one worked version: `ui_host` as a **proxied
CNAME** to `<tunnel-id>.cfargotunnel.com`. Copy it, replace it, or ignore it.

Two things about that record are deliberate:

- **It is a CNAME to a Cloudflare Tunnel, not an A record to the ingress
  LoadBalancer.** A homelab ingress usually sits on a private address that
  public DNS cannot route to, and publishing it would be wrong even where it
  resolves. The tunnel already terminates at ingress-nginx.
- **It must be proxied.** An unproxied CNAME to `<id>.cfargotunnel.com` does not
  resolve, the tunnel hostname only exists inside Cloudflare's edge.

The tunnel itself is not managed here. It is long-lived cluster infrastructure
serving every other hostname on the cluster, so a `terraform destroy` of one n8n
deployment must not be able to take it down.

The API token needs `Zone:DNS:Edit` on the zone. Pass it via
`CLOUDFLARE_API_TOKEN` rather than `terraform.tfvars`.

For the split-ingress topology, copy that `dns.tf` and give it one record per
hostname.

## Multiple hostnames

`n8n_additional_domains` adds names to the deployment. Each becomes another host
rule on the chart's main `Ingress`, and because the chart's webhook `Ingress`
derives its host list from the main one, the five webhook prefixes are routed for
every name without a second list.

Names are lowercased and de-duplicated against the canonical host, since
Kubernetes rejects an uppercase `Ingress` host and two rules for one name is
undefined behaviour rather than an error.

TLS stays **one secret covering every host**: cert-manager issues a single
`Certificate` with the rest as subject alternative names. The module does not
inspect what the issuer actually put on the certificate, an issuer scoped to
one DNS zone will simply fail to issue for a name outside it, at the
`Certificate`, not at plan time.

## Webhook URLs

n8n advertises webhook URLs from `WEBHOOK_URL`, and the module sets it through
the chart's own `webhook.url` value, which the chart renders into its ConfigMap
for every pod type. (On a split ingress the chart's value is deliberately
emptied and the module carries both `WEBHOOK_URL` and `N8N_EDITOR_BASE_URL`
through `config.extraEnv` instead.) It is never in the Secret that carries
`N8N_HOST`: the chart reads only four specific keys from that.

By default it is `https://` against the ingress host. Set `n8n_webhook_url` to
override it, which is what a split-ingress topology needs: the editor lives on
one hostname and webhooks are advertised on another. Without the override, n8n
hands out URLs on the editor's hostname, and the only thing that notices is the
external system whose deliveries stop arriving.

## Split ingress

`examples/homelab-split-ingress` runs the editor and production webhooks on
separate hostnames, with `create_ingress = false` and two caller-owned
`Ingress` objects.

The reason is not load, the webhook processors are already separate pods
either way. It is that n8n's own SSO is a licensed feature this module does not
carry, so the only identity boundary available is one you put in front of it at
the ingress: and that boundary cannot cover the whole deployment, because
webhook senders are machines and cannot complete an interactive login. Two
hostnames let you put Cloudflare Access (or an OIDC proxy, or an IP allowlist)
in front of the editor while the webhook hostname stays open and serves nothing
but the webhook prefixes.

**This needs no license.** Splitting webhook processors off the main process is
queue-mode behaviour, which n8n ships in the Community edition. The split is
two hostnames pointed at pools that already exist.

## Sizing

Start from `examples/homelab` and change values, not structure. The inputs
that actually move capacity:

| Input | Lab default | What to change it for |
| --- | --- | --- |
| `n8n_worker_keda_min_replicas` / `_max_replicas` | `1` / `10` | Sustained execution throughput |
| `n8n_worker_concurrency` | `10` | Executions in flight per worker pod; raise before raising replica count if each execution is light |
| `n8n_webhook_hpa_min_replicas` / `_max_replicas` | `2` / `8` | Inbound webhook rate |
| `n8n_*_cpu_request` / `_memory_request` | Module defaults | The floor the scheduler packs against - get these right before touching HPA bounds |
| `cnpg_instances` | `1` | `3` for a primary plus two replicas with automatic failover |
| `n8n_pruning_max_age` / `_max_count` | `336` hours / `10000` records | Database growth; the single biggest cause of a lab Postgres filling its PVC |

### Sizing against cluster capacity

Nothing adds nodes for you here, so autoscaler ceilings the cluster cannot reach
turn into pods stuck `Pending` during the first burst that needed them. At plan
time the module sums allocatable CPU across the schedulable nodes and warns when
the ceilings exceed it.

```
Warning: Check block assertion failed

Autoscaler maxima exceed the CPU this cluster can schedule. At their ceilings
the n8n pods request 12850m CPU (main 1 × 1250m, worker 10 × 1000m, webhook
8 × 200m), but the 3 schedulable node(s) in this cluster report 11760m
allocatable CPU in total, before anything else you run on them.
```

It only ever warns. Ceilings the current cluster cannot reach are a legitimate
configuration if adding nodes is the next thing you plan to do.

What counts as schedulable: cordoned nodes and nodes carrying any `NoSchedule`
or `NoExecute` taint are excluded (`PreferNoSchedule` is a preference, not a
bar, so those nodes still count), so a lab with three tainted control planes
alongside three workers is not counted at twice its real size. The filter is blunt in the safe
direction: a taint the n8n pods would tolerate still excludes the node, which
understates supply and warns slightly early.

What is *not* subtracted: whatever your own workloads and DaemonSets have
already claimed. The check sees more room than really exists, which costs a
warning rather than raising a false one.

**The node read is an ordinary data source, so a failed read fails the plan.**
Set `k8s_capacity_check_enabled = false` where the cluster is unreachable at
plan time or the credentials cannot list nodes cluster-wide, a plan-only CI job
is the realistic case. That removes the read entirely, not just the warning.
Everything else here needs the same cluster reachable in order to apply, so the
combination is narrow.

## Binary data

The module provisions no object storage. `n8n_binary_data_mode` decides where
binary payloads go, and it defaults to **database**, which is what n8n does in
the queue mode this module always runs. The reason there is no bucket is the
same one that keeps the operators out: this will not own a stateful data
service on a cluster it does not own, and an S3 bucket is a lifecycle that
outlives any one n8n deployment.

Database mode is safe rather than good. Every binary a workflow touches is
base64 inside an execution row, so a 10MB attachment is roughly 13MB of WAL,
replication traffic and backup, and execution pruning becomes the only thing
reclaiming it.

`n8n_binary_data_mode = "filesystem"` moves them onto disk, and in queue mode
that disk has to be shared: main, worker and webhook-processor each handle
different stages of one execution, so a payload written to one pod's local
volume does not exist for the next. The module refuses filesystem mode without
a writable `n8n_extra_volume_mounts` entry covering `n8n_binary_data_path`,
because that combination reports success and loses data. See "Shared storage
across the pods" above for the worked configuration.

To use a bucket, pass the chart's own `s3` tree through
`n8n_extra_helm_values`. It is raw YAML, and Helm applies it after the
module-rendered values, so it overrides the `enabled = false` above:

```hcl
n8n_extra_helm_values = <<-YAML
  s3:
    enabled: true
    storage:
      mode: s3
    bucket:
      name: n8n-binary-data
      region: us-east-1
YAML
```

Check the chart's `values.yaml` for the credential keys that release expects.
The bucket, its lifecycle rules and its credentials are yours to create: any
S3-compatible endpoint works, and MinIO on a NAS is enough for a lab.

## Backups

**CloudNativePG takes no backups by default, and neither does this
module.** A `Cluster` CR with no `backup` stanza is a database whose only
copy is a PVC. Before putting workflows you care about on it, either:

- set `cnpg_backup` to turn on continuous WAL archiving (S3, MinIO, or any
  S3-compatible endpoint: a NAS running MinIO is enough for a lab), or
- back it up out of band: `kubectl cnpg backup`, or a `pg_dump` CronJob
  against the rw Service.

### `cnpg_backup`

The input is passed through to the Cluster's `spec.backup` verbatim, which is
an exception to how every other input here works: the field's own shape has
changed under CloudNativePG and a typed surface would have frozen one version
of it.

**It reaches the in-tree path only.** CloudNativePG deprecated
`spec.backup.barmanObjectStore` in 1.26 in favour of the Barman Cloud Plugin,
which is configured through the Cluster's `spec.plugins` (the `cnpg_plugins`
input, below) plus a separate `ObjectStore` resource that stays yours to
create. On 1.26 and later the in-tree form still works and is still what this
input writes, **but only against an image carrying the barman-cloud
binaries**, and upstream ships those only in the deprecated bare-tag `system`
images. The module's default image is now a `minimal` one, which cannot serve
this input: a plan-time check warns about the pairing. Check what your
operator is with `kubectl get deployment -n cnpg-system -o
jsonpath='{..image}'`.

### `cnpg_plugins`

The plugin route, and the one with a future. Install the
[Barman Cloud Plugin](https://cloudnative-pg.io/plugin-barman-cloud/) in the
operator's namespace (CloudNativePG 1.26 or newer), create an `ObjectStore`
resource and its credentials Secret in the module's namespace, and declare the
plugin on the Cluster:

```hcl
cnpg_plugins = [
  {
    name          = "barman-cloud.cloudnative-pg.io"
    isWALArchiver = true
    parameters    = { barmanObjectName = "n8n-backup-store" }
  }
]
```

```hcl
resource "kubectl_manifest" "n8n_backup_store" {
  yaml_body = yamlencode({
    apiVersion = "barmancloud.cnpg.io/v1"
    kind       = "ObjectStore"
    metadata   = { name = "n8n-backup-store", namespace = module.n8n.namespace }
    spec = {
      configuration = {
        destinationPath = "s3://n8n-backups/"
        endpointURL     = "https://minio.example.com"
        s3Credentials = {
          accessKeyId     = { name = "minio-creds", key = "ACCESS_KEY_ID" }
          secretAccessKey = { name = "minio-creds", key = "SECRET_ACCESS_KEY" }
        }
        wal = { compression = "gzip" }
      }
      retentionPolicy = "30d" # here, not on the Cluster, under the plugin
    }
  })

  # Same setting as the module's own CNPG resources, for the same reason:
  # the operator manages fields on this object after creation.
  server_side_apply = true
}
```

Do not set `cnpg_backup` and a WAL-archiving plugin on the same cluster: both
claim the archive command. The base-backup half moves too: a `Backup` or
`ScheduledBackup` on a plugin cluster needs `method = "plugin"` and a
`pluginConfiguration` block, as the example further down notes.

In-tree form. Note that `retentionPolicy` is deprecated on the same schedule
as `barmanObjectStore`, not separately from it: the whole in-tree stanza moves
to the plugin together, and under the plugin retention is set on the
`ObjectStore` resource instead:

```hcl
cnpg_backup = {
  retentionPolicy = "30d" # deprecated with barmanObjectStore, not apart from it
  barmanObjectStore = {
    destinationPath = "s3://n8n-backups/"
    endpointURL     = "https://minio.example.com"
    s3Credentials = {
      accessKeyId     = { name = "minio-creds", key = "ACCESS_KEY_ID" }
      secretAccessKey = { name = "minio-creds", key = "SECRET_ACCESS_KEY" }
    }
    wal = { compression = "gzip" }
  }
}
```

The credentials Secret is yours to create, in the same namespace, and stays out
of this module for the same reason `db_password_secret_ref` does: reading it
here would put the value in Terraform state.

**WAL archiving alone is not a backup.** It is the half that lets you roll
forward; you still need a base backup to roll forward *from*. That is a
separate `ScheduledBackup` custom resource, which this module does not create:

```hcl
resource "kubectl_manifest" "n8n_pg_backup" {
  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ScheduledBackup"
    metadata   = { name = "n8n-pg-nightly", namespace = module.n8n.namespace }
    spec = {
      schedule             = "0 0 2 * * *" # CNPG takes six fields, seconds first
      backupOwnerReference = "self"
      cluster              = { name = "n8n-pg" }
      # Omitted, so it defaults to barmanObjectStore, matching the in-tree
      # cnpg_backup above. On a cluster using the Barman Cloud Plugin this
      # needs method = "plugin" and a pluginConfiguration block instead, and
      # a ScheduledBackup left on the default there produces nothing.
    }
  })

  # Same setting as the module's own CNPG resources, for the same reason:
  # the operator manages fields on this object after creation, and a
  # client-side apply would fight it for ownership on every later apply.
  server_side_apply = true
}
```

Restore is `bootstrap.recovery` on a **new** Cluster, not an edit to this one,
so a real restore drill means standing up a second cluster and pointing n8n at
it. Do it once before you need it.

### What `terraform destroy` takes with it

`terraform destroy` removes the `Cluster` CR, and CNPG deletes its PVCs behind
it. Whether the underlying volumes survive depends on your `StorageClass`
reclaim policy, not on Terraform: set it to `Retain` for anything you would
miss. Check for orphaned `PersistentVolume`s after a destroy either way.

The module does not put `prevent_destroy` on the Cluster, and cannot make that
conditional: Terraform requires a literal in a `lifecycle` block, so a
module-level toggle for it is not expressible. A hardcoded one would make
`terraform destroy` impossible for every consumer, including the throwaway test
deployments this module is developed against. Reclaim policy is the lever that
actually works here.

n8n's encryption key matters as much as the database: workflow credentials
are encrypted with it, and a database restored without the matching key
has unreadable credentials. Capture `terraform output -raw
n8n_encryption_key` somewhere outside the cluster before you need it.

## Network policy

`n8n_network_policy_enabled` renders the chart's `NetworkPolicy` over the n8n
pods. Off by default.

Read what it actually is before turning it on, because the name promises more
than it delivers. Every egress rule the chart writes targets `to: []`, meaning
all destinations, and the rules differ only by port. It is a port allowlist:

| Direction | Allowed |
| --- | --- |
| Ingress | port 5678, from n8n's own pods and from anywhere else |
| Egress | DNS (53), the configured database port, the configured Redis port, and 443, each to any destination |

Everything else is denied.

What that buys is genuine. n8n makes arbitrary outbound HTTP by design, so any
workflow, or any node with an SSRF bug, can reach whatever the pod network can
reach. On a Talos cluster that includes the Talos API on 50000. Closing every
port outside that allowlist removes most of the reachable surface.

What it does not buy is segmentation. Every port in the allowlist stays open to
every destination: anything answering on 443 is reachable, the Kubernetes API
included, and so is any host answering on the port you configured for the
database or for Redis — a LAN Postgres on 5432, for instance.

If you need policy written against real destinations, write a
`CiliumNetworkPolicy` (or equivalent) against the `app.kubernetes.io/name: n8n`
selector and **leave this toggle off**. The two do not compose the way it might
look. Kubernetes unions every policy that selects a pod and no policy can
subtract, so a destination-scoped rule of yours cannot take back a port this one
has already opened to `to: []`. Turning both on keeps this policy's allowlist
and adds whatever yours permits on top. There is no intersection to be had.

Before enabling it, check whether you rely on any of:

- **Workflows calling plaintext `http://` endpoints.** Port 80 is denied. This
  is the one that breaks real workflows most often.
- **An external OpenTelemetry collector on 4317 or 4318.** Denied. The module
  warns at plan time when `n8n_otel_exporter_otlp_endpoint` resolves to a port
  outside the allowlist above, because n8n does not treat a failed span export
  as an error: nothing crashes, the traces just stop. A collector reached over
  443 and one sharing the database or Redis port are unaffected. So is a
  same-pod sidecar on loopback, n8n's default `http://localhost:4318` included:
  that traffic never leaves the pod, so no NetworkPolicy governs it.
- **SMTP for n8n's own mail** (587, 465, 25). Denied.
- **A CNI that enforces NetworkPolicy.** Cilium and Calico do. A cluster whose
  CNI ignores policy will apply this object happily and enforce nothing, which
  is worse than not setting it, because `kubectl get networkpolicy` then reports
  protection you do not have.

## LAN-exposed services

Two optional `LoadBalancer` Services, both off by default, exist because a
lab typically runs its observability stack *outside* the cluster:

```hcl
cnpg_lan_expose = {
  enabled = true
  ip      = "10.0.0.50"   # rendered as an io.cilium/lb-ipam-ips annotation
}

metrics_lan_expose = {
  enabled = true
  ip      = "10.0.0.51"
}
```

**`ip` is a Cilium convenience, not a portable field.** It renders the
`io.cilium/lb-ipam-ips` annotation, which only Cilium LB-IPAM reads. Every
allocator spells the request differently, so on anything else use `annotations`
and leave `ip` empty, otherwise the address is silently ignored and you get an
arbitrary one, with nothing reporting that the request was dropped:

```hcl
cnpg_lan_expose = {
  enabled     = true
  annotations = { "metallb.universe.tf/loadBalancerIPs" = "10.0.0.50" }
}
```

`annotations` merges last, so it also overrides the key `ip` produces. Setting
neither still creates the Service and lets the allocator choose.

`cnpg_lan_expose` publishes the CNPG rw endpoint, so a Grafana
datasource or a migration tool can reach PostgreSQL without
`kubectl port-forward`. It selects on `cnpg.io/instanceRole = primary`, so
it follows a failover.

`metrics_lan_expose` is for a Prometheus running off-cluster (pair it with
`n8n_metrics_enabled = true`), but read what it exposes before you enable it.
n8n serves `/metrics` on its ordinary HTTP port, 5678, the same port the
editor and the REST API answer on, and a Service routes by port rather than
by path. So this publishes the whole application to that network, not the
metrics path alone. Narrowing it to one path would take an HTTP proxy in
front; there is nothing to set here that does it.

Neither Service has authentication in front of it. PostgreSQL at least still
demands its password. The metrics endpoint does not, and neither does
anything else on 5678 that n8n has not been configured to protect. Keep both
on a trusted VLAN, or leave them off and use `kubectl port-forward`.

## Task runners

The chart ships a launcher config that sets `N8N_RUNNERS_STDLIB_ALLOW`
and `N8N_RUNNERS_EXTERNAL_ALLOW` to empty strings, which blocks *every*
Python import including the standard library, `import time` fails. The
module replaces that config with its own `ConfigMap`
(`task_runners_config.tf`) so the Python task runner works out of the box.

Four inputs control the allowlists: `n8n_python_stdlib_allow`,
`n8n_python_external_allow`, `n8n_js_builtin_allow`, `n8n_js_external_allow`. Widening
them widens what arbitrary workflow code can reach, so treat them the way
you would treat any sandbox escape hatch.

## Upgrading

[docs/upgrading-n8n.md](./upgrading-n8n.md) covers the `n8n_image_tag` and
`n8n_chart_version` procedure. Two notes specific to this module:

- **CNPG major-version upgrades** are the operator's business, not
  Terraform's. Changing `cnpg_postgres_image_tag` across a major version
  triggers the operator's own upgrade path; read the CNPG release notes
  first.
- **The `gavinbunney/kubectl` provider** is what the CNPG `Cluster` CR is
  applied through. Configure it alongside `kubernetes` and `helm` in your root
  module, see `examples/homelab/providers.tf`. It is used rather than
  `hashicorp/kubernetes_manifest` so that `terraform plan` does not require a
  reachable cluster API.

## Troubleshooting

[docs/troubleshooting.md](./troubleshooting.md) covers the general failure
modes. The ones specific to this module:

**CNPG `Cluster` stays `Setting up primary`.** Almost always the PVC: no
default `StorageClass`, or a class whose provisioner cannot satisfy the
request. `kubectl get pvc -n <namespace>` and
`kubectl describe cluster -n <namespace>` say which.

**`Ingress` gets no address.** The controller named by
`k8s_ingress_class_name` is not running, or the class name does not match
what the controller watches. `kubectl get ingressclass`.

**Certificate stays `False`/`Pending`.** cert-manager cannot complete the
challenge, usually DNS for `k8s_ingress_host` does not yet resolve to the
ingress address, or the `ClusterIssuer` named in
`k8s_ingress_cluster_issuer` does not exist.
`kubectl describe certificate -n <namespace>`.

**Terraform reports drift on `kubectl_manifest.cnpg_cluster` every plan.**
`server_side_apply` should leave the operator as field manager for anything
the manifest does not set, so persistent drift means the manifest and the
operator are both claiming a field. Compare
`kubectl get cluster <name> -o yaml` against the manifest and drop the
contested field from the module rather than suppressing the diff.

**A LAN-exposed Service stays `<pending>`.** No `LoadBalancer` allocator in
the cluster, or the requested `ip` is outside the pool. On Cilium:
`kubectl get ciliumloadbalancerippool`.
