# Running n8n behind a TLS proxy

Two independent cases, which can be combined:

- **Outbound.** n8n's calls to the internet (workflow HTTP requests, the
  community-node registry, OAuth providers) pass through a TLS-inspecting
  egress proxy that re-signs certificates with a private CA.
- **Inbound.** A proxy, CDN or tunnel sits in front of the `Ingress` this
  module renders (or in front of the Service, with `create_ingress = false`)
  and terminates the client's TLS.

## Outbound: `n8n_extra_ca_pem`

```hcl
n8n_extra_ca_pem = file("${path.module}/proxy-ca.pem")

n8n_extra_env = [
  { name = "HTTPS_PROXY", value = "http://proxy.example.com:3128" },
  { name = "HTTP_PROXY", value = "http://proxy.example.com:3128" },
  { name = "NO_PROXY", value = ".svc,.cluster.local" },
]
```

The module stores the PEM in the Secret `n8n-ca-bundle-secret`, mounts it
read-only at `/etc/n8n-certs/ca-bundle.crt` on the main, worker and
webhook-processor pods, and sets `NODE_EXTRA_CA_CERTS` to that path. Node adds
the certificate(s) to its built-in roots; it does not replace them.

- Certificates only. A private key block is rejected at plan time, and so is
  a string that is not at least one well-formed PEM certificate.
- `NODE_EXTRA_CA_CERTS` is reserved against `n8n_extra_env` and
  `n8n_extra_env_from_secret` while the input is set, same for the
  `"ca-bundle"` volume name in `n8n_extra_volumes` and the
  `/etc/n8n-certs/ca-bundle.crt` mount path in `n8n_extra_volume_mounts`. All
  three are free again the moment `n8n_extra_ca_pem` goes back to `null`.
- Changing the PEM rolls every n8n pod through a `checksum/extra-ca` pod
  annotation, because Node reads the file once at start and a Secret update
  alone restarts nothing that reads it.
- The proxy variables (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`) stay in
  `n8n_extra_env`, which reaches the n8n containers on every role and not the
  task runner sidecar. They route HTTP(S) requests only; n8n's PostgreSQL and
  Redis connections are plain TCP (or TLS negotiated in-protocol, see
  `db_postgresdb_ssl_enabled`) and never go through them, so an in-cluster
  CloudNativePG or Valkey endpoint needs no `NO_PROXY` entry either way.
- `NO_PROXY` takes comma-separated hostnames, domain suffixes (a leading `.`),
  and exact IP addresses, each with an optional `:port`. It does not parse CIDR
  notation, so an entry such as `10.0.0.0/8` is inert. List every HTTP(S)
  destination that must bypass the proxy by hostname or exact IP, such as the
  cluster's own service domains (`.svc`, `.cluster.local`). The module only
  sets these environment variables: whether a given client honours them is up
  to the client, and Node's built-in HTTP stack does not read them on its own
  without a proxy agent configured in the workflow or node that makes the call.
- Credentials embedded in a proxy URL (`http://user:pass@proxy`) are stored in
  plaintext in Terraform state and the Helm release, like every other
  `n8n_extra_env` value. Prefer a proxy that authenticates the cluster by
  source address.
- If `n8n_network_policy_enabled = true`, the chart's `NetworkPolicy` already
  permits egress to port 443 from any destination, so a proxy listening on
  443 needs no change there; a proxy on another port needs
  `n8n_extra_helm_values` to widen the policy, the same escape hatch the OTLP
  collector guidance in `docs/helm-chart-coverage.md` uses.

### Task runner sidecar

The task runner sidecar is a separate container. It does not get
`NODE_EXTRA_CA_CERTS` and `n8n_extra_ca_pem` does not mount anything into it.
Code nodes that make their own TLS connections from inside the runner
therefore do not trust the private CA. Reaching the sidecar at all needs a
custom runner image (`n8n_task_runner_image_repository`) that carries the CA
in its own trust store; `n8n_extra_env` does not reach the sidecar either, so
there is no environment-variable route to it.

## Inbound: `n8n_proxy_hops`

`n8n_proxy_hops` (default `1`, the module's own `Ingress` controller) sets
`N8N_PROXY_HOPS` on every n8n pod. Count every proxy that adds an
`X-Forwarded-For` entry: a Cloudflare Tunnel, a CDN, a WAF or an outer reverse
proxy in front of the ingress controller each add one, so ingress-nginx
behind Cloudflare is `2`. Too low a value makes n8n attribute the client to
the nearest extra proxy instead of the real client; too high a value, or any
request that bypasses the declared proxy chain, lets the caller forge its
`X-Forwarded-For` address. A `check` block warns at plan time when an Ingress
is being rendered with `n8n_proxy_hops = 0`. See the
[`n8n_proxy_hops` input](../README.md#inputs) for the full description, and
`examples/homelab-split-ingress` / `examples/homelab-cloudflare-split-ingress`
for worked `create_ingress = false` configurations that count their own
chain.

The proxy's own TLS to the origin is configured elsewhere:

- With `create_ingress = true`, the Ingress TLS Secret comes from
  cert-manager via `k8s_ingress_cluster_issuer`; the proxy in front terminates
  the client's TLS and re-establishes its own to the ingress controller.
- With `create_ingress = false`, TLS termination in front of the Service this
  module exposes is entirely the caller's setup; see
  `examples/homelab-split-ingress` for one shape of it.

## Both

Set all three: `n8n_extra_ca_pem`, `n8n_extra_env` with the proxy variables,
and `n8n_proxy_hops`. None of the three depends on the others being set.
