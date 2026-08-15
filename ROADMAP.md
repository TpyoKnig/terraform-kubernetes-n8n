# Roadmap

This roadmap captures intent, not commitments. Nothing here is on a fixed
timeline. See [`CHANGELOG.md`](./CHANGELOG.md) for what has actually shipped.

## Phases

### Phase 1: First release

A lean module that deploys queue-mode n8n onto a cluster the caller already
runs, verified by a mocked plan suite and validated by live applies against a
real cluster. This is where the module is now.

### Phase 2: Real-world feedback

Publish, then iterate on what operators actually hit. The parts most likely to
need it are the ones no test can reach: how the module behaves on clusters whose
storage, ingress and networking differ from the ones it was built against.

### Phase 3: Widen the verified surface

Two things are supported but thin on evidence:

- **The `external` backends.** `postgres_backend = "external"` and
  `redis_backend = "external"` are tested at plan time and have no example
  root. A managed database alongside an in-cluster workload is a normal
  topology and deserves a worked one.
- **Backups.** The module ships no backup configuration for CloudNativePG, and
  a `Cluster` with no `backup` stanza is a database whose only copy is a PVC.
  Today that is documented and left to the caller; a first-class input is worth
  considering, with the caveat that it would give the module an opinion about
  object storage it currently refuses to have.

## Candidate features

- **A worked ingress-level authentication example.** n8n's own SSO (SAML/OIDC)
  is a licensed feature and out of scope for this module, so the identity
  boundary belongs at the ingress instead. `examples/homelab-split-ingress`
  explains the shape but configures no provider; a worked Cloudflare Access or
  OIDC-proxy example would close that gap.
- **DNS-01 for wildcard certificates.** `modules/tls-letsencrypt` solves HTTP-01
  only, which cannot issue wildcards and cannot work on a cluster Let's Encrypt
  cannot reach. DNS-01 needs a provider-specific solver and zone credentials, the same DNS opinion the module otherwise avoids, so it would likely be a
  separate submodule per provider rather than an input here.

## Explicitly out of scope

Not gaps, and not planned:

- **Creating the cluster.** There is no generic "create a Kubernetes cluster"
  resource, and the answer differs for every distribution. See
  `AGENTS.md` → "The ownership boundary".
- **Installing cluster-wide operators.** cert-manager, CloudNativePG, KEDA, an
  ingress controller and a `StorageClass` are singletons shared by every
  workload on the cluster. A module that installed one would own upgrading and
  destroying it on behalf of workloads it cannot see.
- **Managing DNS.** How a name reaches a self-hosted cluster has no portable
  answer. Worked strategies belong in example roots, and two ship today.
- **An object-storage data plane.** Binary data stays on filesystem mode. A
  bucket outlives any one n8n deployment, so the module does not create one:
  `docs/operations.md` covers pointing at your own.
