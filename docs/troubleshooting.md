# Troubleshooting

Issues observed in real deployments and how to resolve them. If you hit something not covered here, open an issue.

See also [operations.md → Troubleshooting](./operations.md#troubleshooting):
CloudNativePG, the ingress controller and cert-manager each have their own
failure modes, and a module-managed resource applying cleanly says nothing
about whether an operator reconciled it.

## `terraform apply`: `no cached repo found ... hashicorp-index.yaml`

### Symptom

One or more `helm_release` resources fail at create time with:

```text
Error: could not download chart: no cached repo found.
(try 'helm repo update'):
open /Users/<you>/Library/Caches/helm/repository/<repo>-index.yaml: no such file or directory
```

### Cause

The `hashicorp/helm` Terraform provider embeds the Helm SDK v3 and reuses the local Helm CLI's repository cache (`$HELM_REPOSITORY_CACHE`). This is still true on the `~> 3.0` provider line this module pins: provider 3.x is a Plugin Framework rewrite, but it continues to vendor `helm.sh/helm/v3` (v3.18.5 as of provider v3.2.0), so the embedded SDK is unchanged from the 2.x era. When the system Helm CLI is **Helm 4** (released 2025), the cache layout differs slightly from the v3 SDK's expectations and the SDK fails to find the index files even though the chart URL is hard-coded in the `helm_release` block.

This is environmental, not a module bug: but anyone running Helm 4 on macOS will see it. The workaround below is unchanged under provider 3.x. (Note: if the repository cache is already populated, for example from earlier `helm repo add`/`helm repo update` runs, the apply succeeds without intervention; the failure only appears against an empty or Helm-4-only cache.)

### Fix

Pre-populate the v3-compatible cache once before the first apply:

```bash
helm repo add valkey https://valkey-io.github.io/valkey-helm
helm repo update
```

Valkey is the only chart this affects. The n8n chart is pulled from an OCI
registry (`oci://ghcr.io/n8n-io/n8n-helm-chart`), and OCI references are
resolved directly rather than through a repository index, so there is no
`index.yaml` to cache and nothing to add. If you have repointed
`valkey_chart_repository` at a mirror, add that URL instead of the one above.

Then re-run `terraform apply`. Already-created resources are skipped; only the failed `helm_release`s are retried.

If your environment supports it, downgrading to Helm 3 also resolves the issue:

```bash
brew uninstall helm
brew install helm@3
```

## Smoke test reports `HTTP 000` after a recent destroy + re-apply

### Symptom

`tests/scripts/smoke-test.sh` fails the HTTP health, redirect, and API checks with `HTTP 000` against the n8n URL. Direct `dig n8n.example.com` resolves correctly, but `curl https://n8n.example.com/healthz` exits with code 6 (`CURLE_COULDNT_RESOLVE_HOST`).

### Cause (macOS)

`mDNSResponder` cached the NXDOMAIN response from the previous deployment's destroy phase and is serving it for 5 to 15 minutes even after the DNS record was re-created. `dig` and `host` bypass `mDNSResponder`; `curl`, browsers, and anything else using `getaddrinfo()` do not.

This only reproduces when the same FQDN is reused across consecutive `apply` → `destroy` → `apply` cycles on the same workstation, which is common during iterative development of this module but unusual in production.

### Fix

Flush the macOS DNS cache:

```bash
sudo killall -HUP mDNSResponder
```

Or wait for the negative cache to age out (typically 5 to 15 minutes). To avoid the issue entirely, use a fresh subdomain per deployment.

## Webhooks return HTTP 200 with an HTML body and never execute

### Symptom

A production webhook, Form Trigger, Wait-node resumption, or MCP Server Trigger URL returns `200` and a chunk of HTML instead of running the workflow. Nothing appears in the executions list. The caller logs a success, so the failure is silent on both ends.

Most often seen on `/webhook-waiting`, `/form`, `/form-waiting`, and `/mcp`, while plain `/webhook` works.

### Cause

The request reached the **main** pods rather than the webhook processors. This module runs the chart with `disableProductionWebhooksOnMainProcess = true`, which disables five endpoint families on the mains: `/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, and `/mcp`. When one of those paths hits a main pod, no handler is registered, so the request falls through to the editor's single-page-app handler, which answers `200` with the editor HTML.

How you end up here:

- **A bring-your-own Ingress** (`create_ingress = false`) whose catch-all rule precedes or replaces the webhook prefixes. This bites the editor half of a split-hostname topology especially easily, because it is natural to give it only a `/` rule.

### Fix

Route every prefix in `n8n_webhook_path_prefixes` to `n8n_webhook_service_name`, declared **before** any catch-all, on *every* Ingress that fronts n8n, internal ones included. Iterate the output rather than hardcoding:

```hcl
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
```

To confirm which pods are actually behind a host rule, compare the Service's endpoints with the pod IPs:

```bash
kubectl get endpointslice -n n8n -l kubernetes.io/service-name=<service> \
  -o jsonpath='{.items[*].endpoints[*].addresses[*]}'
kubectl get pods -n n8n -o custom-columns='NAME:.metadata.name,IP:.status.podIP' --no-headers
```

Webhook prefixes routed to the main Service instead of the webhook Service is the usual finding: the pods answer, so nothing looks broken, but production webhooks are not served there.

A correctly routed webhook prefix returns `application/json` from n8n (for example `404 {"code":404,"message":"The requested webhook ... is not registered."}`), never `text/html`. The content type is the quickest discriminator.

See [examples/homelab-split-ingress](../examples/homelab-split-ingress/) for a worked split configuration.

## Caller-owned Ingress fails with `namespaces "n8n" not found`

### Symptom

On the first `terraform apply` with `create_ingress = false`, your own `kubernetes_ingress_v1` (or any other namespaced resource) fails:

```text
Error: Failed to create Ingress 'n8n/my-ingress' because: namespaces "n8n" not found
```

A re-apply then succeeds, because the namespace exists by that point.

### Cause

Your resource had no dependency edge to the namespace, so Terraform scheduled it concurrently with the module rather than after it. In module versions where `output "namespace"` returned `var.k8s_namespace`, the output was a plan-time constant and consuming it created no ordering at all.

### Fix

Upgrade: `namespace` is now sourced from `kubernetes_namespace.n8n[0]` when the module creates the namespace (`create_namespace = true`, the default), so consuming it orders your resources implicitly. If you set `create_namespace = false` to deploy into a namespace you manage yourself, there is no module-owned namespace resource to order against; make sure that namespace already exists before applying this module.

Also add an explicit dependency on the whole module for anything that routes to the module's Services:

```hcl
resource "kubernetes_ingress_v1" "mine" {
  # ...
  depends_on = [module.n8n]
}
```

The namespace edge alone is not sufficient. Without this, the Ingress can be created before the Helm release has produced the Services it names, and the ingress controller has nothing to route to until it resyncs.

## Pods stay `Pending` with `Insufficient cpu`

### Symptom

Some n8n pods never schedule. `kubectl describe pod` reports:

```text
0/6 nodes are available: 6 Insufficient cpu
```

The cluster autoscaler, if you run one, adds no nodes because it is already
at its maximum size. It usually shows up during a rolling update, which stalls
while the surging ReplicaSet competes for the same exhausted CPU.

### Cause

An autoscaler ceiling is set above what the cluster can schedule. The HPAs and
KEDA scale toward their maxima regardless of whether the capacity exists, and
nothing adds nodes for you here. Confirm with:

```bash
# What the autoscalers are aiming for
kubectl -n <namespace> get hpa
kubectl -n <namespace> get scaledobject

# What the nodes can actually give
kubectl get nodes -o custom-columns='NODE:.metadata.name,ALLOCATABLE_CPU:.status.allocatable.cpu'
kubectl describe node <node> | sed -n '/Allocated resources/,/^Events/p'
```

### Fix

Size the two coupled input groups together: the autoscaler ceilings and the
per-pod CPU requests, against the CPU the cluster actually has. See
[operations.md → Sizing against cluster capacity](./operations.md#sizing-against-cluster-capacity)
for the arithmetic.

The module warns about this at plan time, so `terraform plan` will already be
reporting `Warning: Check block assertion failed` with the two numbers. The
levers are `n8n_worker_keda_max_replicas` and `n8n_webhook_hpa_max_replicas`;
the main pod is a fixed single replica and contributes a constant.

## First apply: a pod crashes on `relation ... already exists`, Helm stuck `pending-install`

### Symptom

On the **first** apply into an empty database, one n8n pod fails during startup
migrations with a duplicate-object error, and no other pod reports anything
wrong:

```text
Starting migration CreateWorkflowNameIndex1691088862123
relation "IDX_workflow_entity_name" already exists
QueryFailedError: relation "IDX_workflow_entity_name" already exists
```

Other spellings of the same failure: `column "isGlobal" of relation
"credentials_entity" already exists`, or any `... already exists` naming an
index or column.

If `terraform apply` is then interrupted, or the Helm wait times out, the
release is left in `pending-install`, which Helm cannot upgrade out of:

```text
STATUS: pending-install
```

### Cause

The chart creates the main, worker and webhook-processor Deployments in the
same apply, and every n8n pod runs database migrations at startup. Against an
empty database they run concurrently, and n8n takes no cross-pod lock, so one
pod wins each migration and the others find the object already created.

This is upstream behaviour in n8n and the chart, not something the module
configures. Terraform cannot order it either: Helm creates all three
Deployments in one release, and there is no dependency edge to add between
them.

### Fix

Usually nothing: it resolves itself. The losing pod restarts, finds the
migrations already applied, and starts normally. A single restart on a pod
during the first apply is expected.

Where it does not resolve, the losing pod stays `Running` but never becomes
ready, because n8n logs the error without exiting. Delete it and let the
Deployment replace it:

```bash
kubectl delete pod -n <namespace> -l app.kubernetes.io/component=main
```

If the apply was interrupted and the release is `pending-install`, Helm has to
be cleared before Terraform can proceed, an upgrade from that state always
fails:

```bash
helm uninstall n8n -n <namespace>
terraform apply
```

To avoid it on a first deployment altogether, let the database migrate under a
single pod before the others start:

```bash
kubectl scale deploy/n8n-worker deploy/n8n-webhook-processor -n <namespace> --replicas=0
kubectl rollout status deploy/n8n-main -n <namespace>
kubectl scale deploy/n8n-worker --replicas=1 -n <namespace>
kubectl scale deploy/n8n-webhook-processor --replicas=2 -n <namespace>
```

Subsequent applies are unaffected: the migrations have already run, so there is
nothing left to race over.

## `terraform destroy` hangs on namespace or finalizers

### Symptom

The namespace sits in `Terminating` for more than a couple of minutes and
`terraform destroy` waits on it.

### Cause

Something in the namespace still carries a finalizer whose controller is no
longer around to clear it. The usual candidates here are a KEDA `ScaledObject`
left behind when KEDA was uninstalled, and CloudNativePG resources when the
operator went away before its `Cluster` did. Kubernetes will not delete the
namespace until every object in it is gone.

### Fix

Strip finalizers from whatever is left in the namespace:

```bash
NS=$(terraform output -raw namespace)

kubectl api-resources --verbs=list --namespaced -o name | while read RESOURCE; do
  kubectl get "$RESOURCE" -n "$NS" \
    -o jsonpath='{range .items[?(@.metadata.finalizers)]}{@.kind}/{@.metadata.name}{"\n"}{end}' \
    2>/dev/null | while read OBJ; do
    [ -n "$OBJ" ] || continue
    NAME=$(echo "$OBJ" | cut -d/ -f2)
    kubectl patch "$RESOURCE/$NAME" -n "$NS" --type=merge \
      -p '{"metadata":{"finalizers":null}}'
  done
done
```

This is a blunt instrument: it tells Kubernetes to stop waiting for cleanup
that is never going to happen. Anything the missing controller would have
tidied up outside the cluster stays untidied, so it is worth a look at what
had a finalizer before reaching for this.

## Recovery from a stuck `pending-rollback` release

### Symptom

`terraform apply` fails with an error naming the release and
`another operation (install/upgrade/rollback) is in progress`, or Helm reports
the release status as `pending-rollback`. Re-running the apply fails the same
way.

### Cause

An upgrade failed, Helm started rolling back, and that rollback did not finish,
usually because the process was interrupted. Helm refuses to act on a release
in a pending state, so every subsequent apply hits the same wall.

### Fix

Do not `helm uninstall` this one. On an existing deployment that deletes the
running release. Finish the rollback instead, using the last revision that
actually deployed:

```bash
NS=$(terraform output -raw namespace)

helm history n8n -n "$NS"
helm rollback n8n <last-deployed-revision> -n "$NS"
terraform apply
```

If the rollback itself will not run, delete the Secret holding the pending
revision so Helm falls back to the previous one, then roll back again:

```bash
kubectl get secret -n "$NS" -l owner=helm,name=n8n
kubectl delete secret -n "$NS" sh.helm.release.v1.n8n.v<pending-revision>
```

## Webhook processor HPA thrashes, or pods OOMKill, with `n8n_reinstall_missing_packages = true`

### Symptom

With `n8n_reinstall_missing_packages = true`, every pod runs npm installs at
boot, and n8n rebroadcasts installs to all pods via pubsub, so during a
rolling restart every pod installs repeatedly. Against the webhook
processor's defaults (`n8n_webhook_cpu_request = "300m"`,
`n8n_webhook_cpu_limit = "800m"`, `n8n_webhook_memory_limit = "1Gi"`) this
produces two distinct failure modes:

1. **CPU:** installs burn 800-1000m per pod, 200-300% of the 300m request.
   The CPU-based `n8n_webhook_processor` HPA (`scaling.tf`) reads that as sustained
   high utilization and scales up on every rollout: each new pod boots,
   installs, and broadcasts, keeping utilization above target and feeding
   back into further scale-up until capacity runs out.
2. **Memory:** concurrent installs plus the n8n baseline exceed the memory
   limit. Pods get OOMKilled (exit 137) mid-install, restart, reinstall, and
   broadcast again, a self-feeding crash loop. Interrupted installs can also
   leave corrupted package directories behind (`ENOTEMPTY`,
   `tar: invalid magic`), which persist because the packages directory lives
   on the pod's ephemeral filesystem.

`terraform plan`/`apply` surfaces a warning for this specific combination via
the `webhook_resources_sized_for_reinstall_missing_packages` check in
`scaling.tf`.

### Cause

`n8n_reinstall_missing_packages` is sized for the general case (occasional
reinstall of a handful of packages), not for the CPU/memory burst every pod
produces simultaneously during a rolling restart. The module's webhook
processor defaults predate that toggle's production cost.

### Fix

Raise the webhook processor's requests and limits above the module defaults.
One operator's stable production values, reported in
[issue #52](https://github.com/n8n-io/terraform-aws-n8n/issues/52):

```hcl
n8n_webhook_cpu_request    = "800m"
n8n_webhook_cpu_limit      = "1500m"
n8n_webhook_memory_request = "1Gi"
n8n_webhook_memory_limit   = "2Gi"
```

Optionally also widen `n8n_webhook_hpa_scale_up_stabilization_window_seconds`
(default `0`, matching the Kubernetes API's own default) so a short boot-time
CPU spike doesn't immediately trigger a scale-up:

```hcl
n8n_webhook_hpa_scale_up_stabilization_window_seconds = 300
```

If pods already have corrupted package directories from an interrupted
install, a rolling restart after raising the resources above resolves it:
n8n rewrites the directory from scratch on the next successful install.

## `terraform plan` fails with `Get "http://localhost/...": connect: connection refused`

### Symptom

A `terraform plan` fails while refreshing Kubernetes resources that already
exist:

```text
Error: Get "http://localhost/api/v1/namespaces/n8n": dial tcp [::1]:80: connect: connection refused

  with module.n8n.kubernetes_namespace.n8n[0],
```

The first apply worked. The error appears only once Kubernetes resources exist
in state **and** some other change is pending in the same configuration,
upstream of the cluster.

### Cause

`localhost` is the `kubernetes` provider's default `host`. Seeing it means the
provider got no endpoint, not that your kubeconfig is wrong.

That happens when the provider is configured from values that are unknown at
plan time. If `host` / `cluster_ca_certificate` come from a data source or from
another module's outputs, Terraform defers that read to apply time whenever
anything it depends on has a pending change. Deferred, the values are unknown,
the provider treats the unknown `host` as unset, and falls back to `localhost`
while refreshing resources already in state.

The common shapes: the cluster is itself managed in the same configuration, or
the provider reads a `data` source for cluster credentials.

### Fix

Apply the pending upstream change on its own first, then plan normally:

```bash
terraform apply -target=module.cluster   # or whatever carries the pending change
terraform plan                           # now refreshes against the real cluster
```

Better, configure the providers from a static source, a kubeconfig file, or
literal values, so nothing in the configuration can make them unknown. That is
why the examples configure `kubernetes`, `helm` and `kubectl` from
`config_path` rather than from module outputs.

Do not reach for `-refresh=false` to get past the error. It defers every data
source in the configuration, which turns a refresh problem into an unknown-value
problem in resources that have nothing to do with the cluster.

## Two n8n deployments sharing one external Redis interfere with each other's workflow activation

### Symptom

Activating a workflow on one deployment fails with `webhook not
registered`, even immediately after a fresh `terraform apply` and even
after repeated activate/deactivate retries, while a second, independent
n8n deployment elsewhere is live and pointed at the **same** Redis (e.g. two
deployments both set to `redis_backend = "external"` against one shared
instance).

### Cause

n8n's scaling-mode pub/sub command channel (`<prefix>:n8n.commands`,
prefixed by `N8N_REDIS_KEY_PREFIX`, which defaults to `"n8n"` for every
deployment) is not scoped per deployment. One deployment's
`add-webhooks-triggers-and-pollers` broadcast is received by every other
main pod subscribed to that same channel on the same Redis, each of which
looks the workflow up in *its own* database, fails to find it, and
publishes a `display-workflow-activation-error` back onto the same shared
channel, which is what breaks the *other* deployment's own activation.
Confirmed live by subscribing to the channel directly and matching the
broadcasting pod's `senderId` against the other deployment's own pod name.
This has nothing to do with which deployment created the Redis: it affects any
two n8n installs (from this module or otherwise) sharing one Redis instance.

### Fix

Set `redis_key_prefix` to a distinct value on every deployment that shares
a Redis instance with another:

```hcl
redis_key_prefix = "tenant-a" # a different value on every deployment sharing this Redis
```

This scopes both `N8N_REDIS_KEY_PREFIX` and the Bull queue's own key prefix
(`QUEUE_BULL_PREFIX`) to the value given, and keeps KEDA's queue-depth
triggers reading from the matching, non-default queue keys. Leave it unset on
the default `redis_backend = "valkey"` path: that release is dedicated to one
deployment, so there is nothing to scope.
