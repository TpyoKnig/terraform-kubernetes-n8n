# Post-deployment setup

After `terraform apply` completes, there is one thing left: getting traffic to
the deployment.

## Wait for the Ingress to get an address

The ingress controller assigns an address asynchronously after the `Ingress`
object is created. Verify:

```bash
kubectl get ingress -n n8n
kubectl get pods -n n8n
```

All pods should reach `Running`, and the `Ingress` should show an ADDRESS. If
the address stays empty, the ingress controller is the place to look, not
Terraform, the module's work finished when the object was created.

If pods are stuck in `Pending`, see
[troubleshooting](./troubleshooting.md#pods-stay-pending-with-insufficient-cpu).
If a pod is in `CreateContainerConfigError`, a referenced Secret is missing or
has a different key than expected.

## Point your domain at n8n

**The module creates no DNS record.** How the hostname reaches your cluster is
yours to arrange, because there is no portable answer: a tunnel, a public
LoadBalancer, split-horizon DNS on a LAN, a reverse proxy, an overlay network.

Whatever you use, the name in `n8n_domain` has to resolve to something that
reaches your ingress controller, and the certificate has to cover it. See
[`examples/homelab-cloudflare`](../examples/homelab-cloudflare/) for one worked
strategy.

Verify once the record exists:

```bash
dig +short n8n.yourdomain.com
curl -sI https://n8n.yourdomain.com | head -1
```

## Check that TLS was issued

cert-manager issues the certificate asynchronously too, and a failure here
leaves the site served with a self-signed default certificate rather than
failing outright:

```bash
kubectl get certificate -n n8n
kubectl describe certificate -n n8n   # if READY is not True
```

## Access n8n

Open `https://n8n.yourdomain.com` and create your owner account.

That is the whole setup. The module deploys Community-edition n8n, and queue
mode, workers and webhook processors all run unlicensed: there is no key to
paste into the UI and no activation step.

## Back up the encryption key now

Before anything is stored:

```bash
terraform output -raw n8n_encryption_key
```

Keep it somewhere durable. Losing it makes every stored credential permanently
unreadable, and that survives a database restore: restoring Postgres into a
rebuilt deployment without this key leaves the credentials present and
undecryptable.
