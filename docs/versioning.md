# Version currency policy

This module pins a lot of versions: the n8n chart and application image, the
Valkey chart, the CloudNativePG Postgres image, five Terraform providers (plus
two more carried only by DNS-provider examples), the Terraform CLI floor, and
the CI toolchain that gates every PR. Each pin was deliberate at the time it
was set, and each one can go stale the moment upstream ships a new release.
This doc is the inventory of every pin, where it lives, and the bump policy
for keeping it current on a cadence instead of waiting for a user to report a
version nobody re-checked.

It is the Kubernetes sibling of
[`terraform-aws-n8n/docs/versioning.md`](https://github.com/n8n-io/terraform-aws-n8n/blob/main/docs/versioning.md)
and keeps that doc's shape and tier names on purpose. The deltas below follow
from this module having no cloud account and no cluster of its own (see
AGENTS.md): there is no EKS/GKE/AKS version list to track, no managed
database engine, and no controller chart this module installs. KEDA,
cert-manager, ingress-nginx and the CloudNativePG operator are all
caller-owned (`docs/shared-responsibility.md`), so this module pins nothing
about any of them.

## Inventory

| Pin | Lives in | Tier |
| --- | --- | --- |
| `kubernetes` provider constraint | `versions.tf` (root, every `examples/*`, and `modules/cluster-capacity`: 9 files total) | Verification-required |
| `helm` provider constraint | `versions.tf` (root and every `examples/*`: 8 files; neither submodule declares `helm`) | Verification-required |
| `random` provider constraint | `versions.tf` (root and every `examples/*`: 8 files; the two submodules do not use `random`) | Patch-safe |
| `time` provider constraint | `versions.tf` (root and every `examples/*`: 8 files; `modules/cluster-capacity` does not use `time`, `modules/tls-letsencrypt` does not either) | Patch-safe |
| `kubectl` (`gavinbunney/kubectl`) provider constraint | `versions.tf` (root, every `examples/*`, and `modules/tls-letsencrypt`: 9 files total) | Verification-required (every custom resource this module applies itself goes through it: the CNPG `Cluster`, the `Pooler`, and the `ClusterIssuer` in `modules/tls-letsencrypt`; see AGENTS.md) |
| `cloudflare` provider constraint | `examples/homelab-cloudflare/versions.tf`, `examples/homelab-cloudflare-split-ingress/versions.tf` | Verification-required |
| `godaddy-dns` (`veksh/godaddy-dns`) provider constraint | `examples/homelab-godaddy/versions.tf` | Patch-safe |
| `required_version` (Terraform CLI floor) | 10 `versions.tf` files: root, every `examples/*`, both `modules/*` | Verification-required. Must stay equal to CI's `TF_VERSION` and `TF_FLOOR_VERSION` pins' floor and match across all ten files; see AGENTS.md ("The floor is `>= 1.11`") for the load-bearing reasons it moved from `>= 1.9`, and `tests/scripts/check-terraform-floor.sh` for the check that enforces it |
| `n8n_chart_version` default | `variables.tf` | Minor-required |
| `n8n_image_tag` default | `variables.tf` | Minor-required (it is the n8n *application* version, independent of the chart; see `docs/helm-chart-coverage.md`) |
| `valkey_chart_version` default | `variables.tf` | Minor-required |
| `cnpg_postgres_image_tag` default | `variables.tf` | Not a pin to bump: `"18-minimal-trixie"` is a floating major tag by design (the variable's own description), and `ghcr.io/cloudnative-pg/postgresql` republishes it against the newest `18.x` minor on every image build. See "What this policy deliberately does not force" |
| `TF_VERSION`, `TF_FLOOR_VERSION`, `TFLINT_VERSION`, `CHECKOV_VERSION`, `TERRAFORM_DOCS_VERSION` | `.github/workflows/terraform-tests.yml` | Verification-required (`CHECKOV_VERSION` doubles as the pin `tests/scripts/check-checkov.sh` enforces locally; `TF_FLOOR_VERSION` doubles as the pin `tests/scripts/check-terraform-floor.sh` enforces against every `required_version` above) |
| `docs/helm-chart-coverage.md`'s declared chart version | `docs/helm-chart-coverage.md` | Must equal `n8n_chart_version`'s default; checked by `tests/scripts/check-helm-chart-coverage.sh` (`task chart-coverage`), a local script this repo's CI does not run |

## Bump tiers

**Patch-safe.** A newer patch/minor release with no known breaking change and
no plan-time diff for existing deployments. Bump in the same PR as any other
change, or standalone with a one-line CHANGELOG entry. No re-verification
beyond the normal `task ci` loop (`terraform fmt`/`validate`/`test`, tflint,
banners, naming, docs, markdown) plus `task checkov`.

**Minor-required.** Moves a default that changes what `terraform apply`
deploys. A caller that never set the corresponding variable in their own
`module` block is not shielded by that omission: Terraform resolves the
variable to the module's new default on that caller's very next apply, with
no config change of their own. For `n8n_chart_version` or `n8n_image_tag`
that means an in-place `helm upgrade` that rolls the release's pods; for
`valkey_chart_version`, the same against the Valkey release when
`redis_backend = "valkey"`. This module is still pre-1.0, and the
[stability contract](../README.md#stability-and-versioning) treats a changed
default as a minor-version-boundary change regardless. Needs: a CHANGELOG
entry under **Changed** naming the old and new value and stating plainly
that unpinned callers move too, a `docs/helm-chart-coverage.md`
re-verification when it's the n8n chart (rendered with `terraform console`
and diffed against the chart's own `values.yaml` at the candidate tag; see
that doc's own history for the method), and a passing
`tests/scripts/check-n8n-chart.sh` when it's a chart this module templates
against.

**Verification-required.** A provider major, the Terraform CLI floor, or a CI
toolchain pin whose major version carries real breaking-change risk. These
are release-sized work in their own right. Needs, at minimum: the upstream
release's own upgrade guide read in full, a plan-time diff against every
affected resource, and a CHANGELOG entry. A `kubernetes` provider major is
the one most likely to rename or restructure a resource type this module
manages directly (the namespace, Secrets, the CNPG-adjacent
`kubernetes_secret_v1`/`kubernetes_config_map_v1` resources, the webhook HPA);
check first whether the provider supports a `moved` block across any
affected rename before renaming the resource type in source, the same
caution `terraform-aws-n8n/AGENTS.md` documents for its own
unversioned-to-`_v1` Kubernetes resource history.

## What this policy deliberately does not force

- **`cnpg_postgres_image_tag` staying a floating major tag.** The default,
  `"18-minimal-trixie"`, tracks upstream automatically: `ghcr.io` serves the
  newest `18.x` minor under that exact tag on every image rebuild, without
  any input change here. `tests/scripts/check-version-drift.sh` reports this
  pin as `OK` with the minor it currently resolves to for visibility, never
  as `DRIFT`, the same way `terraform-aws-n8n`'s own un-pinned EKS add-on
  versions are "nothing to bump" rather than drift. Pinning an exact minor
  (e.g. `"18.4-minimal-trixie"`) is this module's documented upgrade path for
  moving between Postgres majors (see the variable's own description); a
  deployment that has done that is outside what the automated check covers
  and needs a manual compare against `ghcr.io/cloudnative-pg/postgresql`'s
  own tag list.

- **Redis → Valkey is not a question this module revisits here.** The module
  already defaults `redis_backend` to Valkey and documents Redis OSS as the
  non-default `redis_backend = "redis"` path (see `redis_valkey.tf`'s header
  and the matching `postgres_lan.tf`-adjacent backend variables); there is no
  separate engine-family migration pending the way the AWS sibling's
  ElastiCache note describes, because this module never ran a Bitnami/Docker
  Hub Redis image to begin with.

## What the automated drift report cannot see

`tests/scripts/check-version-drift.sh` (run weekly by
`.github/workflows/version-drift.yml`, and on demand via `task
version-drift`) checks every pin reachable from a public API with no cloud
credentials and no cluster:

- The five root Terraform providers (`registry.terraform.io`), compared
  against each constraint rather than a single pinned version, using the
  same constraint grammar `tests/scripts/lib/constraints.sh` evaluates
  (`~>`, `>=`, `>`, `<=`, `<`, `!=`, `=`, or a bare version, comma-separated).
  A constraint that already admits the latest release is `OK`, not `DRIFT`.
  Only a constraint this evaluator cannot parse, or a latest release that is
  not a plain `X.Y.Z` version, is an explicit `ERROR`.
- The two example-only providers (`cloudflare`, `godaddy-dns`), same
  evaluator, read from the one example `versions.tf` each lives in.
- The CI toolchain (`hashicorp/terraform`, `terraform-linters/tflint` and
  `terraform-docs/terraform-docs` via GitHub releases; `checkov` via PyPI,
  since it is pinned as a pip version rather than a GitHub release tag).
- The n8n Helm chart, against its own `oci://ghcr.io/n8n-io/n8n-helm-chart`
  registry's anonymous tag list via a short-lived unauthenticated token and
  the Docker Distribution `tags/list` API. `ghcr.io` does expose a public,
  unauthenticated tag index. Only plain `X.Y.Z` tags count: the registry also
  carries prereleases (e.g. `1.17.0-preview.workerpools.1`) and non-version
  tags (`artifacthub.io`, `sha256-...` digests).
- The n8n application version (`n8n_image_tag`), against `n8n-io/n8n`'s own
  GitHub releases, filtered to the `n8n@X.Y.Z` tag family. That repository is
  a monorepo whose release tags also carry per-package prefixes
  (`@n8n/n8n-nodes-base@...`) and moving marker tags (`latest`, `beta`,
  `stable`) that jump onto whichever numbered release published most
  recently, so only the `n8n@` family is the core application's own version
  history. `n8n_image_tag = null` (delegate to the chart's own `appVersion`)
  is reported as an explanatory `OK`, since there is no pin to be behind.
- The Valkey chart, against `valkey-io/valkey-helm`'s own repository
  `index.yaml` (the Helm repository protocol, not OCI). That repository also
  serves `valkey-operator` and `valkey-resources` from the same index, so the
  check scopes its version scan to entries named `valkey` specifically.
- `cnpg_postgres_image_tag`, reported as `OK` with the minor it currently
  resolves to on `ghcr.io/cloudnative-pg/postgresql`, not compared against a
  single "latest" value (see "What this policy deliberately does not force").

Each pin is classified `DRIFT` (behind upstream, or a provider constraint
that no longer admits the latest release), `OK` (current, admits the latest
release, or a deliberately floating tag tracking upstream on its own), or
`ERROR` (the upstream lookup failed, or the script cannot evaluate the pin's
form), closing with a one-line summary count of pins behind upstream and
errors. The script exits 0 even when a lookup fails (it still exits 1 if
`curl`, `jq` or `python3` is missing): `.github/workflows/version-drift.yml`'s
only consumer of this output is an unguarded step with no `if: always()`
that syncs it to a single tracking issue, and a non-zero exit here would make
GitHub Actions skip that step entirely, silently stopping the tracking issue
from ever reflecting a run that hit a lookup failure. Every `ERROR` is
already visible in the synced report text, so a report, not a gate, is still
the right contract here.

It cannot see, and does not attempt to check, the one thing with no public
API at the granularity that matters here:

- **Whether a specific `cnpg_postgres_image_tag` minor, or a specific
  `n8n_image_tag`, is what you actually want running.** The report proves a
  version exists upstream, not that it is the right one to move to for a
  live deployment; read `docs/upgrading-n8n.md` and the chart's own release
  notes before pinning a newer value.

## Cadence

Review the weekly drift report every time it lands. A patch-safe pin behind
latest: bump it in the next PR that touches that file anyway, no separate
issue needed. A minor- or verification-required pin behind latest: open an
issue using this doc's tiers to scope the work.
