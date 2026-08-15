# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1-beta.3]

Adds a fifth example, an output, and an opt-in shared-storage pattern to every
example. The module's only behavioural change is the new output, so an upgrade
from `0.0.1-beta.2` plans clean unless you opt into shared storage.

### Added

- `n8n_webhook_url` output: the base URL n8n advertises in every production
  webhook, form and MCP URL it generates. The module exposed `n8n_url`, the
  editor address, and nothing carrying `WEBHOOK_URL`, so a caller running the
  split-hostname topology had no way to assert the one value that defines it.
- `examples/homelab-cloudflare-split-ingress`: the split-hostname topology
  behind a Cloudflare Tunnel. One proxied CNAME per hostname, `proxy_hops`
  defaulting to 2 for the extra edge, both DNS and storage opt-in.
- Optional shared `ReadWriteMany` storage in all five examples, off by
  default. Queue mode runs main, worker and webhook-processor pods that share
  no filesystem, and the chart's own `data` volume is an `emptyDir` on main
  only, so anything one pod writes to local disk is invisible to the other
  two. Setting `shared_storage_class` creates one claim, mounts it into all
  three, and moves binary data onto it.
- `proxy_hops` input in both split-ingress examples. `N8N_PROXY_HOPS` was
  hardcoded to `"1"`, which is right behind ingress-nginx alone and wrong
  behind anything in front of it.

### Fixed

- Examples that set `shared_storage_class` could fail their first apply with
  `namespaces "..." not found`. Handing namespace creation to the example left
  the module's Secrets, CNPG `Cluster` and Valkey release with no dependency on
  it, so Terraform was free to schedule them first. The examples now pass the
  namespace resource attribute through `k8s_namespace`.
- `kubectl_config_command` in every example read `current-context` from
  `kubeconfig_path` and then set it in the *default* kubeconfig: a no-op when
  the two matched, and a switch to the wrong cluster when they did not. It now
  exports `KUBECONFIG`, quoted, with a leading `~/` rewritten to `$HOME/`.
- The hostname validation in both split-ingress examples accepted names with an
  empty label or a label ending in a hyphen. Both reach the `Ingress` host
  field and are rejected by the API server, so the failure surfaced on apply
  rather than at plan.
- `k8s_ingress_host` was set in both split-ingress examples where it does
  nothing: every consumer of it is gated on `create_ingress`.
- The README pointed OpenTofu users at the registry address. OpenTofu resolves
  modules against a separate index this module is not published to, so the
  short form fails with `Module not found`. Usage now gives the git source.
- `editor_ingress_extra_annotations` claimed an IP allowlist is meaningful only
  on a path that reaches nginx directly. With `use-forwarded-headers` and
  `compute-full-forwarded-for` it works through a tunnel too.

### Changed

- `openspec/` and `reports/` are no longer tracked. Neither was ever published,
  and the comment claiming release tags excluded them described an exclusion
  nothing implemented.
- `AGENTS.md` states the commit-message convention, aligned with
  `CONTRIBUTING.md`.

## [0.0.1-beta.2]

Documentation only. No inputs, outputs, resources or defaults changed, so an
upgrade from `0.0.1-beta.1` plans clean.

### Fixed

- The Helm cache workaround in `docs/troubleshooting.md` told readers to add a
  chart repository that no longer exists, was never the repository this module
  pulls from, and could not have been added that way regardless: the n8n chart
  is an OCI reference, which resolves directly rather than through an
  `index.yaml`. The step is now keyed on the repository scheme, so it stays
  correct whichever way `n8n_chart_repository` and `valkey_chart_repository`
  are pointed.
- `n8n_chart_repository` suggested mirroring to "an ECR OCI repository in this
  account". There is no cloud account anywhere in this module.
- The smoke-test summary in `tests/scripts/README.md` claimed `/healthz` is
  checked over an ALB. It goes through the `Ingress`.
- The bug-report template asked reporters for a version "e.g. `0.1.0`", a tag
  that belonged to the AWS module this one was forked from and no longer
  exists.

### Changed

- The community-project warning is now the first thing in the README rather
  than half a sentence inside a paragraph about module shape. The module is
  listed on the public registry one search result away from `n8n-io/n8n/aws`,
  under a name built from the same three words, and the registry renders the
  README and nothing else. The warning names that module and points AWS users
  at it.

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

[0.0.1-beta.3]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.3
[0.0.1-beta.2]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.2
[0.0.1-beta.1]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.1
