# AI Assistant and Agents

n8n's AI Assistant and the Agents module are configured entirely through
environment variables, so this module needs no dedicated inputs for them: pass
the plain values through `n8n_extra_env` and the secrets through
`n8n_extra_env_from_secret`.

What the module does not do is run the code sandbox the assistant executes in.
That is a separate service with its own deployment, and it is a caller
prerequisite here in the same way an ingress controller or the CloudNativePG
operator is. See [Sandbox](#sandbox) below.

## Version floor

The Agents module needs n8n 2.32.3 or later. The AI Assistant itself works
earlier, but not every knob does: `INSTANCE_AI_BRAVE_SEARCH_API_KEY` is absent
from 2.31.6 and present in 2.34.6, for example.

Nothing warns you about this. Set a variable the running build does not read
and n8n starts normally, the feature simply never appears, and the version is
not named anywhere in the logs as the reason. Pin `n8n_image_tag` to a known
version rather than leaving the chart on its floating `stable` tag, so which
build you are on is a decision instead of a property of whichever node the pod
last started on.

To check a specific build for yourself, rather than trusting any table
including this one:

```bash
kubectl -n n8n exec deploy/n8n-main -c n8n-main -- \
  sh -c 'grep -rhoE "N8N_INSTANCE_AI[A-Z_]*|N8N_SANDBOX_SERVICE[A-Z_]*|INSTANCE_AI_BRAVE_SEARCH_API_KEY" \
    /usr/local/lib/node_modules/n8n | sort -u'
```

## Variables

Verified by the grep above against n8n 2.34.6. Note that n8n's own
documentation currently names `N8N_INSTANCE_AI_SANDBOX_API_URL` and
`N8N_INSTANCE_AI_SANDBOX_API_KEY` for the self-hosted sandbox; those strings
appear in no shipped build. The names below are the ones the code reads.

| Variable | Purpose |
| --- | --- |
| `N8N_ENABLED_MODULES` | Comma-separated. `instance-ai` for the assistant, `agents` for the Agents module. |
| `N8N_INSTANCE_AI_MODEL` | Provider-qualified model, e.g. `anthropic/claude-opus-4-8`. |
| `N8N_INSTANCE_AI_MODEL_API_KEY` | Key for that provider. **Secret.** |
| `N8N_INSTANCE_AI_SANDBOX_ENABLED` | `true` to let the assistant execute code. |
| `N8N_INSTANCE_AI_SANDBOX_PROVIDER` | `n8n-sandbox` (self-hosted) or `daytona`. |
| `N8N_SANDBOX_SERVICE_URL` | Sandbox API address, for the `n8n-sandbox` provider. |
| `N8N_SANDBOX_SERVICE_API_KEY` | Pre-shared key the sandbox API accepts. **Secret.** |
| `N8N_INSTANCE_AI_SEARXNG_URL` | SearXNG instance for web search. Needs `json` in its `search.formats`. |
| `INSTANCE_AI_BRAVE_SEARCH_API_KEY` | Brave Search key. **Secret.** No `N8N_` prefix, unlike every name above it. |

Web search is optional and either backend satisfies it. SearXNG keeps the
queries inside the cluster; Brave does not, and costs money.

## Wiring

The secrets go in a `Secret` you create yourself, in the same namespace as the
n8n pods. This module neither creates nor reads it, which is the point: no
value passes through Terraform, so none of it lands in the Helm release or in
state, and rotating a key is an edit plus a pod restart rather than an apply.

```bash
kubectl -n n8n create secret generic ai-assistant-secrets \
  --from-literal=model-api-key='...' \
  --from-literal=sandbox-api-key='...' \
  --from-literal=brave-api-key='...'
```

Then:

```hcl
module "n8n" {
  # ...

  n8n_extra_env = [
    { name = "N8N_ENABLED_MODULES", value = "instance-ai,agents" },
    { name = "N8N_INSTANCE_AI_MODEL", value = "anthropic/claude-opus-4-8" },
    { name = "N8N_INSTANCE_AI_SANDBOX_ENABLED", value = "true" },
    { name = "N8N_INSTANCE_AI_SANDBOX_PROVIDER", value = "n8n-sandbox" },
    { name = "N8N_SANDBOX_SERVICE_URL", value = "http://sandbox-api.n8n-sandbox.svc.cluster.local:8080" },
    { name = "N8N_INSTANCE_AI_SEARXNG_URL", value = "http://searxng.searxng.svc.cluster.local:8080" },
  ]

  n8n_extra_env_from_secret = [
    {
      name        = "N8N_INSTANCE_AI_MODEL_API_KEY"
      secret_name = "ai-assistant-secrets"
      secret_key  = "model-api-key"
    },
    {
      name        = "N8N_SANDBOX_SERVICE_API_KEY"
      secret_name = "ai-assistant-secrets"
      secret_key  = "sandbox-api-key"
    },
    {
      name        = "INSTANCE_AI_BRAVE_SEARCH_API_KEY"
      secret_name = "ai-assistant-secrets"
      secret_key  = "brave-api-key"
    },
  ]
}
```

Both inputs append to the chart's `config.extraEnv`. Do not reach for
`n8n_extra_helm_values` to set that list instead: Helm coalesces maps across
values documents but replaces lists, so an overlay setting `config.extraEnv`
substitutes its own for the module's entire one, taking `N8N_ENCRYPTION_KEY`
and every connection variable with it. The release installs cleanly and the
pods come up misconfigured.

A `secret_name` or `secret_key` that does not exist does not fail the apply.
Kubernetes resolves the reference when the container starts, long after Helm
has reported success, so the symptom is pods in `CreateContainerConfigError`.

## Sandbox

`N8N_INSTANCE_AI_SANDBOX_PROVIDER` takes two values:

- **`daytona`** points at Daytona's hosted service. Nothing to run, configured
  through `DAYTONA_API_URL` and `DAYTONA_API_KEY`, and your assistant's code
  execution leaves the cluster.
- **`n8n-sandbox`** points at
  [`n8n-io/n8n-sandbox-service`](https://github.com/n8n-io/n8n-sandbox-service)
  running in your own cluster.

The chart's default runner isolation is `sysbox`, under a `sysbox-runc`
RuntimeClass. Sysbox installs by writing to the host's containerd
configuration and restarting kubelet, targeting Ubuntu-style mutable
containerd config, which an immutable-rootfs distribution such as Talos,
Bottlerocket, Flatcar or Fedora CoreOS has no supported way to accept.

As of chart 0.4.0 (upstream
[n8n-io/n8n-sandbox-service#126](https://github.com/n8n-io/n8n-sandbox-service/pull/126))
`runner.isolation: privileged` is a first-class alternative: the same
Docker-in-Docker runner, running with `privileged: true` instead of under
sysbox, which any node can schedule. The render refuses to proceed until you
set `runner.acknowledgePrivileged = true`; an escape from the runner container
reaches the node, so the trade-off is intentionally not a silent default. This
superseded an earlier hand-rolled translation of the service's
`compose.yaml` topology into plain manifests, which existed only because
chart 0.3.x had no privileged option at all - the manifests are no longer
needed now that the chart covers the same case, and the chart's own
validation, TLS wiring and upgrade path beat maintaining a fork.

`examples/homelab-ai-assistant` works the full path end to end: the namespace's
required Pod Security Admission level, the cert-manager self-signed CA chain
`tls.mode: certManager` needs, and the exact `helm upgrade --install` this
example doesn't run for you (the chart is not published to a Helm repository
yet, so nothing in this repository can pin a version against it declaratively).

Whichever way it runs, the sandbox needs to be reachable from the n8n pods at
`N8N_SANDBOX_SERVICE_URL`. If the namespaces enforce `NetworkPolicy`, that path
has to be opened explicitly.
