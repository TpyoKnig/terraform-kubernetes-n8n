# Security Policy

## Scope

This policy covers `terraform-kubernetes-n8n`, the Terraform module published
at <https://github.com/TpyoKnig/terraform-kubernetes-n8n>. It is not on the
Terraform Registry, so a GitHub `?ref=` tag is the only supported source.

It does **not** cover:

- The n8n product itself.
- Workflows users build inside n8n.
- Kubernetes itself, the Helm charts this module installs, or any
  operator it expects the cluster to already run.

If you've found something that affects the n8n product rather than
this Terraform module, please report it through n8n's product security
channel instead.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting:

1. https://github.com/TpyoKnig/terraform-kubernetes-n8n/security/advisories/new
2. Fill in the report. We see it; the public does not.

If you cannot use GitHub Advisories, open an issue saying only that you have
a security report and asking for a contact address, no details in the issue.

Please **do not** open public GitHub issues describing security findings.

Do not send reports for this module to n8n. It is a community project and n8n
does not maintain it, so a report sent there cannot be acted on and only delays
the fix. `security@n8n.io` is the right address for vulnerabilities in the n8n
product itself.

## Response expectations

This is a community project maintained on a best-effort basis by
volunteers. There is no SLA, contractual or otherwise, and no organisation
standing behind it. The intent is to:

- Acknowledge new reports within 5 business days.
- Provide an initial assessment (severity, scope, planned action)
  within 10 business days.
- Coordinate a fix and disclosure timeline with the reporter.

For critical issues with active exploitation, the intent is to move faster:
but treat those as goals, not guarantees, and plan your own mitigations
accordingly.

## Supported versions

Only the most recent release receives security fixes. Older tags do not
receive backports, and pre-1.0 there is no long-term support line. See
[README.md, Stability and versioning](./README.md#stability-and-versioning)
for the versioning policy.

| Version      | Security fixes |
| ------------ | -------------- |
| 0.0.1-beta.6 | ✅ (current)   |

`0.0.1-beta.1` through `0.0.1-beta.5` are the earlier tags. All are
superseded and receive nothing, including security fixes. Upgrade rather than
asking for a backport.

## Out of scope for this policy

- Findings that require an attacker already inside the cluster.
  Hardening within an already-compromised environment is best-effort
  and not in scope.
- Findings against the third-party charts this module installs (the n8n
  chart, Valkey) or the operators it expects you to run (CloudNativePG,
  cert-manager, KEDA, an ingress controller). Report those upstream; we
  bump our chart pins once a fix is available.
- Findings against permissive settings this module exposes as optional
  inputs (e.g. widening the task runner's `n8n_python_external_allow`, or
  enabling `cnpg_lan_expose` on an untrusted network). These are
  documented configuration choices, not vulnerabilities.
