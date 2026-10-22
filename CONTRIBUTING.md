# Contributing

Thanks for considering a contribution to `terraform-kubernetes-n8n`.

## Before you start

- Open an [issue](https://github.com/TpyoKnig/terraform-kubernetes-n8n/issues)
  for anything non-trivial before opening a PR. Aligning on the
  approach first avoids wasted work on both sides.
- For security findings, **do not** open a public issue. See
  [`SECURITY.md`](./SECURITY.md).
- For general n8n questions (not specific to this module), use the
  [n8n community forum](https://community.n8n.io/) instead.

## Development setup

The conventions a PR is measured against are in
[`docs/module-contract.md`](./docs/module-contract.md), written as numbered
rules so a review comment can cite one.

The deep guide for working in this repo lives in [`AGENTS.md`](./AGENTS.md),
read it before making changes. It covers the local validation loop,
the test framework, and the quality bar this module is held to.

The short version:

```bash
terraform fmt -recursive
terraform init -backend=false
terraform validate
terraform test -verbose
if [ -d tests/opentofu-gaps ]; then
  terraform test -test-directory=tests/opentofu-gaps -verbose
fi
tflint --init && tflint --format compact
terraform-docs --output-check .
```

Repeat the `init / validate / test / tflint / terraform-docs` block
under each example directory (`examples/homelab`,
`examples/homelab-cloudflare`, `examples/homelab-godaddy`,
`examples/homelab-split-ingress`) and each submodule
(`modules/cluster-capacity`, `modules/tls-letsencrypt`), which mirrors
the CI matrix exactly. CI will run the same matrix on your PR. The root
and `modules/cluster-capacity` also carry a `tests/opentofu-gaps`
directory: run the `if` block above there too, it is real coverage under
Terraform, just isolated out of `terraform test`'s default directory
because a known OpenTofu testing-framework limitation cannot execute it
(see AGENTS.md's local development loop).

Don't skip the submodules. They are the only roots that catch a change
to their own input contract: a new required variable in either one
validates fine everywhere else, because the root module calls
`cluster-capacity` with every input already set and does not call
`tls-letsencrypt` at all.

If you have [`task`](https://taskfile.dev) installed (`brew install
go-task`), `task ci` runs the same fmt/validate/test/lint/docs matrix
across the module root and every example in one command. See
[`Taskfile.yml`](./Taskfile.yml) for the individual targets (`task fmt`,
`task validate`, `task test`, `task lint`, `task docs`,
`task docs-generate`).

### OpenTofu

This module is published to both the Terraform and OpenTofu registries,
so OpenTofu is a tested, supported consumer, not just Terraform with a
different binary name. CI's `test-opentofu` job runs `tofu init
-backend=false` and `tofu test` across the same root, example and
submodule matrix `test`/`test-floor` cover, on the pinned `TOFU_VERSION`
(see `.github/workflows/terraform-tests.yml`). If you have the `tofu`
CLI installed, run the same thing locally with `task opentofu`
(standalone, not part of `task ci`, since most contributors only have
one of the two CLIs on PATH). Two targets are deliberately
non-blocking there for known OpenTofu testing-framework gaps unrelated
to this module's resources or variables; see the comments beside
`test-opentofu` in the workflow file for what they are and why a real
fix in either tool will let CI go fully strict there too. A change that
affects `tests/*.tftest.hcl` syntax or mock/override shapes should still
pass `task opentofu` where it is not one of those two documented
exceptions.

## Commit messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```text
<type>(<optional scope>): <imperative summary, <72 chars>

<optional body explaining the why>
```

Common types: `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`. There is
no `test` type here: a change to `terraform test` coverage ships in the
same commit as the behaviour it covers, so it takes that commit's type.
Scope is optional but useful (e.g. `feat(database): add Aurora
Multi-AZ option`). Use the imperative mood ("add", not "added" or
"adds").

## Pull requests

- Open PRs against `main`. Don't push directly to `main`; it's
  protected.
- One logical change per PR. Smaller PRs review faster.
- If you add a new input, surface it through a `terraform-docs`
  regeneration (`terraform-docs markdown table --output-file README.md
  --output-mode inject .`), CI checks that the README is in sync.
- If you add a non-trivial new resource or behavior, add a plan-time
  assertion in `tests/defaults.tftest.hcl` (or the relevant example's
  test suite).
- All CI checks must be green before merge.

See [`AGENTS.md`](./AGENTS.md) for details on adding inputs, adding
resources, and what *not* to change.

This module selects a backing service with an enum, `postgres_backend`
(`cnpg` | `external`), `redis_backend` (`valkey` | `external`), not with a
`create_<x>`/`install_<x>` toggle. A new backing service should follow that
shape. Anything the caller must already own (the cluster, the ingress
controller, cert-manager, the CNPG operator, KEDA, the StorageClass, DNS) is a
documented prerequisite rather than a toggle, because this module creates no
cluster infrastructure of its own.
