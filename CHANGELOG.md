# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1-beta.4]

The AI Assistant round. Adds an input for secret-backed environment variables
and an output naming the OAuth2 redirect URI, and fixes a split ingress
labelling the editor with the webhook hostname, which broke every OAuth
credential on that topology.

Upgrading from `0.0.1-beta.3` plans clean on a single hostname. On a split
ingress it replans the n8n release: `WEBHOOK_URL` and `N8N_EDITOR_BASE_URL`
move out of the chart's ConfigMap and into `config.extraEnv`, and the second of
those changes value. The pods restart. No data is touched and no output changes
on any path.

### Added

- `n8n_oauth_callback_url` output: the redirect URI to register with any OAuth2
  provider a credential will use. n8n builds it from `N8N_EDITOR_BASE_URL`, so
  on a split ingress it sits on the editor hostname and never the webhook one,
  which is not derivable from the other outputs and is the thing that was wrong
  in the release before this one. Re-exported by both split-ingress examples,
  which now assert it lands on `editor_host` and refuse it on `webhook_host` -
  the regression guard that could not exist while nothing exposed the value.

- `n8n_extra_env_from_secret` input: environment variables for the n8n pods
  sourced from keys of existing Kubernetes Secrets, rendered as
  `valueFrom.secretKeyRef` entries. `n8n_extra_env` is typed as name/value
  pairs, so every secret a caller needed to pass had to go through it in
  plaintext, landing in the Helm release and in Terraform state. The documented
  alternative was an `n8n_extra_helm_values` overlay, which does not work for
  this: Helm coalesces maps across values documents but replaces lists, so an
  overlay setting `config.extraEnv` substitutes its own list for the module's
  entire one, dropping `N8N_ENCRYPTION_KEY` and every connection variable. The
  release still installs and the pods come up misconfigured. The new input
  appends instead, and rejects module-managed names and names already set in
  `n8n_extra_env`.

### Fixed

- `N8N_ENDPOINT_*` is now reserved. The module hardcodes the path segments n8n
  serves and then publishes them: `n8n_webhook_path_prefixes` lists `/webhook`,
  `/webhook-waiting`, `/form`, `/form-waiting` and `/mcp`, the examples route
  exactly those five on the webhook Ingress, and `n8n_oauth_callback_url`
  spells `/rest` into the redirect URI. Each of those segments is an
  `N8N_ENDPOINT_` variable, and repointing one through `n8n_extra_env` left the
  Ingress routing the old segment and the outputs advertising it while n8n
  answered on the new one, with the module reporting both as correct.

- `examples/homelab-cloudflare-split-ingress` had no `.terraform-docs.yml`, so
  `terraform-docs --output-check` there printed its help text and exited 0. The
  example was enumerated in the Taskfile and in CI all along; the check simply
  could not fail, so that README was never actually verified against the code.

- `n8n_extra_env_from_secret` accepted Secret names the API server rejects.
  The `secret_name` check matched one `[a-z0-9.-]` character class, which
  admits `a..b` and `a-.b`, so the guard passed exactly the malformed names it
  exists to catch and the pod stuck in `CreateContainerConfigError` long after
  Helm reported success. Now matched label by label, with the 253-character
  limit.

- `N8N_EDITOR_BASE_URL` named the webhook host on a split ingress, breaking
  every OAuth2 credential. Chart 1.10.0 derives that variable from the first
  ingress host and, failing that, from `webhook.url`, on the stated assumption
  that "webhook.url is the domain". With `create_ingress = false` the chart has
  no ingress host to read, so it labelled the editor with the webhook
  hostname. Nothing warned: the editor still loaded, and webhook delivery still
  worked. What broke was every absolute URL n8n builds from
  `getInstanceBaseUrl()`, which prefers `N8N_EDITOR_BASE_URL` over
  `WEBHOOK_URL` - above all the OAuth2 redirect URI,
  `<editor base>/rest/oauth2-credential/callback`. Sent to the webhook host it
  404s twice over: a split ingress routes only the webhook prefixes there, and
  the webhook processor serves no `/rest` routes even when reached. So
  connecting any OAuth credential failed at the provider's callback while
  everything else kept working, which points the search at the wrong half.

  The module now empties the chart's `webhook.url` on that path, which
  suppresses both chart keys and their `configMapKeyRef` entries, and sets
  `WEBHOOK_URL` and `N8N_EDITOR_BASE_URL` from `config.extraEnv` instead.
  Overriding in place was not an option: a second entry of the same name in a
  container's env list fails the strategic merge patch on the next `helm
  upgrade` and leaves the release stuck in `failed`.

  Affects `homelab-split-ingress` and `homelab-cloudflare-split-ingress`.
  Single-host deployments are untouched, and the `n8n_webhook_url` output is
  unchanged on every path.

### Changed

- `n8n_extra_helm_values` description corrected. It claimed `valueFrom`-shaped
  environment entries were its most useful application, which was the one
  thing it could not safely do.

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

[Unreleased]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/compare/0.0.1-beta.4...HEAD
[0.0.1-beta.4]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.4
[0.0.1-beta.3]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.3
[0.0.1-beta.2]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.2
[0.0.1-beta.1]: https://github.com/TpyoKnig/terraform-kubernetes-n8n/releases/tag/0.0.1-beta.1
