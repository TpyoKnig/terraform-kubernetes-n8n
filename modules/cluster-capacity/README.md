# modules/cluster-capacity

An advisory `check` that compares the root module's autoscaler ceilings against the CPU this cluster can actually schedule.

## Why this exists

On the cloud siblings a node group grows when pods do not fit. Here nothing does. Set `n8n_worker_keda_max_replicas = 20` on a three-node lab and the plan succeeds, the apply succeeds, and the failure surfaces weeks later as workers stuck `Pending` with `Insufficient cpu` during the first burst that needed them.

So this reads the cluster's own allocatable CPU and warns at plan time when the ceilings cannot fit. It is a `check` block: it never fails a plan, and it creates nothing.

## You do not call this directly

The root module does, as `module.cluster_capacity`, passing the demand figure it already computed. Set `k8s_capacity_check_enabled = false` there to remove it.

That flag exists because the node read is a plain data source, not one nested inside the `check`. Nested reads have their provider errors masked as warnings, which sounds ideal: but they also execute after every other resource, which creates a dependency cycle for any caller that writes `depends_on = [module.n8n]`. A sizing hint is not worth breaking that, so the read moved out and became gateable instead. `main.tf` carries the full reasoning.

## What the number means

Only nodes that could take an n8n pod are counted: cordoned nodes and any node with a `NoSchedule` or `NoExecute` taint are excluded (`PreferNoSchedule` is a preference, not a bar, so those nodes stay counted), which is what keeps tainted control planes from roughly doubling apparent supply on a small cluster.

Two approximations remain, both understating supply: allocatable CPU has kubelet and system reservations removed but not what your own workloads have claimed, and DaemonSet requests are not subtracted. The check therefore sees more room than really exists and errs toward staying quiet rather than warning falsely.

A cluster that reports no schedulable nodes at all is treated as silence, not as zero capacity.

## Requires

The `kubernetes` provider must be able to **list nodes cluster-wide** at plan time. A credential scoped to one namespace cannot, and a plan run without cluster access cannot either: that is the case `k8s_capacity_check_enabled = false` is for.

## Reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [kubernetes_nodes.capacity](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/data-sources/nodes) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_demand_breakdown"></a> [demand\_breakdown](#input\_demand\_breakdown) | Human-readable breakdown of how peak\_cpu\_request\_millis was reached, interpolated into the warning message. Passed in rather than rebuilt here so this submodule needs none of the pod-sizing inputs, only the arithmetic they produce. | `string` | n/a | yes |
| <a name="input_docs_reference"></a> [docs\_reference](#input\_docs\_reference) | Where the warning points the operator for the full sizing discussion. Kept as an input so the root module names its own docs without this submodule hardcoding a path relative to a repository it may not be vendored into. | `string` | `"docs/operations.md → \"Sizing against cluster capacity\""` | no |
| <a name="input_model_readable"></a> [model\_readable](#input\_model\_readable) | Whether the caller could parse every CPU quantity that feeds peak\_cpu\_request\_millis. False silences the check entirely: an unreadable quantity makes the demand figure meaningless, and a wrong capacity warning is worse than none. Mirrors local.n8n\_capacity\_model\_readable in the root module. | `bool` | n/a | yes |
| <a name="input_peak_cpu_request_millis"></a> [peak\_cpu\_request\_millis](#input\_peak\_cpu\_request\_millis) | CPU, in millicores, that the n8n pod families request in total when every autoscaler sits at its ceiling simultaneously. Compared against the cluster's allocatable CPU to produce an advisory warning. The root module computes it from the per-pod CPU requests and the autoscaler maxima. | `number` | n/a | yes |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
