# modules/tls-letsencrypt

A Let's Encrypt `ClusterIssuer` for cert-manager, solving HTTP-01 through your ingress controller.

## Why this exists

The root module writes a `cert-manager.io/cluster-issuer` annotation onto the `Ingress` it renders, naming whatever you passed as `k8s_ingress_cluster_issuer`. Every example defaults that to `letsencrypt-prod`: and nothing created it.

That failure is quiet. cert-manager sees an annotation naming an issuer that does not exist, never issues a certificate, and the ingress controller keeps serving its own default self-signed one. The deployment comes up, Terraform reports success, and the only symptom is a browser warning. A named prerequisite that is silently optional is the worst kind, so this module ships the one object that closes it.

## Why it is separate from the root module

A `ClusterIssuer` is cluster-scoped and shared. Two n8n deployments in one cluster both wanting TLS must not both own it, and `terraform destroy` on one must not take the other's issuer down with it: which would silently stop the survivor's renewals until someone noticed a certificate expiring 60 days later.

So this follows the same rule as the rest of the module: it does not own cluster-wide singletons on the caller's behalf. Call this once from wherever your cluster's shared configuration lives, not from every n8n deployment.

## Usage

```hcl
module "tls" {
  source = "github.com/TpyoKnig/terraform-kubernetes-n8n//modules/tls-letsencrypt"

  email              = "ops@example.com"
  ingress_class_name = "nginx"
}

module "n8n" {
  source = "github.com/TpyoKnig/terraform-kubernetes-n8n"

  n8n_domain                 = "n8n.example.com"
  k8s_ingress_class_name     = "nginx"
  k8s_ingress_cluster_issuer = module.tls.cluster_issuer_name
}
```

Passing the output rather than repeating the string is the point: the annotation and the issuer cannot drift apart.

## Prerequisites

- **cert-manager**, installed cluster-wide. This creates a custom resource its CRDs define; it does not install the operator.
- **Your hostname already resolving to this ingress controller.** HTTP-01 validates by fetching a token over port 80 from Let's Encrypt's servers, so DNS has to be in place *before* the certificate can issue. See the DNS examples.

## Start on staging

```hcl
staging = true
```

Staging certificates are signed by an untrusted root, so browsers reject them: that is expected. The reason to use it is rate limits: production allows **5 duplicate certificates per week**, and a misconfigured ingress that fails validation repeatedly can exhaust that and lock the hostname out until it resets. Get DNS and ingress working on staging, then flip to `false`.

The two issuers can coexist: the account-key Secret name defaults off the issuer name, so `letsencrypt-staging` and `letsencrypt-prod` do not collide on one ACME account.

## What this does not do

**No DNS-01 solver, so no wildcard certificates.** DNS-01 needs a provider-specific solver and credentials for the zone, which would give this module a DNS opinion: the one thing the rest of it deliberately refuses to have. HTTP-01 needs only that the name already resolves here.

**No private clusters.** HTTP-01 requires Let's Encrypt's validation servers to reach the hostname on port 80. A cluster reachable only over a private network, or behind an authenticating proxy, cannot use this issuer and needs a DNS-01 solver configured out of band.

## Reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | >= 1.14 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [kubectl_manifest.letsencrypt](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_email"></a> [email](#input\_email) | Contact address registered with Let's Encrypt for this ACME account. Required: Let's Encrypt uses it for expiry warnings and for contact about problems with issued certificates. It is not published in the certificate, but it is recorded in the ACME account and in Certificate Transparency logs' surrounding metadata, so use an address you are willing to associate with the deployment. | `string` | n/a | yes |
| <a name="input_ingress_class_name"></a> [ingress\_class\_name](#input\_ingress\_class\_name) | IngressClass cert-manager uses when it creates the temporary Ingress that serves the HTTP-01 challenge response. Must match the class actually serving your hostname, otherwise the challenge Ingress is created and no controller picks it up, and validation times out with no obvious error on the n8n side. | `string` | `"nginx"` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the ClusterIssuer this module creates. Pass the same value as the root module's k8s\_ingress\_cluster\_issuer (or the examples' cluster\_issuer), because that is what gets written into the Ingress annotation cert-manager reads. A mismatch is silent: cert-manager sees an annotation naming an issuer that does not exist, never issues, and the site serves the ingress controller's default self-signed certificate. | `string` | `"letsencrypt-prod"` | no |
| <a name="input_private_key_secret_name"></a> [private\_key\_secret\_name](#input\_private\_key\_secret\_name) | Name of the Secret in cert-manager's namespace holding this ACME account's private key. cert-manager creates it; the module only names it. Changing this name after issuance registers a NEW ACME account rather than reusing the existing one, which restarts from zero against the rate limits, so treat it as fixed once set. | `string` | `null` | no |
| <a name="input_staging"></a> [staging](#input\_staging) | Issue from Let's Encrypt's staging endpoint instead of production. Staging certificates are signed by an untrusted root, so browsers reject them - the point is that staging has far higher rate limits than production's 5 duplicate certificates per week. Use it while getting DNS, ingress and the challenge path working, then flip to false. Getting this wrong in the other direction is the expensive mistake: a misconfigured ingress that fails validation repeatedly against production can exhaust the weekly limit and lock the hostname out of new certificates until it resets. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_acme_server"></a> [acme\_server](#output\_acme\_server) | ACME directory endpoint in use. Staging when staging = true, which is signed by an untrusted root: browsers will reject certificates issued from it, by design. |
| <a name="output_cluster_issuer_name"></a> [cluster\_issuer\_name](#output\_cluster\_issuer\_name) | Name of the ClusterIssuer created. Pass this straight into the root module's k8s\_ingress\_cluster\_issuer so the Ingress annotation and the issuer cannot drift apart - which is the failure this module exists to prevent. |
| <a name="output_is_staging"></a> [is\_staging](#output\_is\_staging) | Whether this issuer points at Let's Encrypt staging. Useful as an assertion in a caller's own tests, so a deployment cannot reach production still pointed at staging and serve untrusted certificates. |
<!-- END_TF_DOCS -->
