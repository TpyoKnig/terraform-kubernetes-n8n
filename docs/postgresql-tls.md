# PostgreSQL TLS certificate verification

`db_postgresdb_ssl_enabled` (the default, `true`) encrypts the connection
between n8n and PostgreSQL, but encryption alone does not prove n8n is
talking to the server it thinks it is. Out of the box the module sets
`DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false`, which negotiates TLS but skips
certificate validation entirely: anything presenting a certificate at all is
accepted. `db_postgresdb_ssl_reject_unauthorized` and `db_postgresdb_ssl_ca_pem`
exist to close that gap, on both the CNPG path and the external `db_host` path.

## Why the default skips verification

On the CNPG path (`postgres_backend = "cnpg"`, the default), CloudNativePG
generates a self-signed certificate authority per `Cluster` and signs the
instance's server certificate with it. That CA is not published anywhere this
module can read without a cluster: it lives in a Secret the operator creates
(conventionally `<cluster>-ca`, holding `ca.crt`/`ca.key`), and this module does
not read it, consistent with the rest of this codebase: cluster state is
attested by input, never detected by data source (see `AGENTS.md`). Node.js has
no reason to trust a CA it has never seen, so turning on verification with no
CA supplied makes every connection fail closed. That is why the module
defaults to skipping verification rather than breaking every existing
deployment the first time this input shipped.

On the external path (`postgres_backend = "external"`, `db_host`), the same
default applies for a different, simpler reason: the module has no idea what
CA issued that server's certificate, and guessing wrong is the same failure
mode.

## Hostname verification works on both backends

n8n's PostgreSQL driver (`pg`/node-postgres) exposes a single
`rejectUnauthorized` flag. Setting it `true` always performs both a
certificate-chain check and a hostname/SAN check via Node's TLS module; there
is no way to ask for chain-only verification. That matters because some managed
databases (reached only by a private IP with no certificate-covered name) can
never pass the hostname half, no matter what CA is supplied.

This module's CNPG path does not have that problem. n8n always connects to the
CNPG rw Service's cluster-internal DNS name
(`<cluster>-rw.<namespace>.svc.cluster.local`, see `local.k8s_pg_host` in
`locals.tf`), and CloudNativePG's default self-managed certificate covers that
Service's DNS names in its SANs. So, once the operator-issued CA reaches
`db_postgresdb_ssl_ca_pem`, verification can genuinely succeed on the CNPG
path too, not only on the external one. The external path works the same way
it does on the cloud siblings: `db_host` has to be a name the server's own
certificate actually covers.

## Turning on verification

### External path

```hcl
module "n8n" {
  # ...
  postgres_backend                      = "external"
  db_host                                = "postgres.example.internal"
  db_postgresdb_ssl_enabled              = true
  db_postgresdb_ssl_reject_unauthorized  = true
  db_postgresdb_ssl_ca_pem               = file("${path.module}/postgres-ca.pem")
}
```

Supply the CA bundle that issued your server's certificate. If the server
chains to a publicly trusted root already present in the pod image's trust
store, `db_postgresdb_ssl_ca_pem` can stay null and verification still works;
see "Without a CA bundle" below.

### CNPG path

The CA is generated only after the `Cluster` exists, so this is a two-step,
day-two change rather than something the first `terraform apply` can do for
you:

1. Apply with `postgres_backend = "cnpg"` (the default) so the operator
   creates the `Cluster` and its CA Secret.
2. Extract the CA:

   ```bash
   kubectl get secret n8n-pg-ca -n <namespace> -o jsonpath='{.data.ca\.crt}' | base64 -d
   ```

   (`n8n-pg-ca` is this module's fixed CNPG cluster name, `n8n-pg`, plus the
   operator's own `-ca` suffix; it does not change between deployments.)
3. Set `db_postgresdb_ssl_reject_unauthorized = true` and
   `db_postgresdb_ssl_ca_pem` to that output, and apply again.

```hcl
module "n8n" {
  # ...
  db_postgresdb_ssl_enabled             = true
  db_postgresdb_ssl_reject_unauthorized = true
  db_postgresdb_ssl_ca_pem              = file("${path.module}/cnpg-ca.pem")
}
```

Because the module never reads the CA Secret itself, nothing re-extracts it
automatically if CNPG ever rotates that CA (CNPG does not rotate its default
self-managed CA on its own, but a cluster recreated from scratch gets a new
one). Re-run step 2 and re-apply if verification starts failing closed after a
Cluster was recreated.

## Without a CA bundle

Leaving `db_postgresdb_ssl_ca_pem` null while
`db_postgresdb_ssl_reject_unauthorized = true` is valid: verification then
falls back to the pod image's bundled trust store, which only succeeds if the
server's certificate chains to a publicly trusted root already in that image.
The CNPG path's self-signed per-cluster CA is never in that store, so this
combination fails closed there; it is realistic only on the external path
against a server with a publicly trusted certificate.

In this mode n8n passes `ssl: true` to its PostgreSQL driver rather than an
explicit `rejectUnauthorized` option (n8n's database configuration only builds
an explicit TLS options object when a CA, certificate, key, or a `false`
`rejectUnauthorized` is present), so the certificate check follows Node's
process-wide default. If `n8n_extra_env` sets
`NODE_TLS_REJECT_UNAUTHORIZED=0`, Node skips the check on every n8n pod. The
`postgres_ssl_verification_disabled_by_node_tls_env` check (`n8n.tf`) warns
about this combination at plan time. Once you supply a CA bundle, n8n passes an
explicit `rejectUnauthorized`, and `NODE_TLS_REJECT_UNAUTHORIZED` no longer
affects this connection.

## How the CA reaches n8n

`db_postgresdb_ssl_ca_pem`, trimmed of surrounding whitespace, is passed to the
n8n Helm chart's `database.ssl.ca` value (`local.postgres_ssl_ca_values` in
`locals.tf`), which the chart renders as the `DB_POSTGRESDB_SSL_CA`
environment variable on the main, worker, and webhook-processor pods
(chart 1.14.0 through at least 1.17.0). This is the one case where this module
sets `database.ssl` at all: `DB_POSTGRESDB_SSL_ENABLED` and
`DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED` are otherwise expressed through
`config.extraEnv`, never through the chart's own `database.ssl.enabled` /
`.rejectUnauthorized`, because on charts before 1.15.0 the enable flag rendered
`DB_POSTGRESDB_SSL`, a name n8n does not read, and the reject flag renders a
name this module already emits unconditionally, which duplicates an
environment variable and fails every later Helm upgrade. See the comment on
`local.k8s_values_database` in `locals.tf` for the full history.

When a CA is active, this module still avoids that duplicate: it omits its own
`DB_POSTGRESDB_SSL_ENABLED` entry only on a chart version it has verified
renders that name itself from `database.ssl.enabled` (1.15.0 and later, from
the configured `n8n_chart_repository`), and keeps emitting
`DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED` from `config.extraEnv` unconditionally
by pinning the chart's own `database.ssl.rejectUnauthorized = true`, which
suppresses the chart's conditional render of that same name. See
`local.n8n_chart_renders_postgres_ssl_enabled` and
`local.postgres_ssl_ca_values` in `locals.tf`, and
`tests/scripts/check-n8n-chart.sh`, which renders the real chart to prove
exactly one of each name reaches the main Deployment.

Keeping the CA inside the Helm release means a failed upgrade's atomic
rollback restores the previous CA together with the pods, removing the CA is a
Helm-only change with no separate object to delete first, and the chart's
`checksum/config` pod annotation rolls the pods whenever only the CA changes.

A CA certificate is public, so `db_postgresdb_ssl_ca_pem` is not marked
sensitive; it is still stored in Terraform state and in the Helm release. The
module checks only that the value has PEM certificate framing
(`-----BEGIN CERTIFICATE-----` / `-----END CERTIFICATE-----`), that it is pure
ASCII, and that it is at most 131050 characters after trimming (the chart
passes it to each container as an environment variable, and Linux refuses to
start a container whose environment string exceeds `MAX_ARG_STRLEN`, 128 KiB);
it does not parse the certificate itself, and a bundle with more than one
certificate is accepted.

## Plan-time warnings

Two non-blocking `check` blocks in `n8n.tf` catch the ways these inputs can be
set to something that renders but does nothing:

- `db_postgresdb_ssl_ca_pem_requires_verification` warns if
  `db_postgresdb_ssl_ca_pem` is set while `db_postgresdb_ssl_reject_unauthorized`
  is false (the CA still reaches the chart, unused) or while
  `db_postgresdb_ssl_enabled` is false (the CA never reaches the chart at all).
- `postgres_ssl_verification_disabled_by_node_tls_env` warns if
  `db_postgresdb_ssl_reject_unauthorized = true` with no CA, and
  `n8n_extra_env` sets `NODE_TLS_REJECT_UNAUTHORIZED=0`, which silently defeats
  that verification on every n8n pod.

Neither check fails the plan. Both exist so a caller who sets one input and
forgets the other, or who already has `NODE_TLS_REJECT_UNAUTHORIZED=0` in
`n8n_extra_env` for an unrelated reason, learns about it before the next
`terraform apply`, not after wondering why a supplied CA "did nothing."

## PgBouncer (`cnpg_pooler_enabled`)

`cnpg_pooler_enabled = true` requires `db_postgresdb_ssl_enabled = false` (the
module refuses the combination at plan time, see `variables.tf`): the CNPG
`Pooler` serves its clients in plaintext and terminates TLS on its own upstream
leg to Postgres. With TLS off on that leg, `db_postgresdb_ssl_reject_unauthorized`
and `db_postgresdb_ssl_ca_pem` are inert by the same logic
`db_postgresdb_ssl_ca_pem_requires_verification` flags elsewhere: there is no
TLS connection for n8n to verify a certificate on. `examples/homelab-pgbouncer`
documents this.

## Upgrading an existing deployment

Changing any of these three inputs only changes what the n8n application
containers send as TLS connection parameters; it does not modify the CNPG
`Cluster` or an external server. A Helm-only rollout applies the new value on
the next pod restart of the main, worker, and webhook-processor Deployments.
Setting `db_postgresdb_ssl_reject_unauthorized = true` without a CA that covers
the server's actual certificate chain fails every database connection closed
after the rollout completes, so confirm a new CA or a newly turned-on
verification in a non-production environment first, there is no fallback to an
unverified connection once the setting is live.
