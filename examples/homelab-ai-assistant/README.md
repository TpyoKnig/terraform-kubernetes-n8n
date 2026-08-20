# Homelab example, with the AI Assistant and Agents on

The [`homelab`](../homelab/) example unchanged, plus n8n's AI Assistant and Agents module turned on and wired to a code-execution sandbox. Start with `homelab` if you have not deployed n8n before; come here once you want the assistant working, not just installed.

Two things this example does **not** do, on purpose:

- **It does not deploy the sandbox.** `n8n-sandbox-service` is a separate service with its own Helm chart, its own lifecycle, and (as of chart 0.4.0) no published Helm repository to pin a `helm_release` resource against - the chart still lives only in the upstream repository's `main` branch. Vendoring a copy into this repository to work around that would mean keeping a fork of someone else's chart in sync by hand. The module's own stance already treats the sandbox as a caller prerequisite, the same category as the ingress controller or the CNPG operator (see [`../../docs/ai-assistant.md`](../../docs/ai-assistant.md)); this example inherits that rather than special-casing itself out of it.
- **It does not create the credentials Secret.** `ai-assistant-secrets` holds your model API key and the sandbox's own API key. Declaring it as a `kubernetes_secret` resource would put both straight into Terraform state. `kubectl create secret` below keeps them out.

## What it creates

Everything [`homelab`](../homelab/) creates, plus:

- `N8N_ENABLED_MODULES=instance-ai,agents` and the rest of the AI Assistant / Agents wiring on every n8n pod (main, worker, webhook-processor), pointed at a sandbox you stand up separately
- An `ai_assistant` output showing the model and sandbox URL actually wired in, so a `sandbox_namespace` / `sandbox_release_name` typo shows up in `terraform plan` output instead of only as a code-execution timeout discovered in the browser

## Prerequisites

Everything [`homelab`](../homelab/) needs, plus:

- **cert-manager**, already required by `homelab` for the ingress certificate, is also how the sandbox's mTLS certificates get issued below.
- **An Anthropic (or other supported provider) API key** for `N8N_INSTANCE_AI_MODEL_API_KEY`.
- **n8n 2.32.3 or later** for the Agents module (the module's own `n8n_image_tag` default already clears this; only matters if you override it - see [`../../docs/ai-assistant.md`](../../docs/ai-assistant.md) "Version floor" for what an unmet floor looks like: n8n starts normally and the feature simply never appears, with nothing in the logs naming the reason).
- **A namespace that can run a privileged pod.** The sandbox's in-cluster code runner needs Docker-in-Docker, which needs `privileged: true`. On an immutable-rootfs distribution (Talos, Bottlerocket, Flatcar, Fedora CoreOS) that rules out the chart's `sysbox` isolation, which is why the steps below use `runner.isolation: privileged` instead. Platforms that block privileged containers outright (GKE Autopilot, for example) cannot run the in-cluster runner at all; use the chart's `dataPlane.mode: external` there, which this README does not cover.

## Standing up the sandbox

Chart `n8n-io/n8n-sandbox-service` 0.4.0 (merged as [PR #126](https://github.com/n8n-io/n8n-sandbox-service/pull/126)) added `runner.isolation: privileged`, which runs the same Docker-in-Docker runner without the `sysbox-runc` RuntimeClass that immutable-rootfs nodes cannot install. Verified end to end on Talos: the AI Assistant generated a workflow, ran a Code node through the runner, and the runner reported back the cluster's own kernel version.

Not on a published Helm repository yet, so this pulls the chart directory directly:

```bash
git clone --depth 1 https://github.com/n8n-io/n8n-sandbox-service.git
cd n8n-sandbox-service
```

**1. Namespace, with the Pod Security Admission level the privileged runner needs.** A PSA denial lands on the runner's `StatefulSet` events, not on a pod - `kubectl get pods` shows nothing at all rather than a failure, so check there first if the runner never appears:

```bash
kubectl create namespace n8n-sandbox
kubectl label namespace n8n-sandbox pod-security.kubernetes.io/enforce=privileged
```

**2. A CA both the API and the runner trust.** `tls.mode: certManager` needs an `Issuer` to reference; a plain self-signed one gives every certificate its own root and the runner never completes registration. This is the three-object self-signed → CA certificate → CA issuer chain:

```yaml
# sandbox-ca.yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: sandbox-selfsigned
  namespace: n8n-sandbox
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: sandbox-ca
  namespace: n8n-sandbox
spec:
  isCA: true
  commonName: n8n-sandbox-ca
  secretName: sandbox-ca-tls
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: sandbox-selfsigned
    kind: Issuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: sandbox-ca
  namespace: n8n-sandbox
spec:
  ca:
    secretName: sandbox-ca-tls
```

```bash
kubectl apply -f sandbox-ca.yaml
```

**3. The chart itself**, with generated auth tokens (the chart refuses to render with the `changeme` placeholder or an empty value) and the two settings that make the runner actually usable on Talos:

```bash
API_KEY=$(openssl rand -base64 32 | tr -d '\n=' | tr '/+' '_-')
RUNNER_TOKEN=$(openssl rand -base64 32 | tr -d '\n=' | tr '/+' '_-')
RUNNER_API_KEY=$(openssl rand -base64 32 | tr -d '\n=' | tr '/+' '_-')

helm upgrade --install sandbox ./charts/n8n-sandbox-service \
  --namespace n8n-sandbox \
  --set auth.generated.apiKeys="$API_KEY" \
  --set auth.generated.runnerRegistrationToken="$RUNNER_TOKEN" \
  --set auth.generated.runnerApiKey="$RUNNER_API_KEY" \
  --set auth.generated.runnerApiKeys="$RUNNER_API_KEY" \
  --set tls.mode=certManager \
  --set tls.certManager.issuerRef.name=sandbox-ca \
  --set runner.isolation=privileged \
  --set runner.acknowledgePrivileged=true

kubectl -n n8n-sandbox rollout status statefulset -l app.kubernetes.io/name=n8n-sandbox-service
```

`$API_KEY` is the value the n8n side needs next - keep it. Release name `sandbox` against chart name `n8n-sandbox-service` is deliberate: the chart's fullname template drops the chart name whenever the chart name already contains the release name, so the API Service ends up named plain `sandbox-api` rather than something longer. `sandbox_release_name` in this example's `variables.tf` assumes exactly that; change one, change the other.

## Wiring n8n to the sandbox

n8n's own documentation currently names `N8N_INSTANCE_AI_SANDBOX_API_URL` and `N8N_INSTANCE_AI_SANDBOX_API_KEY`. **Neither string exists in any shipped build.** This example's `main.tf` already uses the names the code actually reads (`N8N_SANDBOX_SERVICE_URL`, `N8N_SANDBOX_SERVICE_API_KEY`); the Secret below just has to carry the right values under the right keys.

```bash
kubectl -n n8n create secret generic ai-assistant-secrets \
  --from-literal=model-api-key='sk-ant-...' \
  --from-literal=sandbox-api-key="$API_KEY"
```

`sandbox-api-key` must equal the `$API_KEY` the sandbox's `auth.generated.apiKeys` was set to above. Rotate one without the other and only code execution breaks - the editor and the assistant chat keep working, which reads as a sandbox outage rather than the credential mismatch it is.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set ui_host, and sandbox_namespace / sandbox_release_name
# if you named them anything other than the defaults above.

terraform init
terraform apply
```

## Verify

Infrastructure green is not the same as the feature working - finish with a real prompt in the browser, not just pod status:

```bash
# Sandbox API up
kubectl -n n8n-sandbox get pods

# Reachable from the n8n namespace
kubectl -n n8n run -it --rm curl --image=curlimages/curl --restart=Never -- \
  curl -s http://sandbox-api.n8n-sandbox.svc.cluster.local:8080/healthz
```

Then open `$(terraform output -raw n8n_url)`, open the AI Assistant, and ask it to run:

```
python3 -c "import platform,os;print(platform.platform());print(os.uname().nodename)"
```

A result naming your own node's kernel (for example `Linux-6.18.39-talos-x86_64-with-glibc2.36`) proves the code ran in your sandbox rather than nowhere at all. On first use the assistant uploads its template knowledge base into the sandbox - expect a burst of `mkdir` / file-write calls and a few benign `404`s before that finishes.

## Teardown

```bash
terraform destroy
helm -n n8n-sandbox uninstall sandbox
kubectl delete namespace n8n-sandbox
kubectl -n n8n delete secret ai-assistant-secrets
```

CNPG and Valkey PVCs are removed or retained according to their `StorageClass` reclaim policy, not by Terraform - see [`homelab`](../homelab/)'s teardown note.

## Production considerations

See [`homelab`](../homelab/)'s table first; it all still applies. Specific to the sandbox:

| Setting | Current | Production |
|---|---|---|
| `runner.isolation` | `privileged` | `sysbox`, on nodes where you can install it - a privileged-container escape reaches the node, sysbox's does not |
| Runner replicas | `1` (chart default) | More than one if code execution cannot tolerate the outage window while a runner pod restarts; each runner is a `StatefulSet` member, and a dead runner's in-flight sandboxes are lost |
| Model API key | plaintext in a Secret you created by hand | fine as-is if your cluster's Secrets are encrypted at rest; otherwise put it behind whatever secrets manager the rest of your cluster already uses |

<!-- The block below is auto-generated by terraform-docs. Run `terraform-docs markdown table --output-file README.md --output-mode inject .` to refresh it. -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
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
| <a name="input_ai_model"></a> [ai\_model](#input\_ai\_model) | Provider-qualified model the AI Assistant and Agents module call, e.g. "anthropic/claude-opus-4-8". n8n reads this verbatim and does not validate it against a model list, so a typo or a retired model surfaces as the assistant failing every request rather than as a plan-time or startup error. | `string` | `"anthropic/claude-opus-4-8"` | no |
| <a name="input_cluster_issuer"></a> [cluster\_issuer](#input\_cluster\_issuer) | cert-manager ClusterIssuer to use for the ingress TLS cert. | `string` | `"letsencrypt-prod"` | no |
| <a name="input_keda_installed"></a> [keda\_installed](#input\_keda\_installed) | Set true when the KEDA operator is already installed cluster-wide. Workers then scale on Redis queue depth rather than CPU, and the chart's CPU worker HPA is disabled so the two never both own the worker Deployment. Leave false if you are unsure: a ScaledObject with no operator behind it never reconciles and workers stay at their minimum replica count without anything failing. | `bool` | `false` | no |
| <a name="input_kubeconfig_path"></a> [kubeconfig\_path](#input\_kubeconfig\_path) | Path to kubeconfig used by the kubernetes, helm and kubectl providers (the kubectl one applies the CNPG Cluster CR). | `string` | `"~/.kube/config"` | no |
| <a name="input_metrics_lan_ip"></a> [metrics\_lan\_ip](#input\_metrics\_lan\_ip) | Address to publish the n8n main pod's /metrics endpoint on, for a Prometheus that runs outside the cluster and so cannot use in-cluster service discovery. Same allocator requirement as postgres\_lan\_ip. Leave null (the default) and no LoadBalancer Service is created; an in-cluster Prometheus or Alloy does not need this. | `string` | `null` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace to deploy into. Created by this example on every path rather than by the module, so that turning shared storage on later cannot move it between two resource addresses. An existing deployment upgrading to this needs one terraform state mv first, or the next apply plans to destroy the namespace; both commands are in storage.tf. | `string` | `"n8n"` | no |
| <a name="input_postgres_lan_ip"></a> [postgres\_lan\_ip](#input\_postgres\_lan\_ip) | Address to publish the CNPG rw endpoint on, for LAN clients that are not in the cluster - a Grafana instance querying n8n's execution tables, a DB client. Rendered as an io.cilium/lb-ipam-ips annotation, so it pins the address on Cilium LB-IPAM only; other allocators (MetalLB, kube-vip) ignore that key and will allocate an arbitrary address instead. To pin on those, call the module directly and use cnpg\_lan\_expose.annotations / metrics\_lan\_expose.annotations with the key your allocator honours. Leave null (the default) and no LoadBalancer Service is created. Postgres is exposed without a proxy in front of it, so only set this on a network you trust. | `string` | `null` | no |
| <a name="input_sandbox_namespace"></a> [sandbox\_namespace](#input\_sandbox\_namespace) | Namespace the n8n-sandbox-service Helm release runs in. This example does not create that release (see README) - it only builds N8N\_SANDBOX\_SERVICE\_URL from this and sandbox\_release\_name, so the value has to match wherever you actually installed it. | `string` | `"n8n-sandbox"` | no |
| <a name="input_sandbox_release_name"></a> [sandbox\_release\_name](#input\_sandbox\_release\_name) | Helm release name the n8n-sandbox-service chart was installed under. The chart derives its API Service name from this ("<release>-api" unless nameOverride collides with it, e.g. release "sandbox" against chart name "n8n-sandbox-service" renders plain "sandbox-api"), which is what N8N\_SANDBOX\_SERVICE\_URL has to name. Get this wrong and n8n reaches for a Service that does not exist: the assistant loads normally and every code execution request times out. | `string` | `"sandbox"` | no |
| <a name="input_shared_mount_path"></a> [shared\_mount\_path](#input\_shared\_mount\_path) | Where the shared volume is mounted in the n8n container on all three pod types. Binary data goes to `shared_mount_path`/storage. Kept out of /home/node/.n8n deliberately: the chart already mounts its own data volume there on main, and nesting one mount inside another is a way to lose track of which pod sees what. Note the task-runner sidecar does not get this mount; n8n\_extra\_volume\_mounts reaches the n8n container only. | `string` | `"/opt/n8n-shared"` | no |
| <a name="input_shared_storage_class"></a> [shared\_storage\_class](#input\_shared\_storage\_class) | An RWX-capable StorageClass for a volume shared across the main, worker and webhook-processor pods (NFS, SMB, CephFS, or whatever the cluster offers). Leave null and no claim is created, in which case binary data stays in Postgres, which is n8n's default in queue mode. Set it and binary data moves to the shared volume instead. Check the class can actually reclaim before trusting it: with the NFS CSI driver against an NFSv3-only appliance the PV is deleted while every byte stays on the server, which reads as automatic cleanup and is not. | `string` | `null` | no |
| <a name="input_shared_storage_size"></a> [shared\_storage\_size](#input\_shared\_storage\_size) | Size of the shared RWX claim. Only used when shared\_storage\_class is set. Binary data from every execution lands here, so size it against retention rather than against one workflow. | `string` | `"20Gi"` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass for the CNPG and Valkey PVCs. Empty uses whatever the cluster's default StorageClass is. | `string` | `""` | no |
| <a name="input_ui_host"></a> [ui\_host](#input\_ui\_host) | Hostname served by ingress. A DNS record for it has to reach the cluster's ingress controller, and creating that record is yours to do - this example manages no DNS, because how a name reaches a self-hosted cluster depends entirely on the setup (a tunnel, a public LoadBalancer, split-horizon DNS on the LAN, a reverse proxy). See examples/homelab-cloudflare for one worked version. | `string` | `"n8n.example.com"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_ai_assistant"></a> [ai\_assistant](#output\_ai\_assistant) | The model and sandbox URL n8n was wired to. Exists so sandbox\_namespace / sandbox\_release\_name typos surface as a visible plan/apply output instead of only as a code-execution timeout discovered in the browser; the value here is what N8N\_SANDBOX\_SERVICE\_URL and N8N\_INSTANCE\_AI\_MODEL actually render to, whatever this example's Helm release itself resolves to under a real apply. |
| <a name="output_backing_services"></a> [backing\_services](#output\_backing\_services) | Which backend provides Postgres and Redis for this deployment, and the in-cluster endpoints for each. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that points kubectl at the cluster this example deployed to. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once the ingress controller has published the host. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace the n8n release and its backing services were deployed into. |
<!-- END_TF_DOCS -->
