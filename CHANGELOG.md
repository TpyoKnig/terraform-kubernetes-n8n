# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1-beta.1], First release

Initial public release of `terraform-kubernetes-n8n`: a single resource-bearing
root module that deploys [n8n](https://n8n.io) in queue mode onto a Kubernetes
cluster the caller already runs. The module's shape mirrors its
[`terraform-aws-n8n`](https://github.com/n8n-io/terraform-aws-n8n) sibling:
one root, `versions.tf`/`variables.tf`/`locals.tf`/`outputs.tf` plus one file
per concern, no nested `module` calls in the deployment path.

Where the cloud siblings provision a cluster *and* the workload, this one
cannot: "create a Kubernetes cluster" is not a resource any provider offers
generically. It owns the workload and its backing services, and treats the
cluster, ingress controller, cert-manager, CloudNativePG, KEDA, `StorageClass`
and DNS as caller prerequisites.

### Added

- **A single `terraform apply`** bringing up the namespace, Secrets,
  ServiceAccount, backing services and the n8n Helm release together: no
  separate infrastructure tier, and no cloud provider declared or required.
- **n8n in queue mode**, separate worker and webhook-processor pools, on the
  Community edition throughout, no licence is required or accepted.
- **CloudNativePG** for PostgreSQL (`postgres_backend = "cnpg"`), or an
  external endpoint. The operator generates the credentials into its own
  `<cluster>-app` Secret, so there is no password input on that path.
- **Valkey** for the Bull queue (`redis_backend = "valkey"`), or an external
  endpoint with optional TLS, auth token, username and timeout.
- **Multi-domain `Ingress`** with all five webhook path prefixes routed to the
  webhook processors, cert-manager TLS through a named `ClusterIssuer`, or
  `create_ingress = false` for caller-owned routing with the namespace, Service
  names, port and prefix list exposed as outputs.
- **Worker autoscaling on queue depth** via KEDA when `k8s_keda_installed`
  attests the operator is present, falling back to the chart's CPU HPA, plus
  main and webhook HPAs and an advisory cluster-capacity diagnostic.
- The n8n runtime, execution, lifecycle, task-runner, logging, pruning,
  community-package and external-secrets control surface, plus custom
  image/pull-secret/extra-volume/extra-env support and OpenTelemetry and
  metrics observability.
- **Optional off-cluster access** to the PostgreSQL read-write endpoint and the
  n8n metrics endpoint as `LoadBalancer` Services, off unless an address is
  named. Neither adds authentication.
- `examples/homelab`, `examples/homelab-cloudflare`, `examples/homelab-godaddy`
  and `examples/homelab-split-ingress`.
- `modules/cluster-capacity/` and `modules/tls-letsencrypt/` submodules.
- `docs/operations.md`, `docs/troubleshooting.md`, `docs/post-deployment.md`,
  `docs/upgrading-n8n.md`.

[0.0.1-beta.1]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.1
