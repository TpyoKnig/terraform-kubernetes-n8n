# Module contract

The conventions this module holds itself to, written down so a PR has
something to be measured against instead of my taste on the day.

Each rule is numbered so a review comment can say "contract 4.2" and mean
something. Where a rule is already enforced by CI, that's noted. Where it
isn't, it's a review judgment and you can argue with it.

The reasoning behind most of these lives in [`AGENTS.md`](../AGENTS.md). This
file is the short checkable form, not a second copy of the argument.

## Where these came from

There is no published HashiCorp spec called "HVD" that a module can be
validated against. HashiCorp Validated Designs are reference architectures,
and the Terraform modules that implement them (`terraform-aws-vault-enterprise-hvd`,
`terraform-azurerm-terraform-enterprise-hvd`, and their siblings) are the
observable convention. So the shape below is reverse-engineered from those
modules plus two things that *are* written down:

- [Standard Module Structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure),
  which is normative about file layout, `modules/`, `examples/` and READMEs.
- The [Partner Premier Tier](https://www.hashicorp.com/en/blog/announcing-the-new-partner-premier-tier-for-the-terraform-registry)
  criteria, already quoted in `AGENTS.md`: static analysis, `terraform test`,
  naming conventions, clear docs, all standard module files.

The HVD modules agree on a README order, an explicit prerequisites-versus-
module-creates split, version pinning in every usage snippet, and a plain
support statement. This module already had all four before I went looking,
which is the main reason this document is a write-up rather than a rewrite.

## 1. Naming and structure

1.1 The repository is `terraform-<PROVIDER>-<NAME>`, where PROVIDER is the
real primary provider. Here that's `hashicorp/kubernetes`, so
`terraform-kubernetes-n8n`. Not `terraform-k8s-n8n`, not `terraform-helm-n8n`.

1.2 One resource-bearing root module. Resources may be split across files by
concern, but there is no second root and no `backend_platform`-style switch
that makes this two modules wearing one name.

1.3 Nested modules live in `modules/`, are called by relative path, and each
carries its own README, variables, outputs and test suite. A submodule exists
only when the root genuinely cannot own the resource. Both current submodules
document that reason in their README.

1.4 Examples live in `examples/`, one per topology, never per size tier.

## 2. The ownership boundary

2.1 This module owns the workload and its backing services. It creates no
cluster, no ingress controller, no cert-manager, no CNPG operator, no KEDA, no
StorageClass and no DNS record.

2.2 A cluster-wide singleton is never installed by this module. Installing one
means owning its upgrade and destroy on behalf of workloads the module can't
see. This is permanent, not a gap waiting on a PR.

2.3 Anything in 2.1 is a documented prerequisite in `README.md`, and the
module does not probe for it. A missing operator surfaces as an unreconciled
resource in the cluster, not as a Terraform error.

2.4 Cluster state is attested by input, never detected by data source. A
refresh-time lookup makes the dependent branch unknown at plan time and defeats
the mocked suite. `k8s_keda_installed` is the worked example.

## 3. Inputs and outputs

3.1 A **backing service** is selected by enum, never by a toggle.
`postgres_backend` is `cnpg | external`, `redis_backend` is `valkey | external`.
A new backing service follows that shape, because the question is always "which
one", not "yes or no".

3.1.1 A `create_<x>` toggle is legitimate for an **optional resource the module
itself renders**, which is a different question. `create_ingress` and
`create_namespace` are the two, and both answer "should the module render this
at all", not "which implementation". Do not read 3.1 as banning them.

3.2 Every input and output carries a `description`. Enforced by tflint
(`terraform_documented_variables`, `terraform_documented_outputs`).

3.3 Every declared input reaches the workload. An input that is accepted,
validated and documented but wired to nothing is worse than one that isn't
offered. A new workload input ships with a test asserting it against the
rendered values tree.

3.4 Validation belongs at the variable, with an error message that says what
to do. Plan-time rejection beats a less legible failure inside n8n.

3.5 Secrets are referenced, never read. `*_secret_ref` inputs name a Secret the
module never reads, so a wrong name fails at the pod, not in state.

3.6 Every root input belongs to a naming family. Enforced by
`scripts/check-variable-prefixes.sh`.

| Family | Governs |
| --- | --- |
| `n8n_` | n8n application and workload configuration |
| `k8s_` | cluster-facing surface: ingress, attestations |
| `db_` | Postgres endpoint and protocol, in n8n's own vocabulary |
| `redis_` | queue endpoint and protocol, same |
| `cnpg_` | in-cluster Postgres implementation |
| `valkey_` | in-cluster queue implementation |
| `postgres_` | the Postgres backend selector |
| `create_` | optional resources the module itself renders |
| `metrics_` | n8n's own metrics port exposure |

The logic behind the split, since it is not obvious from the list: a
**selector** takes the generic service name, an **endpoint or protocol** input
takes n8n's own vocabulary because it maps to an n8n environment variable
(`db_*` mirrors `DB_POSTGRESDB_*`, `redis_*` mirrors `QUEUE_BULL_REDIS_*`), and
an **implementation** input takes the implementation's name. That is why
`db_host` sits next to `postgres_backend` rather than being `postgres_host`.

There are no exemptions. The `namespace` output keeps its short caller-facing
name while its input is `k8s_namespace`, which is deliberate: input names are
the module's internal vocabulary, output names are what a caller reads.

3.7 This vocabulary is for the root module only. Examples and submodules take
caller-facing names (`ui_host`, `godaddy_domain`, `kubeconfig_path`,
`peak_cpu_request_millis`), which is correct for them.

## 4. Documentation

4.1 README section order, borrowed from the HVD modules: what the module owns,
prerequisites, usage, the subsystem sections, examples, operations, stability,
support, out of scope, then the generated reference block.

4.2 The block between `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` is
generated. Never hand-edit it. Enforced by the `docs` CI job
(`terraform-docs --output-check`), for the root and every example and submodule.

4.3 Every usage snippet pins a version. An unpinned `source` invites a
`terraform apply` to pick up a breaking change the caller didn't choose.

4.4 The support statement stays plain and stays present. This is a community
project, it is not an n8n product, and n8n does not offer, endorse or support
it.

4.5 If you reference a `docs/` file, it exists. Dead documentation links have
been the single most common review finding on this repo.

## 5. Testing

5.1 Every root has a mocked plan suite that runs with no cluster and no
credentials: the module root, all six examples, both submodules.

5.2 A new resource or behaviour ships with a plan-time assertion. A new input
ships with an assertion that it reaches the rendered values.

5.3 Submodule suites are not optional. They're the only roots that catch a
change to their own input contract, because the root calls `cluster-capacity`
with every input already set and never calls `tls-letsencrypt`.

5.4 `command = apply` is not a workaround for a plan-time unknown.

5.5 `tests/scripts/smoke-test.sh` is where a real cluster gets inspected. It is
deliberately not in CI, because CI has no cluster.

## 6. Static analysis

6.1 tflint and checkov both run on every PR and both hard-fail.

6.2 No repo-wide `skip-check`. A finding is annotated inline at the resource
that causes it, with a reason, so the check stays live everywhere else.

6.3 Rationale in a config file has to be reproducible against this repo. A
comment explaining a setting by citing a file that doesn't exist here is worse
than no comment. This has happened once already and the note in
`.checkov.yaml` records it.

## 7. Versioning

7.1 Pre-1.0, breaking changes allowed, and the changelog says which.

7.2 A PR states whether it is patch-eligible (additive only) or minor-only
(changes defaults, renames or removes inputs, refactors resource addresses,
raises a provider floor). The PR template asks this.

7.3 No `moved` blocks across the AWS sibling boundary. The two describe
different infrastructure and share no resource addresses.

## 8. Writing style

8.1 No em-dashes. Comma, colon, period, parentheses or a spaced hyphen. This
applies to prose, code comments, variable descriptions and commit messages.
Note that a description can smuggle one in as a `\u2014` escape, which greps
for the character will not find.

8.2 Say what the thing does, then say the catch. Known limits stated plainly
beat feature marketing, and they're the part a self-hoster actually needs.

8.3 Commit messages are Conventional Commits, imperative mood. A body is for a
real decision worth recording, not for narrating the diff.

## Deliberate deviations

Two places where this module knowingly departs from the standard, recorded so
nobody has to rediscover the reasoning.

**Example `source` is a relative path.** The Standard Module Structure says
example `module` blocks "should have their source set to the address an
external caller would use, not to a relative path". Every example here uses
`source = "../.."` instead. A registry address would pin examples to the last
published version, so `terraform test` in an example would validate the
released module rather than the working tree, and CI would stop catching
breakage before release. The README usage snippet carries the external address
and pins it, which is where a caller actually copies from.

**No `main.tf`, and the nested module call is not in one.** The Standard Module
Structure asks for `main.tf`, `variables.tf` and `outputs.tf` "even if they're
empty", says `main.tf` "should be the primary entrypoint", and says "any nested
module calls should be in the main file". This repo has no `main.tf`, and its
only nested module call, `module "cluster_capacity"`, lives in `scaling.tf`.

Resources here are filed by concern (`n8n.tf`, `postgres_cnpg.tf`,
`redis_valkey.tf`, `scaling.tf`), which is what rule 1.2 asks for and what the
Standard itself allows for a complex module. A `main.tf` holding one `module`
block and nothing else would be a file you have to open to learn nothing. The
capacity submodule is called from `scaling.tf` because that is where the
autoscaler ceilings it reads are defined, and splitting them would make the
demand model harder to follow, not easier.

**No object-storage data plane.** The cloud siblings offer one. This module
provisions no bucket, because it will not own a stateful data service on a
cluster whose lifecycle it does not control. Pointing n8n at your own bucket is
supported and documented in [`operations.md`](./operations.md#binary-data).

## What is machine-checked

| Rule | Checked by |
| --- | --- |
| 3.2 descriptions present | tflint, `docs` CI job |
| 3.6 naming families | `scripts/check-variable-prefixes.sh`, `naming` CI job |
| 4.2 generated block in sync | `terraform-docs --output-check`, all 9 roots |
| 5.1 mocked suites pass | `terraform test`, all 9 roots |
| 6.1 lint and scan clean | tflint, checkov, both hard-fail |
| 8.3 commit format | review only |

Everything else in this document is review judgment. If a rule here blocks
something that's obviously right, say so in the PR and we'll change the rule
rather than pretend the exception doesn't exist.
