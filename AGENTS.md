# AGENTS.md

Guidance for AI coding agents (Claude Code, Cursor, Copilot, etc.) working in
this repository. Human contributors should also find this useful - it explains
*what* this module is and *what bar* it is held to.

This file is the Kubernetes sibling of
[`terraform-aws-n8n/AGENTS.md`](https://github.com/n8n-io/terraform-aws-n8n/blob/main/AGENTS.md).
The shape, quality bar, and "what not to do" list are intentionally aligned;
the deltas below cover what changes when the target is a cluster the module
does not own.

## What this repo is

`terraform-kubernetes-n8n` deploys [n8n](https://n8n.io) onto a **Kubernetes
cluster the caller already runs**. A single `terraform apply` brings up the
workload and its backing services; no cloud account is involved and no cloud
provider is declared.

The module deploys **Community-edition n8n only**. There is no licence input,
the rendered chart values carry no `license` or `multiMain` block, and no
`N8N_LICENSE_*` variable reaches the pods. Queue mode - separate worker and
webhook-processor pools - is a Community feature and is what does the scaling.
`n8n-main` is therefore always a single replica with its HPA off: leader
election among mains is the licensed piece.

### The ownership boundary, and why it sits here

The cloud siblings provision a cluster *and* the workload on it. This module
cannot: "create a Kubernetes cluster" is not a resource any provider offers
generically, because the answer differs for Talos, kubeadm, k3s, and every
managed offering. So this module is workload-and-backing-services only, and
that is a permanent design property rather than a gap to close.

**The module owns:** namespace, Secrets, the n8n Helm release and its values,
the CloudNativePG `Cluster` and the Valkey release when selected, the `Ingress`
when asked, the worker `ScaledObject` when KEDA is attested, the task-runner
`ConfigMap`, and two optional `LoadBalancer` Services.

**The caller owns:** the cluster, ingress controller, cert-manager and its
`ClusterIssuer`, the CloudNativePG operator, KEDA, a default `StorageClass`,
metrics-server, and DNS.

The rule behind that split is ownership, not convenience. Each caller-owned
item is a cluster-wide singleton serving every workload on the cluster. A
module that installed one would take responsibility for upgrading and
destroying it on behalf of workloads it cannot see.

### Architecture at a glance

```text
                    caller publishes the hostname
                              |
                              v
   user --> ingress controller --> n8n main pods --> CloudNativePG (Postgres)
                     |                    |
                     |                    +--> Valkey (queue) <-- workers (KEDA-scaled)
                     |
                     +------> n8n webhook processors
```

### File layout

| File / dir | Purpose |
| --- | --- |
| `versions.tf` | `required_version` + `required_providers` only. |
| `variables.tf` | All inputs, with `description`, `type`, and `validation`. |
| `outputs.tf` | All outputs, with `description` and `sensitive` where needed. |
| `locals.tf` | Shared locals, and the chart values tree (`local.k8s_values_*`) assembled into `local.k8s_values_final`. |
| `n8n.tf` | Encryption key, namespace, Secrets, ServiceAccount, the Helm release, and the workload-level `check` blocks. |
| `postgres_cnpg.tf` / `redis_valkey.tf` | The two in-cluster backing services, each `count`-gated on its backend enum. |
| `postgres_lan.tf` / `metrics_lan.tf` | Optional `LoadBalancer` Services, off unless an address is named. |
| `task_runners_config.tf` | The task-runner launcher `ConfigMap`. |
| `scaling.tf` | Worker autoscaling and the CPU demand model. |
| `modules/cluster-capacity/` | Reads the cluster's allocatable CPU and warns when demand exceeds it. A submodule because Terraform rejects `count` inside a check block's nested data block. |
| `modules/tls-letsencrypt/` | A Let's Encrypt `ClusterIssuer` for cert-manager. A submodule because a `ClusterIssuer` is cluster-scoped and shared, so the root must not own one per deployment. |
| `examples/homelab*/` | Four topology examples, one per DNS and ingress strategy. Each carries its own README, generated reference block and mocked test suite. |

### Deltas worth knowing

1. **Custom resources go through `gavinbunney/kubectl`, never
   `hashicorp/kubernetes_manifest`.** `kubernetes_manifest` resolves a
   resource's schema against a live cluster API at *plan* time, so
   `terraform plan` fails outright wherever the API is unreachable - CI, a
   laptop off the network, any review not sitting on the cluster - and it
   reverts a mutating webhook's own defaults unless every injected subtree is
   enumerated in `computed_fields`, an allowlist that has to be maintained
   against every operator release. `kubectl_manifest` defers schema resolution
   to apply time and, with `server_side_apply = true`, leaves the operator as
   field manager for everything the manifest does not set.

   Treat this as the default for **any** custom resource, not only CRDs
   installed in the same apply - the plan-time API dependency is the broader
   problem, and it is the one that breaks CI.

2. **Cluster-wide operators are attested, never detected.** `k8s_keda_installed`
   is an input rather than a data source lookup, because a refresh-time read
   makes the dependent branch unknown at plan time and defeats the mocked
   suite. It defaults to `false`: a `ScaledObject` with no operator behind it
   never reconciles and pins workers at their floor without failing anything.

3. **The capacity diagnostic reads the cluster, and must stay removable.** The
   node read is an ordinary data source in `modules/cluster-capacity`, *not*
   nested inside the `check` block. Nesting gives error-masking for free but
   makes `depends_on` on this module a dependency cycle for any caller
   resource, because checks execute after every resource. The cost is that a
   failed read fails the plan, so `k8s_capacity_check_enabled` removes the read
   entirely.

4. **Every declared input must reach the workload.** The module previously
   accepted, validated and documented twelve inputs that reached nothing on
   this platform. An input that is silently discarded is worse than one that is
   not offered, so new workload inputs get a test asserting them against the
   rendered values tree.

5. **No DNS, and no default DNS strategy.** How a name reaches a self-hosted
   cluster has no portable answer. A worked strategy belongs in its own example
   root, never in the module.

## Quality bar: HashiCorp Terraform Registry & Partner Premier Tier

This module targets the quality criteria HashiCorp publishes for partner
modules in the Terraform Registry, specifically the
[Partner Premier Tier](https://www.hashicorp.com/en/blog/announcing-the-new-partner-premier-tier-for-the-terraform-registry)
and the broader [Terraform partnerships
guidelines](https://developer.hashicorp.com/terraform/docs/partnerships).

> Module quality is ensured through a varied set of standards focused on
> HashiCorp-defined, best-in-class infrastructure as code principles. This
> includes:
>
> - Successfully passing TFLint, Checkov, or another static code analysis tool
>   and reporting the result to HashiCorp
> - Traditional unit and integration testing via Terraform test
> - Adherence to Terraform's official naming conventions
> - Clear module documentation
> - Inclusion of all standard module files

Concretely, in this repo:

### 1. Static analysis (TFLint + Checkov)

`.github/workflows/terraform-tests.yml` runs both on every PR and push to `main`:

- **`terraform fmt -check -recursive`** - canonical formatting.
- **`terraform validate`** against the module root, both submodules
  (`modules/cluster-capacity/`, `modules/tls-letsencrypt/`) and every example
  (`examples/homelab/`, `examples/homelab-cloudflare/`,
  `examples/homelab-godaddy/`, `examples/homelab-split-ingress/`) via the CI
  matrix.
- **`tflint`** against the module root, every example and both submodules, all
  reading the single root `.tflint.hcl` through `TFLINT_CONFIG_FILE`. That
  config is what enables the `terraform` ruleset at `preset = "recommended"`;
  without it tflint falls back to a small built-in default set, and a job named
  `tflint (examples/homelab)` reports green having checked far less than the
  name implies. There is no provider ruleset to add, neither `kubernetes` nor
  `helm` publishes a tflint plugin, so the Terraform preset is the whole
  ruleset available here.
- **`checkov`** against the Terraform framework, at the version pinned in
  `CHECKOV_VERSION`. CI runs `tests/scripts/check-checkov.sh`, the same script
  you run locally, and that script refuses to run against a different checkov
  version, because results are not comparable across versions. Findings hard-fail the
  build: every one is either fixed or annotated at its resource with an inline
  `checkov:skip=<ID>:<reason>`, and `.checkov.yaml` suppresses no check
  repo-wide. The current baseline is **12 passed, 0 failed, 0 skipped**, with no
  `checkov:skip` anywhere: so any annotation you add is the first, and a drop
  in the passed count means checks stopped applying, not that the module got
  safer. Scope is the Terraform framework only, and `.checkov.yaml` explains
  why: the workload is a Helm release, and checkov's Kubernetes checks read
  rendered manifests this gate never produces. **When you add new resources, do
  not regress curated findings; prefer fixing them over adding suppressions, and
  when a suppression is genuinely right, say why at the resource.**

### 2. Unit + integration tests via `terraform test`

- `tests/defaults.tftest.hcl` is the canonical plan-time test suite.
  It mocks every provider (`kubernetes`, `helm`, `kubectl`, `random`, `time`),
  so it runs with no cluster, no credentials and no network, and is safe in CI.
- `mock_provider` is file-scoped, and a mocked value can only hold one shape per
  file. Put a run in its own file when it needs a different mocked shape rather
  than widening the shared mock, which silently weakens every other run reading
  the same attribute.
- Each example has its own `tests/defaults.tftest.hcl` exercising it end-to-end
  with the same mocking strategy, catching wiring mistakes between the module
  and a realistic caller.
- `modules/cluster-capacity/tests/capacity.tftest.hcl` lives with the submodule
  because `expect_failures` cannot name a check inside a child module.
- `tests/scripts/smoke-test.sh` is the **integration / post-apply** check used
  against a real cluster, kept out of CI on purpose (it needs a live cluster
  and an applied stack). It asserts what a plan cannot: that the CloudNativePG
  cluster reconciled, the queue is reachable, and the `Ingress` has an address.
- `tests/scripts/verify-custom-image.sh` is the same tier, narrowed to
  deployments that bake community packages into a custom image. Plan-time tests
  cannot reach what it checks: whether n8n *loaded* the baked nodes, and whether
  it loaded them on workers as well as mains. A deployment can pass every other
  check and still fail only when a production execution hits the node.

When you add a feature, add an `assert` for it in the relevant `.tftest.hcl`
file. Use `command = plan` unless you specifically need apply semantics.

#### Known mock provider limitations

- **`helm_release.values` is unknown at plan time.** The `values` argument is
  a locally-computed `yamlencode()` block, but because it belongs to a
  resource that depends on `kubernetes_namespace` (whose attributes are
  `(known after apply)` under the mock provider), the whole resource, including its inputs, is deferred. You cannot assert on Helm values
  content in `command = plan` tests.
- **Mocks do not enforce dependency ordering or server-side preconditions.**
  The mock `kubernetes` provider will happily "create" a namespaced resource
  whose namespace does not exist, so a missing dependency edge passes every
  plan-time assert and then fails on a real apply with
  `namespaces "n8n" not found`. This is not hypothetical: `output "namespace"`
  once returned `var.k8s_namespace`, a plan-time constant, which left callers'
  `kubernetes_*` resources with no edge to `kubernetes_namespace.n8n`. The full
  suite was green and the first live apply failed. Whenever an output is
  intended to order a caller's resources, return the **resource attribute**
  rather than the variable, and treat "did the graph actually serialise these"
  as a question only a live apply answers.
- **A `run` block cannot express "argument passed as `null`".** In a `variables`
  block, `x = null` means *unset*: the variable takes its default and no error is
  raised. A real caller writing `x = null` in a `module` block is different:
  null **propagates into the module** rather than falling back to the default,
  unless the variable declares `nullable = false`. Measured on 1.9.8 (before the
  floor moved; the behaviour is unchanged since), one module
  with `default = 6` invoked three ways: no argument sees `6`; `n = null` on a
  nullable variable sees `null`; `n = null` on a `nullable = false` variable sees
  `6`, silently, with no error. Only the middle case can break anything, and it
  is the only one a `run` block cannot reproduce.

  This is not academic. It is how the `nullable = false` gap on the autoscaling
  inputs was found (see `scaling.tf`): Terraform evaluates a `check` block's
  `error_message` alongside its condition rather than lazily on failure, so a
  propagated null reached the message's interpolations and aborted the plan with
  `Invalid template interpolation value`, from a block whose entire purpose is
  to warn *without* failing. `expect_failures` cannot assert it; the attempt
  fails with "Missing expected failure".

  So: for any input with a default where null is not meaningful, declare
  `nullable = false` rather than trusting a test to catch it. Null-handling is a
  question only a real `module` block answers, which means a live plan against a
  caller configuration rather than the mocked suite.

#### Write guard-style `check` conditions as `guard ? body : true`

```hcl
# Preferred.
condition = var.create_database ? (var.db_host == null && var.db_password == null) : true

# Avoid.
condition = !var.create_database || (var.db_host == null && var.db_password == null)
```

Both forms behave identically on the versions this module now supports, so
this is a consistency rule rather than a correctness one, and the existing
`check` blocks all use the first form. Keep matching them: nest rather than
chaining `||` inside the body.

It used to be a correctness rule, and the history is worth knowing before
anyone "simplifies" one of these back. `required_version` was `>= 1.9` and CI
pinned 1.9.8. Short-circuit evaluation of `&&` and `||` arrived in Terraform
1.10, so on 1.9 both operands were always evaluated, making
`known_true || unknown` *unknown*, and a `check` whose condition is unknown at
plan fails `terraform test` with "Check block assertion known after apply".
The `!guard || body` shape therefore broke whenever the right side read an
input a caller wired from a resource attribute. Worse, any local Terraform
newer than 1.9 short-circuited and passed, so the whole class of bug was
invisible locally and only ever failed in CI.

The floor is now `>= 1.11` (every `versions.tf`, and CI's `TF_VERSION`), which
is above the 1.10 that fixed it, so the hazard is retired. It is written down
because "this reads more naturally as `!guard || body`" is a reasonable
instinct that was, for a long stretch of this repo's history, wrong.

#### The floor is `>= 1.11`

Declared as `required_version = ">= 1.11"` everywhere: root, both submodules and
all four examples, each in its own `versions.tf`. Matched by CI's single
`TF_VERSION` pin either way. It moved up from
`>= 1.9` because `override_resource`'s `override_during` attribute, which
Some runs need to assert a plan-time value
on a resource the same configuration creates, arrived in 1.11
(hashicorp/terraform#36227) and is silently ignored before it. A silently
ignored override does not error; it turns the documented `terraform test`
command into a confusing assertion failure, which is the worst way to learn
about a version constraint.

Keep all seven declarations and the CI pin in step when bumping. A floor the
CI does not exercise is a claim nobody is checking.

**Recommended pattern** when end-to-end wiring cannot be tested under mocks:

1. Write `command = plan` assertions at the variable contract level (default
   value, type acceptance, validator rejection).
2. Add a comment in the test file explaining *why* the wiring cannot be
   asserted and *how* to verify it manually (e.g. "run a real `terraform
   plan` from the Terraform Cloud workspace").
3. Do not reach for `command = apply` to work around plan-time unknowns -
   the ARN validation failures produce worse noise than the coverage gap.

### 3. Naming conventions

This module follows the [Terraform module
conventions](https://developer.hashicorp.com/terraform/language/modules/develop/structure):

- Repository name is **`terraform-<PROVIDER>-<NAME>`** → `terraform-kubernetes-n8n`.
- Resource names use **`snake_case`**. The "main" resource of a kind in this
  module is named `n8n` (e.g. `helm_release.n8n`, `kubernetes_secret.n8n`):
  this matches the registry convention of
  using a short, descriptive label rather than repeating the resource type.
- Variables and outputs use **`snake_case`** with a leading noun
  (`n8n_domain`, `n8n_webhook_url`, `k8s_ingress_class_name`).
- Every variable has a `description` and a `type`. Most have a `validation`
  block that fails fast with a useful error message, preserve this when
  adding new inputs.
- Every output has a `description`. Outputs containing secrets are marked
  `sensitive = true`.

### 4. Clear documentation

- `README.md` is the entry point. The `## Reference` section between
  `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` is **auto-generated**:
  do not hand-edit it. All rendering options (formatter, output template,
  `lockfile: false` to keep providers shown as constraints) live in
  `.terraform-docs.yml`, so refreshing the README is one command:

  ```bash
  brew install terraform-docs   # or: see the install step in .github/workflows/terraform-tests.yml
  terraform-docs .
  ```

  CI installs the same version (`v0.24.0`, tracking the brew default) and
  runs `terraform-docs --output-check .`, see the `docs` job in
  `.github/workflows/terraform-tests.yml`. If your local version differs
  from CI's, the markdown table whitespace will drift and the check will
  fail; bump both together when upgrading.

- Each example has its own `README.md` documenting the runnable example.
- `docs/operations.md`, `docs/troubleshooting.md`, `docs/post-deployment.md`
  `docs/upgrading-n8n.md`, `docs/module-contract.md` and
  `docs/helm-chart-coverage.md` cover operator-facing concerns that don't belong
  inline in `README.md`. That is the whole set, if you reference a `docs/`
  file, it exists here or the link is dead.
- Inline comments in `.tf` files use the `# ── Section ──` banner style. Every
  `variable`/`output` block lives under one of these banners.
  `scripts/check-variable-banners.sh` (`task banners`, local-only for now:
  not yet wired into CI) fails if a block has no banner above it, or if a
  banner comment doesn't match the `# ── Name ──...──` format.

  **`variables.tf` banners, in file order:**

  | Banner | Covers |
  |---|---|
  | `Common` | Naming threaded through every resource (`namespace`) |
  | `Core inputs` | Hostname, additional domains, webhook URL, encryption key |
  | `Cluster` | Namespace creation |
  | `Ingress` | Ingress class, host, issuer, TLS secret, annotations, and the raw-values escape hatch |
  | `Chart repositories` | The `*_chart_repository` overrides, one per chart the module installs |
  | `Chart versions` | The `*_chart_version` pins, plus n8n image tag/repository/pull secrets, Helm timeout, timezone and logging |
  | `n8n resource requests and limits` | CPU/memory requests and limits, one set per pod role |
  | `Execution settings` | Worker concurrency, execution timeouts, pruning, execution-data storage mode |
  | `Graceful shutdown` | Termination grace period, prestop sleep |
  | `Task runners` | Task runner sizing, lifecycle and the import allowlists |
  | `PostgreSQL` | `postgres_backend`, the CloudNativePG sizing inputs, and the external-database references |
  | `Redis / queue` | `redis_backend`, the Valkey sizing inputs, and the external-Redis references |
  | `HPA: main pods` / `HPA: webhook processor pods` | CPU-based autoscaling |
  | `Observability` | Metrics/telemetry toggles |
  | `Community packages` | Custom-node loading, OTEL export, the `n8n_extra_env` escape hatch |
  | `Sidecars` | `extraContainers` and `extraInitContainers` on the n8n pods |
  | `External Secrets` | External Secrets Operator integration |
  | `KEDA: worker pods` | Queue-depth autoscaling |

  `scripts/check-variable-banners.sh` hardcodes this same list, in this same
  order, and fails if `variables.tf` disagrees with it. Update the table and
  the script together, or the check goes red on an untouched checkout.

  `outputs.tf` banners: `App DNS`, `Secrets`, `Infrastructure`.

  When adding a variable, file it under the banner matching what it
  *configures*, not which feature or PR introduced it. A new OTEL sampling
  knob belongs in `Community packages`, next to the other OTEL vars, not a new
  one-off banner. Only add a new banner when a variable's theme doesn't fit
  any existing section, the way `Common` didn't fit `Foundation inputs` (see
  #81). Match the banner's dash-padding to its neighbors, copy an existing
  banner line and rename it rather than typing dashes by hand.

### 5. Standard module files

All of the following are present and should stay present:

- `README.md`, `LICENSE`, `versions.tf`, `variables.tf`, `outputs.tf`
- `examples/` with at least one runnable example
- `tests/` with at least one `.tftest.hcl` suite
- `.github/workflows/` with the CI pipeline above

## How to work in this repo (agent quick reference)

### Vendored agent skills

`.agents/skills/` contains two skills vendored from
[hashicorp/agent-skills](https://github.com/hashicorp/agent-skills) via the
[skills CLI](https://skills.sh) and pinned by `skills-lock.json`:
`terraform-style-guide` and `terraform-test`. Agents that read
`.agents/skills/` (pi does natively; Claude Code via the git-ignored
`.claude/skills/` symlinks) load them automatically. The symlinks are not
committed; Claude Code users create them once per clone:

```bash
mkdir -p .claude/skills
ln -sf ../../.agents/skills/terraform-style-guide \
       ../../.agents/skills/terraform-test .claude/skills/
```

Do not hand-edit the vendored files; update them with `skills update -p`.
Where a skill's generic guidance
conflicts with this repo's conventions (e.g. the style guide's `terraform.tf`
vs this repo's `versions.tf`, or its Terraform version floor), **this
`AGENTS.md` and the existing repo layout win**.

### Local development loop

`task ci` (see [`Taskfile.yml`](./Taskfile.yml), requires
[`task`](https://taskfile.dev)) runs the full loop below across the module
root and every example in one command. The raw commands work identically
without `task` installed:

```bash
# The veksh/godaddy-dns provider requires credentials even in plan-time tests.
# Export stubs once per shell session before running terraform test.
export GODADDY_API_KEY=stub GODADDY_API_SECRET=stub

terraform fmt -recursive                       # before committing
terraform init -backend=false                  # at module root
terraform validate
terraform test -verbose                        # plan-time, no cluster needed
tflint --init && tflint --format compact
terraform-docs --output-check .                # README drift check

# Repeat under each example and each submodule. This list mirrors the CI matrix
# (the `target:` lists in .github/workflows/terraform-tests.yml) and
# Taskfile.yml's EXAMPLES + SUBMODULES vars, so a green local run means CI will
# be green too. Keep all three in sync when adding a root: one that no local
# wrapper visits is one nobody validates before pushing.
for dir in examples/homelab \
           examples/homelab-cloudflare \
           examples/homelab-godaddy \
           examples/homelab-split-ingress \
           modules/cluster-capacity \
           modules/tls-letsencrypt; do
  ( cd "$dir" \
      && terraform init -backend=false \
      && terraform validate \
      && terraform test -verbose \
      && tflint --init && tflint --format compact \
      && terraform-docs --output-check . ) || echo "FAILED: $dir"
done
```

`examples/homelab-godaddy` needs `GODADDY_API_KEY` / `GODADDY_API_SECRET` set
to anything non-empty, the provider demands credentials even for a plan-time
test. `Taskfile.yml` exports stubs for exactly this reason.

A real deployment uses `terraform apply` from `examples/homelab/` with a
populated `terraform.tfvars`, but **never apply from CI** in this repo.

### Commit messages

[Conventional Commits](https://www.conventionalcommits.org/), enforced by
review rather than by a hook. `CONTRIBUTING.md` states the same rule for human
contributors; this section is the agent-facing form of it.

```text
<type>(<optional scope>): <imperative summary, under 72 chars>

<body: why, not what. The diff already says what.>
```

Types in use here: `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`, which
is the same set `CONTRIBUTING.md` gives. Not `bug`: the type names the
change, not the thing being changed, so a bug fix is `fix`. Not `test`
either: a change to `terraform test` coverage ships in the same commit as
the behaviour it covers, so it takes that commit's type. Use `!` after the type or scope for a breaking change to an input,
output or default.

Scope is optional and is a path or subsystem, not a ticket. The ones that
recur: `examples`, `readme`, `release`, `ci`, `tflint`, `security`,
`troubleshooting`. `fix(examples):` is the right shape for anything under
`examples/`, whichever example it touches.

Two repo-specific habits worth keeping:

- **One logical change per commit**, even when several arrive together. A
  round of review findings that touches validation, comments and tests is
  still one commit if it is one round; splitting an unrelated change out of it
  is not optional. The index carries whatever was staged earlier, so check
  `git diff --cached --stat` before committing rather than assuming
  `git add <path>` scoped it.
- **Say what was wrong, not just what changed.** These commits are the only
  record of why a default is the value it is, and a body naming the failure
  mode ("the claim sits Pending with nothing explaining why") is worth more
  later than one naming the edit.

Older subjects in `git log` predate this repo and do not follow the
convention; they came with the AWS history this module was ported from.

Imperative mood: "add", not "added" or "adds". No em-dashes or en-dashes
anywhere in this repo, commit messages included.

### Provider lock files

`.terraform.lock.hcl` is committed at the module root and in every
`examples/*` root module, each locked for `linux_amd64`, `linux_arm64`, and
`darwin_arm64` (Intel macOS is intentionally out of scope). This is what lets
`actions/cache` in `.github/workflows/terraform-tests.yml` key the provider
plugin cache and lets repeated local `terraform init` runs skip the registry
download.

Refresh a lock file after changing a `required_providers` constraint by
re-running the same `providers lock` invocation in that root module:

```bash
terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64
```

On an unlocked platform (Intel macOS, Windows), `terraform init` fails with
"no compatible checksums"; re-run the command above with your platform added
(e.g. `-platform=darwin_amd64`) locally, without committing the result.

The module root's lock file exists only to cache the dev loop and CI; it is
never read by consumers of the published module (Terraform resolves a
root module's own lock file, not one committed inside a dependency). That is
why `.terraform-docs.yml` keeps `lockfile: false`: the README reference
table must keep showing the provider *constraints* from `versions.tf`, not
the pinned versions this lock file resolves to.

### When adding a new input

1. Add it to `variables.tf` with `description`, `type`, sensible `default`
   (if any), and a `validation` block when it adds meaningful guardrails.
   Prefer adding validation for new inputs, but align with existing patterns in
   `variables.tf` and avoid redundant checks.
2. Surface it on the resource(s) that consume it.
3. Add an `assert` in `tests/defaults.tftest.hcl` (and the relevant example
   test file if the variable is exercised by an example). See *Known mock
   provider limitations* below for guidance when end-to-end wiring cannot be
   tested under mocks.
4. Update `CHANGELOG.md` - add a bullet under `## [Unreleased] / ### Added`.
5. Re-run `terraform-docs .` to refresh the `README.md` reference table.
   **This step is CI-gated**, the `docs` job runs `terraform-docs
   --output-check .` and will fail the PR if the README is stale.
6. Run the full local loop (`terraform fmt -recursive`, `terraform validate`,
   `terraform test`) and confirm all tests pass **before committing**.

### When adding a new resource

1. Put it in the existing `.tf` file matching its concern (e.g. anything CloudNativePG →
   `postgres_cnpg.tf`). Create a new file only for a genuinely new concern.
3. Reference it from the relevant output, if it's user-facing.
4. Add a plan-time assertion if the resource encodes a non-obvious default.
5. Run `tflint` and `checkov` locally before pushing - CI will run them
   anyway, but failing fast saves a round trip.

### What *not* to do

- Don't configure providers inside the module. `versions.tf` declares
  `required_providers`; provider configuration is the caller's job (see
  `examples/homelab/providers.tf`).
- Don't introduce nested `module` calls without a strong reason - this module
  is intentionally flat so registry consumers can read it top to bottom.
- Don't commit `terraform.tfstate*`, `*.tfplan`, `apply*.log`, or
  `terraform.tfvars`. The `.gitignore` already covers these; check before
  committing if you ran `apply` locally inside `examples/homelab/`.
- Don't hand-edit the `<!-- BEGIN_TF_DOCS -->` block in `README.md`.
- Don't widen `soft_fail` or silence lint rules without a comment explaining
  why and a follow-up TODO.
- Don't add inline lint-suppression comments (`<!-- markdownlint-disable -->`,
  `# tflint-ignore`, `# checkov:skip`) as a first response to a lint
  warning. Prefer fixing the root cause or updating the relevant config file
  (`.markdownlint.jsonc`, `.tflint.hcl`). Inline suppressions are acceptable
  only for genuine false positives that cannot be resolved at the config
  level, and must include a comment explaining why.

## References

- [Terraform module structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure)
- [Publishing modules to the Terraform Registry](https://developer.hashicorp.com/terraform/registry/modules/publish)
- [Terraform partnerships guidelines](https://developer.hashicorp.com/terraform/docs/partnerships)
- [Announcing the new Partner Premier Tier for the Terraform Registry](https://www.hashicorp.com/en/blog/announcing-the-new-partner-premier-tier-for-the-terraform-registry)
- [`terraform test` framework](https://developer.hashicorp.com/terraform/language/tests)
- [`terraform-docs`](https://terraform-docs.io/)
- [TFLint](https://github.com/terraform-linters/tflint) · [Checkov](https://www.checkov.io/)
