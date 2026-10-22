# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Contract tests for the module's public inputs and the values tree it renders.
#
# Every provider is mocked, so these run with no cluster and no credentials:
# the point is to assert what the module *plans*, which is where the module's
# own logic lives. Behaviour that only shows up against a live API belongs in
# tests/scripts/smoke-test.sh instead.
#
# Run: terraform test
#   (from the module root - requires terraform >= 1.11)

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  n8n_domain = "n8n.test.example.com"

  # cnpg is the default backend and no backup is the default state, so
  # check.cnpg_has_no_backup_configured fires on every run that has not
  # configured one. Acknowledged once here; the runs that are about the check
  # itself override it.
  cnpg_backup_acknowledged = true
}

run "postgres_backend_defaults_to_cnpg" {
  command = plan

  assert {
    condition     = var.postgres_backend == "cnpg"
    error_message = "postgres_backend must default to \"cnpg\", the in-cluster Postgres."
  }
}

run "redis_backend_defaults_to_valkey" {
  command = plan

  assert {
    condition     = var.redis_backend == "valkey"
    error_message = "redis_backend must default to \"valkey\", the in-cluster queue."
  }
}

# ── Enum validation rejects unknown values ────────────────────────────────────

run "postgres_backend_rejects_unknown_value" {
  command = plan

  variables {
    postgres_backend = "aurora"
  }

  expect_failures = [var.postgres_backend]
}

run "redis_backend_rejects_unknown_value" {
  command = plan

  variables {
    redis_backend = "memorystore"
  }

  expect_failures = [var.redis_backend]
}

# The module provisions no bucket and renders s3.enabled = false, so accepting
# "s3" here would emit N8N_EXECUTION_DATA_STORAGE_MODE=s3 against object storage
# that was never configured, and every pod would refuse to start. Rejected at
# plan time instead of discovered in a crash loop.
run "execution_data_storage_mode_rejects_object_storage" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "s3"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}

# ── Queue-depth worker autoscaling ───────────────────────────────────────────

run "keda_off_by_default_leaves_the_chart_cpu_hpa" {
  command = plan

  variables {
    postgres_backend = "cnpg"
    redis_backend    = "valkey"
    create_ingress   = false
  }

  assert {
    condition     = local.k8s_values_hpa.hpa.worker.enabled == true
    error_message = "With k8s_keda_installed = false the chart's CPU worker HPA must stay enabled - it is the only thing scaling workers on that path."
  }

  assert {
    condition     = length(keys(local.k8s_values_keda)) == 0
    error_message = "No KEDA values may be rendered unless the caller attests the operator is installed."
  }
}

run "keda_attestation_swaps_cpu_hpa_for_queue_depth" {
  command = plan

  variables {
    postgres_backend = "cnpg"
    redis_backend    = "valkey"
    create_ingress   = false

    k8s_keda_installed               = true
    n8n_worker_keda_min_replicas     = 1
    n8n_worker_keda_max_replicas     = 12
    n8n_worker_keda_jobs_per_replica = 7
  }

  # The property that matters: exactly one controller owns the worker
  # Deployment. Both-on is the failure this pair of assertions exists to
  # prevent, and it cannot be caught by asserting either one alone.
  assert {
    condition     = local.k8s_values_hpa.hpa.worker.enabled == false
    error_message = "The chart's CPU worker HPA must be disabled when KEDA scales workers, or two controllers fight over the worker Deployment's replica count."
  }

  assert {
    condition     = local.k8s_values_keda.keda.enabled == true
    error_message = "k8s_keda_installed = true must render the chart's KEDA values."
  }

  assert {
    condition = (
      local.k8s_values_keda.keda.worker.minReplicaCount == 1 &&
      local.k8s_values_keda.keda.worker.maxReplicaCount == 12
    )
    error_message = "The ScaledObject must be bounded by the same n8n_worker_keda_* inputs the CPU HPA used, so a config tuned against one does not need retyping for the other."
  }

  assert {
    condition     = length(local.k8s_values_keda.keda.worker.triggers) == 2
    error_message = "Two triggers are required: bull:jobs:wait for queued work and bull:jobs:active for jobs held by a worker awaiting a task runner."
  }

  # The scaling client must read the same endpoint the workload does. Drift
  # between them scales against a queue nobody is filling.
  assert {
    condition     = alltrue([for t in local.k8s_values_keda.keda.worker.triggers : startswith(t.metadata.address, local.k8s_redis_host)])
    error_message = "KEDA triggers must address the same Redis endpoint the n8n workload uses."
  }

  # The AUTH token must reach KEDA by env reference, never as a literal in the
  # ScaledObject manifest.
  assert {
    condition     = alltrue([for t in local.k8s_values_keda.keda.worker.triggers : t.metadata.passwordFromEnv == "QUEUE_BULL_REDIS_PASSWORD"])
    error_message = "KEDA must resolve the Redis password from the worker pod's environment, not carry it in the ScaledObject."
  }

  # No TriggerAuthentication object exists to name: passwordFromEnv above
  # resolves the token from the worker container directly. An
  # authenticationRef = { name = "" } key used to be rendered regardless.
  assert {
    condition     = alltrue([for t in local.k8s_values_keda.keda.worker.triggers : !contains(keys(t), "authenticationRef")])
    error_message = "A KEDA trigger must not carry an authenticationRef naming a TriggerAuthentication object that cannot exist."
  }
}

run "webhook_autoscaling_is_owned_by_the_chart" {
  command = plan

  variables {
    postgres_backend = "cnpg"
    redis_backend    = "valkey"
    create_ingress   = false

  }

  assert {
    condition     = local.k8s_values_hpa.hpa.webhookProcessor.enabled == true
    error_message = "The chart's webhookProcessor HPA must still be enabled - the module-managed one being absent should not mean no webhook autoscaling."
  }
}

# ── Multi-domain Ingress ──────────────────────────────────────────────────────
# n8n_domain alone renders one host; every name in n8n_additional_domains has to
# reach both the Ingress rules and the TLS block, or the certificate ends up
# covering names the Ingress does not serve.

run "kubernetes_ingress_serves_one_host_by_default" {
  command = plan

  variables {
    postgres_backend           = "cnpg"
    redis_backend              = "valkey"
    create_ingress             = true
    k8s_ingress_cluster_issuer = "letsencrypt-prod"
  }

  assert {
    condition     = local.k8s_ingress_hosts == tolist(["n8n.test.example.com"])
    error_message = "With no additional domains the host list must be exactly the canonical hostname."
  }

  assert {
    condition     = length(local.k8s_values_ingress.ingress.tls) == 1
    error_message = "One TLS block covering every host, so cert-manager issues a single Certificate."
  }
  # The third assertion this run used to carry here, that
  # modules/cluster-capacity actually instantiates on this path, now lives in
  # tests/opentofu-gaps/cluster-capacity-module-instantiation-gap.tftest.hcl:
  # OpenTofu v1.13.2's test runner cannot resolve length(module.x) for a
  # count-conditioned module with zero output blocks (see that file's header).
}

# The node read is an ordinary data source, so a plan somewhere the cluster is
# unreachable fails on it. This is the way out, and it has to actually remove
# the read rather than only silencing the warning.
run "the_capacity_check_can_be_turned_off" {
  command = plan

  variables {
    postgres_backend = "cnpg"
    redis_backend    = "valkey"
    create_ingress   = false

    k8s_capacity_check_enabled = false
  }

  assert {
    condition     = length(module.cluster_capacity) == 0
    error_message = "k8s_capacity_check_enabled = false must remove the submodule, and with it the node read - not just suppress the warning."
  }
}

run "kubernetes_ingress_serves_every_configured_domain" {
  command = plan

  variables {
    postgres_backend           = "cnpg"
    redis_backend              = "valkey"
    create_ingress             = true
    k8s_ingress_cluster_issuer = "letsencrypt-prod"

    # Mixed case on purpose: Kubernetes rejects an uppercase Ingress host, so
    # the module has to normalize rather than pass the caller's string through.
    n8n_additional_domains = ["Hooks.Test.Example.com", "alt.test.example.com"]
  }

  assert {
    condition     = local.k8s_ingress_hosts == tolist(["n8n.test.example.com", "hooks.test.example.com", "alt.test.example.com"])
    error_message = "Every configured domain must be routed, lowercased, with the canonical hostname first."
  }

  assert {
    condition     = length(local.k8s_values_ingress.ingress.hosts) == 3
    error_message = "The chart's main Ingress must carry a rule per host."
  }

  assert {
    condition     = alltrue([for h in local.k8s_values_ingress.ingress.hosts : h.paths == [{ path = "/", pathType = "Prefix" }]])
    error_message = "Every host serves the editor and API at / on the main Ingress; the chart's webhook Ingress claims the webhook prefixes ahead of it."
  }

  # One certificate, every name. Two TLS blocks would mean two Certificates
  # racing for the same Ingress.
  assert {
    condition     = length(local.k8s_values_ingress.ingress.tls) == 1
    error_message = "TLS must stay a single secret covering every host."
  }

  assert {
    condition     = local.k8s_values_ingress.ingress.tls[0].hosts == local.k8s_ingress_hosts
    error_message = "The TLS block must name every routed host, or cert-manager issues a certificate that does not cover them all."
  }

  # The chart's webhook Ingress ranges over ingress.hosts, so the additional
  # names are routed to the webhook processors as well as the mains without a
  # second host list.
  assert {
    condition     = local.k8s_values_ingress.ingress.webhookProcessor.tls[0].hosts == local.k8s_ingress_hosts
    error_message = "The webhook Ingress must carry the same TLS host list as the main one."
  }

  # The chart takes only enabled/className/annotations/tls here and hardcodes
  # the five webhook path prefixes itself. Passing hosts or paths looks like
  # configuration and is silently discarded, which is how only /webhook ended up
  # routed while the block appeared to name it.
  assert {
    condition     = !contains(keys(local.k8s_values_ingress.ingress.webhookProcessor), "paths") && !contains(keys(local.k8s_values_ingress.ingress.webhookProcessor), "hosts")
    error_message = "The webhookProcessor values block must not carry hosts or paths keys: the chart ignores both."
  }
}

# N8N_WEBHOOK_URL sits in kubernetes_secret.n8n, but the chart wires only
# four keys from secretRefs.existingSecret, so on this backend it was never
# read. n8n then built webhook URLs from N8N_PROTOCOL + N8N_HOST - and
# N8N_PROTOCOL is "http", because TLS terminates at the ingress. Every
# advertised URL was http:// for an https:// endpoint, and n8n_webhook_url
# did nothing at all.
run "webhook_url_reaches_the_pods_on_the_kubernetes_backend" {
  command = plan

  variables {
    postgres_backend           = "cnpg"
    redis_backend              = "valkey"
    create_ingress             = true
    k8s_ingress_cluster_issuer = "letsencrypt-prod"
  }

  assert {
    condition     = local.k8s_values_webhook.webhook.url == "https://n8n.test.example.com"
    error_message = "With no override, N8N_WEBHOOK_URL must be https:// against the canonical ingress host."
  }

  # On a single host the callback follows the same name as everything else.
  # Asserted here too so the output is covered on the path where the chart,
  # not the module, renders N8N_EDITOR_BASE_URL.
  assert {
    condition     = output.n8n_oauth_callback_url == "https://n8n.test.example.com/rest/oauth2-credential/callback"
    error_message = "On a single host the OAuth callback URL must follow the ingress host; got ${output.n8n_oauth_callback_url}."
  }

  # Through the chart's typed key, never as a second config.extraEnv entry: the
  # chart already emits N8N_WEBHOOK_URL from its own ConfigMap, and two entries
  # of one name in a container's env list fail the strategic merge patch on
  # every later helm upgrade.
  assert {
    condition     = !contains([for e in local.k8s_values_config.config.extraEnv : e.name], "N8N_WEBHOOK_URL")
    error_message = "N8N_WEBHOOK_URL must not also be appended to config.extraEnv; the duplicate breaks helm upgrade."
  }
}

# The wiring this asserts was documented long before it existed: the variable
# description promised secretRefs.existingSecret would follow the caller's
# Secret, while locals.tf hardcoded "n8n-secrets". With the module Secret
# count-gated to zero on this path, the chart was pointed at a Secret nothing
# created, and every pod sat in CreateContainerConfigError while the Secret
# the caller wrote was never read, unless it was itself named "n8n-secrets"
# and the hardcoded string happened to resolve to it.
run "the_encryption_key_secret_ref_reaches_the_chart" {
  command = plan

  variables {
    n8n_encryption_key_secret_ref = { name = "caller-n8n-secrets" }
  }

  assert {
    condition     = local.k8s_values_secret_refs.secretRefs.existingSecret == "caller-n8n-secrets"
    error_message = "secretRefs.existingSecret must name the caller's Secret when n8n_encryption_key_secret_ref is set; got ${local.k8s_values_secret_refs.secretRefs.existingSecret}."
  }

  assert {
    condition     = length(kubernetes_secret.n8n) == 0
    error_message = "The module Secret must not be created when the caller supplies their own: the chart reads all four keys from one Secret, and two Secrets means one of them is dead."
  }

  assert {
    condition     = length(random_id.n8n_encryption_key) == 0
    error_message = "No encryption key may be generated when the caller's Secret carries it: a module-held value that differs from the served one is worse than none."
  }
}

# The default path, pinned so the conditional above cannot drift: with no ref,
# the chart reads the module-owned Secret and that Secret exists.
run "the_default_path_serves_the_module_secret" {
  command = plan

  assert {
    condition     = local.k8s_values_secret_refs.secretRefs.existingSecret == "n8n-secrets"
    error_message = "With no n8n_encryption_key_secret_ref, secretRefs.existingSecret must stay on the module-owned Secret; got ${local.k8s_values_secret_refs.secretRefs.existingSecret}."
  }

  assert {
    condition     = length(kubernetes_secret.n8n) == 1
    error_message = "The module Secret must exist on the default path: it is the Secret the chart is pointed at."
  }
}

# The chart hardcodes the key name it reads on this path, so any other key is
# rejected at plan rather than accepted and ignored.
run "the_encryption_key_secret_ref_rejects_a_renamed_key" {
  command = plan

  variables {
    n8n_encryption_key_secret_ref = { name = "caller-n8n-secrets", key = "ENCRYPTION_KEY" }
  }

  expect_failures = [var.n8n_encryption_key_secret_ref]
}

run "webhook_url_can_name_a_different_host_than_the_editor" {
  command = plan

  variables {
    postgres_backend = "cnpg"
    redis_backend    = "valkey"
    create_ingress   = false

    # The split-ingress topology: the editor lives on n8n_domain, webhooks are
    # advertised somewhere else entirely. Without this the input was accepted
    # and discarded, which breaks that topology silently.
    n8n_webhook_url = "https://hooks.test.example.com"
  }

  # webhook.url is deliberately emptied on this path, which is the opposite of
  # what the single-host run above asserts. Chart 1.16.0's configmap.yaml
  # falls back to webhook.url for N8N_EDITOR_BASE_URL when it has no editor.url
  # (this module never sets it) and no ingress host to read, so leaving
  # webhook.url set labels the editor with the webhook hostname and every
  # OAuth2 redirect URI 404s. Emptying it suppresses both chart keys
  # (N8N_WEBHOOK_URL and N8N_EDITOR_BASE_URL) and both configMapKeyRef
  # entries, so the module can set them from extraEnv without the duplicate
  # that breaks helm upgrade.
  assert {
    condition     = local.k8s_values_webhook.webhook.url == ""
    error_message = "On a split ingress the chart's webhook.url must be empty so it renders neither URL key."
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : "${e.name}=${e.value}"],
      "N8N_WEBHOOK_URL=https://hooks.test.example.com",
    )
    error_message = "Emptying webhook.url drops the chart's N8N_WEBHOOK_URL, so extraEnv must carry it back."
  }

  # The regression this whole path exists for.
  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : "${e.name}=${e.value}"],
      "N8N_EDITOR_BASE_URL=https://n8n.test.example.com",
    )
    error_message = "N8N_EDITOR_BASE_URL must name the editor host, not the webhook host."
  }

  # Asserted on the output as well as the local, because the split-hostname
  # examples assert against the output and a correct local wired to the wrong
  # output would leave them passing while the module reported the editor
  # address as the webhook one.
  assert {
    condition     = output.n8n_webhook_url == "https://hooks.test.example.com"
    error_message = "n8n_webhook_url output must carry the advertised webhook base URL; got ${output.n8n_webhook_url}."
  }

  assert {
    condition     = output.n8n_webhook_url != output.n8n_url
    error_message = "With n8n_webhook_url set to a different host, the two URL outputs must differ."
  }

  # The output exists so a caller can register the right redirect URI without
  # deriving it. Asserted against the webhook host as well as for the editor
  # one, because naming the webhook host is the specific mistake that produced
  # a 404 at the end of every consent flow.
  assert {
    condition     = output.n8n_oauth_callback_url == "https://n8n.test.example.com/rest/oauth2-credential/callback"
    error_message = "The OAuth callback URL must sit on the editor host; got ${output.n8n_oauth_callback_url}."
  }

  assert {
    condition     = !startswith(output.n8n_oauth_callback_url, output.n8n_webhook_url)
    error_message = "The OAuth callback URL must never sit on the webhook host: that host routes only the webhook prefixes, to pods serving no /rest routes."
  }
}

# k8s_ingress_host is documented as "only used when create_ingress = true", and
# homelab-split-ingress leaves it unset for that reason. The editor base URL
# must honour that: sourcing it from k8s_ingress_host would let a value the
# docs call ignored decide which host receives OAuth2 callbacks.
run "the_editor_base_url_ignores_k8s_ingress_host_when_no_ingress_is_created" {
  command = plan

  variables {
    postgres_backend = "cnpg"
    redis_backend    = "valkey"
    create_ingress   = false
    k8s_ingress_host = "stale.test.example.com"
    n8n_webhook_url  = "https://hooks.test.example.com"
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : "${e.name}=${e.value}"],
      "N8N_EDITOR_BASE_URL=https://n8n.test.example.com",
    )
    error_message = "With create_ingress = false the editor base URL must come from n8n_domain, not k8s_ingress_host."
  }
}

run "the_webhook_url_output_falls_back_to_the_editor_url" {
  command = plan

  variables {
    postgres_backend = "cnpg"
    redis_backend    = "valkey"
  }

  # The single-hostname default, which is what four of the five examples run:
  # n8n advertises webhooks on the same name it serves the editor on.
  assert {
    condition     = output.n8n_webhook_url == output.n8n_url
    error_message = "Without n8n_webhook_url the advertised base URL must equal n8n_url; got ${output.n8n_webhook_url} and ${output.n8n_url}."
  }
}

run "the_webhook_url_output_follows_the_routed_host_not_N8N_HOST" {
  command = plan

  variables {
    postgres_backend = "cnpg"
    redis_backend    = "valkey"

    # The one case where the two URL outputs legitimately disagree, and the
    # case the fallback assertion above cannot see because it never sets this.
    k8s_ingress_host = "routed.test.example.com"
    n8n_domain       = "canonical.test.example.com"
  }

  # WEBHOOK_URL falls back to the hostname the Ingress actually routes, because
  # that is the name an external caller can reach. n8n_url reports N8N_HOST,
  # which is n8n_domain. Asserted rather than left implied: the output's first
  # description claimed the two were equal until n8n_webhook_url was set, which
  # is true only while k8s_ingress_host is unset.
  assert {
    condition     = output.n8n_webhook_url == "https://routed.test.example.com"
    error_message = "The advertised webhook base URL must follow k8s_ingress_host when set; got ${output.n8n_webhook_url}."
  }

  assert {
    condition     = output.n8n_url == "https://canonical.test.example.com"
    error_message = "n8n_url must report n8n_domain (N8N_HOST); got ${output.n8n_url}."
  }
}

run "kubernetes_ingress_normalizes_case_variant_duplicates" {
  command = plan

  variables {
    postgres_backend           = "cnpg"
    redis_backend              = "valkey"
    create_ingress             = true
    k8s_ingress_cluster_issuer = "letsencrypt-prod"

    # Passes the variable's own duplicate validation, which compares strings
    # exactly, and would still render two rules for one hostname. Kubernetes
    # accepts that Ingress and ingress-nginx picks one rule arbitrarily.
    n8n_additional_domains = ["N8N.Test.Example.com"]
  }

  assert {
    condition     = local.k8s_ingress_hosts == tolist(["n8n.test.example.com"])
    error_message = "A domain differing from the canonical hostname only in case must collapse to one rule."
  }
}

# A mixed-case k8s_ingress_host passed every existing check (n8n_domain's
# FQDN validation accepts A-Z) and produced a lowercased Ingress host list,
# but the TLS Secret name, the editor base URL and the webhook URL fallback
# all kept the caller's original case: a RFC 1123 Secret name is
# lowercase-only, so the apply failed on a generated internal name with an
# error that never mentioned casing, and the two URL locals disagreed with
# the routed, lowercased Ingress host.
run "a_mixed_case_ingress_host_normalizes_everywhere_it_is_used" {
  command = plan

  variables {
    postgres_backend = "cnpg"
    redis_backend    = "valkey"
    create_ingress   = true
    k8s_ingress_host = "Editor.Test.Example.Com"
  }

  assert {
    condition     = local.k8s_ingress_host_effective == "editor.test.example.com"
    error_message = "k8s_ingress_host_effective must lower-case the override branch."
  }

  assert {
    condition     = local.k8s_ingress_tls_secret == "editor-test-example-com-tls"
    error_message = "The TLS Secret name must derive from the lower-cased host; Kubernetes Secret names are lowercase-only RFC 1123 subdomains."
  }

  assert {
    condition     = local.k8s_editor_base_url == "https://editor.test.example.com"
    error_message = "The editor base URL must use the lower-cased host."
  }

  assert {
    condition     = local.k8s_webhook_url == "https://editor.test.example.com"
    error_message = "The webhook URL fallback must use the lower-cased host."
  }
}

# F-046: k8s_ingress_host becomes an Ingress host and the webhook fallback
# address, so a typo used to be served rather than caught at plan time.
run "k8s_ingress_host_rejects_a_malformed_hostname" {
  command = plan

  variables {
    k8s_ingress_host = "not a host"
  }

  expect_failures = [var.k8s_ingress_host]
}

run "k8s_ingress_host_empty_string_still_falls_back" {
  command = plan

  variables {
    k8s_ingress_host = ""
  }

  assert {
    condition     = var.k8s_ingress_host == ""
    error_message = "The empty string must stay the documented fall-back-to-n8n_domain spelling, not a rejected hostname."
  }
}

# n8n_domain itself normalizes the same way when no k8s_ingress_host override
# is set, since it is what N8N_HOST, the editor/webhook URL fallbacks and the
# TLS secret name all fall back to.
run "a_mixed_case_n8n_domain_normalizes_everywhere_it_is_used" {
  command = plan

  variables {
    postgres_backend = "cnpg"
    redis_backend    = "valkey"
    create_ingress   = true
    n8n_domain       = "N8N.Test.Example.com"
  }

  assert {
    condition     = local.n8n_domain == "n8n.test.example.com"
    error_message = "n8n_domain must be lower-cased once at its single source."
  }

  assert {
    condition     = nonsensitive(kubernetes_secret.n8n[0].data["N8N_HOST"]) == "n8n.test.example.com"
    error_message = "N8N_HOST must be lower-cased: it is what n8n advertises as its own identity."
  }

  assert {
    condition     = local.k8s_ingress_tls_secret == "n8n-test-example-com-tls"
    error_message = "The TLS Secret name must derive from the lower-cased n8n_domain fallback."
  }

  assert {
    condition     = output.n8n_url == "https://n8n.test.example.com"
    error_message = "n8n_url must report the lower-cased n8n_domain."
  }
}

run "webhook_ingress_is_absent_when_the_caller_owns_routing" {
  command = plan

  variables {
    postgres_backend = "cnpg"
    redis_backend    = "valkey"
    create_ingress   = false

    # Supported alongside create_ingress = false: the caller routes the names
    # itself. Nothing here may warn about a certificate the module was never
    # asked to issue.
    n8n_additional_domains = ["hooks.test.example.com"]
  }

  assert {
    condition     = local.k8s_values_ingress.ingress.enabled == false
    error_message = "create_ingress = false must leave the chart's main Ingress off."
  }

  # Ungated, this left a chart-owned webhook Ingress behind with an empty rule
  # set on a deployment whose routing the caller had taken over.
  assert {
    condition     = local.k8s_values_ingress.ingress.webhookProcessor.enabled == false
    error_message = "create_ingress = false must leave the chart's webhook Ingress off too."
  }
}


# ── Workload controls actually reach the pods ─────────────────────────────────
# These inputs were declared, validated and documented for a long time while
# reaching nothing on this platform: they were only ever rendered into a Helm
# release that no longer exists. Setting one and having it silently discarded
# is worse than not offering it, so each is asserted against the rendered
# values tree rather than trusted to stay wired.

# The chart reads these from the TOP-LEVEL executions block
# (_environment-helpers.tpl, "n8n.executionsEnv"). An earlier version of this
# run asserted them under config.executions, a key the chart never reads, so
# the test passed while the values were silently dropped. Asserting against
# k8s_values_final rather than an intermediate local keeps a merge-order
# mistake from reintroducing that.
run "execution_limits_and_pruning_reach_the_chart" {
  command = plan

  variables {
    n8n_execution_timeout           = 3600
    n8n_execution_timeout_max       = 7200
    n8n_execution_concurrency_limit = 25
    n8n_pruning_max_age             = 168
    n8n_pruning_max_count           = 15000
  }

  assert {
    condition     = local.k8s_values_final.executions.timeout == 3600
    error_message = "n8n_execution_timeout must reach the chart's top-level executions.timeout."
  }

  assert {
    condition     = local.k8s_values_final.executions.timeoutMax == 7200
    error_message = "n8n_execution_timeout_max must reach the chart's top-level executions.timeoutMax."
  }

  assert {
    condition     = local.k8s_values_final.executions.concurrency.productionLimit == 25
    error_message = "n8n_execution_concurrency_limit must reach the chart's top-level executions.concurrency.productionLimit."
  }

  assert {
    condition     = local.k8s_values_final.executions.pruning.enabled == true && local.k8s_values_final.executions.pruning.maxAge == 168
    error_message = "Pruning must stay enabled with n8n_pruning_max_age reaching executions.pruning.maxAge."
  }

  assert {
    condition     = local.k8s_values_final.executions.pruning.maxCount == 15000
    error_message = "n8n_pruning_max_count must reach the chart's top-level executions.pruning.maxCount."
  }

  # The dead subtree must stay dead: config.executions is not a key the chart
  # reads, so rendering it again would be a silent no-op wearing the costume of
  # configuration.
  assert {
    condition     = !contains(keys(local.k8s_values_final.config), "executions")
    error_message = "config.executions must not be rendered; the chart only reads the top-level executions block."
  }
}

# F-015: the numeric execution/pruning inputs above used to accept anything a
# `number` admits; each now floors and bounds to the spellings n8n actually
# defines. One rejection probe per input, plus the execution_timeout_max
# cross-check against execution_timeout.
run "execution_timeout_rejects_a_fraction" {
  command = plan

  variables {
    n8n_execution_timeout = 3600.5
  }

  expect_failures = [var.n8n_execution_timeout]
}

run "execution_timeout_rejects_zero" {
  command = plan

  variables {
    n8n_execution_timeout = 0
  }

  expect_failures = [var.n8n_execution_timeout]
}

run "execution_timeout_accepts_the_disabled_spelling" {
  command = plan

  variables {
    n8n_execution_timeout = -1
  }

  assert {
    condition     = local.k8s_values_final.executions.timeout == -1
    error_message = "-1 must still disable the timeout."
  }
}

run "execution_timeout_max_rejects_a_fraction" {
  command = plan

  variables {
    n8n_execution_timeout_max = 7200.5
  }

  expect_failures = [var.n8n_execution_timeout_max]
}

run "execution_timeout_max_rejects_a_ceiling_below_the_default" {
  command = plan

  variables {
    n8n_execution_timeout     = 7200
    n8n_execution_timeout_max = 3600
  }

  expect_failures = [var.n8n_execution_timeout_max]
}

run "execution_timeout_max_allows_an_unlimited_ceiling_over_a_finite_default" {
  command = plan

  variables {
    n8n_execution_timeout     = 7200
    n8n_execution_timeout_max = -1
  }

  assert {
    condition     = local.k8s_values_final.executions.timeoutMax == -1
    error_message = "An unlimited ceiling (-1) must be allowed over any finite default."
  }
}

run "pruning_max_age_rejects_a_fraction" {
  command = plan

  variables {
    n8n_pruning_max_age = 168.5
  }

  expect_failures = [var.n8n_pruning_max_age]
}

run "pruning_max_age_rejects_zero" {
  command = plan

  variables {
    n8n_pruning_max_age = 0
  }

  expect_failures = [var.n8n_pruning_max_age]
}

run "pruning_max_count_rejects_a_fraction" {
  command = plan

  variables {
    n8n_pruning_max_count = 15000.5
  }

  expect_failures = [var.n8n_pruning_max_count]
}

run "pruning_max_count_accepts_zero_as_no_limit" {
  command = plan

  variables {
    n8n_pruning_max_count = 0
  }

  assert {
    condition     = local.k8s_values_final.executions.pruning.maxCount == 0
    error_message = "0 must still mean no count limit."
  }
}

# n8n_pruning_enabled, n8n_pruning_hard_delete_buffer,
# n8n_pruning_hard_delete_interval and n8n_pruning_soft_delete_interval: the
# four pruning inputs the fork carried that this module lacked. enabled
# defaults true (today's hardcoded value, unchanged); the three cadence
# inputs default null and are merged into executions.pruning only when set,
# so an unconfigured deployment renders exactly what it always has (chart's
# own hardDeleteBuffer/hardDeleteInterval/softDeleteInterval defaults apply
# via Helm's values merge, same as before these inputs existed).
run "pruning_cadence_defaults_render_no_keys" {
  command = plan

  assert {
    condition     = local.k8s_values_final.executions.pruning.enabled == true
    error_message = "n8n_pruning_enabled must default to true, matching today's hardcoded value."
  }

  assert {
    condition = !(
      contains(keys(local.k8s_values_final.executions.pruning), "hardDeleteBuffer") ||
      contains(keys(local.k8s_values_final.executions.pruning), "hardDeleteInterval") ||
      contains(keys(local.k8s_values_final.executions.pruning), "softDeleteInterval")
    )
    error_message = "At the defaults, none of the three cadence keys may be rendered: the chart's own values.yaml defaults must be what applies, exactly as before these inputs existed."
  }
}

run "pruning_disabled_reaches_the_chart" {
  command = plan

  variables {
    n8n_pruning_enabled = false
  }

  assert {
    condition     = local.k8s_values_final.executions.pruning.enabled == false
    error_message = "n8n_pruning_enabled must reach the chart's top-level executions.pruning.enabled."
  }

  assert {
    condition     = local.k8s_values_final.executions.pruning.maxAge == 336 && local.k8s_values_final.executions.pruning.maxCount == 10000
    error_message = "maxAge/maxCount must still render while pruning is disabled, so the policy resumes unchanged if it is switched back on."
  }
}

run "pruning_cadence_inputs_reach_the_chart_when_set" {
  command = plan

  variables {
    n8n_pruning_hard_delete_buffer   = 2
    n8n_pruning_hard_delete_interval = 30
    n8n_pruning_soft_delete_interval = 120
  }

  assert {
    condition = (
      local.k8s_values_final.executions.pruning.hardDeleteBuffer == 2 &&
      local.k8s_values_final.executions.pruning.hardDeleteInterval == 30 &&
      local.k8s_values_final.executions.pruning.softDeleteInterval == 120
    )
    error_message = "Each pruning cadence input must reach its chart key: the chart renders the EXECUTIONS_DATA_*DELETE* env vars from exactly these."
  }
}

run "pruning_hard_delete_buffer_rejects_a_fraction" {
  command = plan

  variables {
    n8n_pruning_hard_delete_buffer = 1.5
  }

  expect_failures = [var.n8n_pruning_hard_delete_buffer]
}

run "pruning_hard_delete_buffer_rejects_zero" {
  command = plan

  variables {
    n8n_pruning_hard_delete_buffer = 0
  }

  expect_failures = [var.n8n_pruning_hard_delete_buffer]
}

run "pruning_hard_delete_interval_rejects_a_fraction" {
  command = plan

  variables {
    n8n_pruning_hard_delete_interval = 15.5
  }

  expect_failures = [var.n8n_pruning_hard_delete_interval]
}

run "pruning_hard_delete_interval_rejects_zero" {
  command = plan

  variables {
    n8n_pruning_hard_delete_interval = 0
  }

  expect_failures = [var.n8n_pruning_hard_delete_interval]
}

run "pruning_soft_delete_interval_rejects_a_fraction" {
  command = plan

  variables {
    n8n_pruning_soft_delete_interval = 60.5
  }

  expect_failures = [var.n8n_pruning_soft_delete_interval]
}

run "pruning_soft_delete_interval_rejects_zero" {
  command = plan

  variables {
    n8n_pruning_soft_delete_interval = 0
  }

  expect_failures = [var.n8n_pruning_soft_delete_interval]
}

# The three cadence env names are reserved exact names (no EXECUTIONS_DATA_
# prefix in n8n_managed_env_prefixes), same shape as the EXECUTIONS_DATA_SAVE_*
# reservations above.
run "pruning_hard_delete_buffer_name_is_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "EXECUTIONS_DATA_HARD_DELETE_BUFFER", value = "2" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "pruning_hard_delete_interval_name_is_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "EXECUTIONS_DATA_PRUNE_HARD_DELETE_INTERVAL", value = "30" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "pruning_soft_delete_interval_name_is_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "EXECUTIONS_DATA_PRUNE_SOFT_DELETE_INTERVAL", value = "120" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# n8n_timezone: shape only, since the IANA database is not readable from
# Terraform. A three-segment zone (America/Argentina/Buenos_Aires) and an
# Etc/GMT+5-style offset must both still pass.
run "timezone_rejects_an_empty_string" {
  command = plan

  variables {
    n8n_timezone = ""
  }

  expect_failures = [var.n8n_timezone]
}

run "timezone_rejects_a_space_separated_name" {
  command = plan

  variables {
    n8n_timezone = "New York"
  }

  expect_failures = [var.n8n_timezone]
}

run "timezone_accepts_a_three_segment_zone" {
  command = plan

  variables {
    n8n_timezone = "America/Argentina/Buenos_Aires"
  }

  assert {
    condition     = local.k8s_values_config.config.timezone == "America/Argentina/Buenos_Aires"
    error_message = "A three-segment IANA zone must still be accepted and rendered."
  }
}

# n8n's environment variable reference documents
# N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES and
# N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES. An earlier version of this module
# emitted both without the NODE_ infix, so n8n never saw them and silently
# fell back to its own limits; the misspellings were also absent from
# n8n_managed_env_names, which left the correct names free for n8n_extra_env
# and would have produced a duplicate env entry once the names were aligned.
run "the_compression_limits_render_the_names_n8n_reads" {
  command = plan

  variables {
    n8n_compression_max_decompressed_size_bytes = 1073741824
    n8n_compression_max_zip_entries             = 250
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES", value = "1073741824" },
    )
    error_message = "n8n_compression_max_decompressed_size_bytes must render as N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES; without the NODE_ infix n8n ignores it."
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES", value = "250" },
    )
    error_message = "n8n_compression_max_zip_entries must render as N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES; without the NODE_ infix n8n ignores it."
  }

  # Every name the module renders into config.extraEnv must be reserved, or
  # the escape hatch can set the same variable a second time and wedge every
  # later helm upgrade.
  assert {
    condition = alltrue([
      for e in local.k8s_values_config.config.extraEnv :
      contains(local.n8n_managed_env_names, e.name) ||
      anytrue([for p in local.n8n_managed_env_prefixes : startswith(e.name, p)])
    ])
    error_message = "Every name the module renders into config.extraEnv must be reserved in n8n_managed_env_names or covered by a managed prefix."
  }
}

# _helpers.tpl's n8n.taskRunnerContainer helper renders
# `toYaml .Values.taskRunners.resources` into the sidecar container. The
# module used to write these four quantities under resources.taskRunner, a
# key no template in the chart reads and which the top-level resources block
# (main, worker, webhookProcessor) does not define, so every sidecar ran on
# the chart's own 100m/256Mi defaults no matter what the caller set.
run "the_task_runner_resources_reach_the_sidecar_not_a_dead_key" {
  command = plan

  variables {
    n8n_task_runners_enabled       = true
    n8n_task_runner_cpu_request    = "250m"
    n8n_task_runner_cpu_limit      = "1500m"
    n8n_task_runner_memory_request = "640Mi"
    n8n_task_runner_memory_limit   = "2Gi"
  }

  assert {
    condition = (
      local.k8s_values_task_runners.taskRunners.resources.requests.cpu == "250m" &&
      local.k8s_values_task_runners.taskRunners.resources.requests.memory == "640Mi" &&
      local.k8s_values_task_runners.taskRunners.resources.limits.cpu == "1500m" &&
      local.k8s_values_task_runners.taskRunners.resources.limits.memory == "2Gi"
    )
    error_message = "The n8n_task_runner_* quantities must render into taskRunners.resources, the only key the chart reads for the sidecar container."
  }

  # Guards the regression directly: back under resources.taskRunner the
  # values are still in the values tree, still visible in `helm get values`,
  # and still read by nothing.
  assert {
    condition     = !contains(keys(local.k8s_values_resources.resources), "taskRunner")
    error_message = "The top-level resources block must not carry a taskRunner key; the chart defines main, worker and webhookProcessor there and reads nothing else."
  }
}

# -1 lets n8n_worker_concurrency govern instead: this used to default to 100,
# which every worker read independently with no coordination between them
# (a live finding, see CHANGELOG and the locals.tf comment above
# k8s_values_executions). Both sides of that interaction are asserted here:
# productionLimit renders -1 at the default, and queueMode.workerConcurrency
# still reaches the chart from n8n_worker_concurrency independently of it.
run "execution_concurrency_limit_defaults_to_unset_so_worker_concurrency_governs" {
  command = plan

  assert {
    condition     = var.n8n_execution_concurrency_limit == -1
    error_message = "n8n_execution_concurrency_limit must default to -1, so the worker's own --concurrency flag (n8n_worker_concurrency) governs instead of a fixed instance-wide cap."
  }

  assert {
    condition     = local.k8s_values_final.executions.concurrency.productionLimit == -1
    error_message = "The default -1 must reach the chart's top-level executions.concurrency.productionLimit unchanged."
  }

  assert {
    condition     = local.k8s_values_final.queueMode.workerConcurrency == var.n8n_worker_concurrency
    error_message = "n8n_worker_concurrency must reach queueMode.workerConcurrency regardless of n8n_execution_concurrency_limit; the two are independent inputs that only interact at the n8n process level (worker.ts), not in this module's values tree."
  }
}

run "execution_concurrency_limit_rejects_zero" {
  command = plan

  variables {
    n8n_execution_concurrency_limit = 0
  }

  expect_failures = [var.n8n_execution_concurrency_limit]
}

run "execution_concurrency_limit_rejects_a_fraction" {
  command = plan

  variables {
    n8n_execution_concurrency_limit = 2.5
  }

  expect_failures = [var.n8n_execution_concurrency_limit]
}

# executions.data (saveOnError/saveOnSuccess/saveOnProgress/saveManualExecutions)
# is rendered unconditionally by the chart, so unlike the limits above there is
# no "stays dead" half to prove: the defaults already match what the chart
# would bake in on its own, and this proves both the default wiring and a
# caller override reach the same top-level executions.data key.
run "execution_data_save_settings_reach_the_chart" {
  command = plan

  assert {
    condition = (
      local.k8s_values_final.executions.data.saveOnError == "all" &&
      local.k8s_values_final.executions.data.saveOnSuccess == "all" &&
      local.k8s_values_final.executions.data.saveOnProgress == false &&
      local.k8s_values_final.executions.data.saveManualExecutions == true
    )
    error_message = "The four n8n_executions_data_save_* defaults must reach executions.data unchanged, matching n8n's own defaults (all/all/false/true)."
  }
}

run "execution_data_save_settings_can_be_overridden" {
  command = plan

  variables {
    n8n_executions_data_save_on_success        = "none"
    n8n_executions_data_save_on_error          = "none"
    n8n_executions_data_save_on_progress       = true
    n8n_executions_data_save_manual_executions = false
  }

  assert {
    condition = (
      local.k8s_values_final.executions.data.saveOnError == "none" &&
      local.k8s_values_final.executions.data.saveOnSuccess == "none" &&
      local.k8s_values_final.executions.data.saveOnProgress == true &&
      local.k8s_values_final.executions.data.saveManualExecutions == false
    )
    error_message = "Each n8n_executions_data_save_* input must reach its own executions.data key independently."
  }
}

run "execution_data_save_on_success_rejects_an_unknown_enum_value" {
  command = plan

  variables {
    n8n_executions_data_save_on_success = "first"
  }

  expect_failures = [var.n8n_executions_data_save_on_success]
}

run "execution_data_save_on_error_rejects_an_unknown_enum_value" {
  command = plan

  variables {
    n8n_executions_data_save_on_error = "sometimes"
  }

  expect_failures = [var.n8n_executions_data_save_on_error]
}

# The duplicate-key hazard this reserved list exists to prevent: all four
# names are rendered by the chart from executions.data unconditionally, with
# no EXECUTIONS_DATA_SAVE_ prefix in n8n_managed_env_prefixes to catch them
# generically (unlike DB_/QUEUE_/N8N_RUNNERS_), so each is reserved by its
# exact name instead.
run "execution_data_save_names_are_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "EXECUTIONS_DATA_SAVE_ON_SUCCESS", value = "none" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "execution_data_save_manual_executions_name_is_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS", value = "false" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# F-047/F-048: the two compression limits and n8n_task_runner_timeout gain the
# same whole-number floor their siblings got in round 1.
run "compression_max_decompressed_size_rejects_a_fraction" {
  command = plan

  variables {
    n8n_compression_max_decompressed_size_bytes = 1073741824.5
  }

  expect_failures = [var.n8n_compression_max_decompressed_size_bytes]
}

run "compression_max_zip_entries_rejects_a_fraction" {
  command = plan

  variables {
    n8n_compression_max_zip_entries = 250.5
  }

  expect_failures = [var.n8n_compression_max_zip_entries]
}

run "task_runner_timeout_rejects_a_fraction" {
  command = plan

  variables {
    n8n_task_runner_timeout = 300.5
  }

  expect_failures = [var.n8n_task_runner_timeout]
}

run "editor_and_package_policy_reach_the_pods" {
  command = plan

  variables {
    n8n_templates_enabled                  = false
    n8n_personalization_enabled            = false
    n8n_community_packages_prevent_loading = true
    n8n_unverified_packages_enabled        = false
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "N8N_TEMPLATES_ENABLED", value = "false" }
    )
    error_message = "n8n_templates_enabled must render N8N_TEMPLATES_ENABLED into config.extraEnv."
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "N8N_COMMUNITY_PACKAGES_PREVENT_LOADING", value = "true" }
    )
    error_message = "n8n_community_packages_prevent_loading must render N8N_COMMUNITY_PACKAGES_PREVENT_LOADING."
  }
}

run "postgres_tls_states_its_choice_either_way" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled = false
  }

  # Rendered explicitly rather than omitted: an in-cluster pooler terminating
  # SSL upstream is exactly when this matters, and a missing variable would
  # leave n8n on its own default instead of the caller's choice.
  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "DB_POSTGRESDB_SSL_ENABLED", value = "false" }
    )
    error_message = "db_postgresdb_ssl_enabled = false must still render DB_POSTGRESDB_SSL_ENABLED explicitly."
  }
}

# ── No licensed feature may be rendered ───────────────────────────────────────
# The module deploys Community-edition n8n only. Nothing here should be able to
# put a licence key, a licensed env var, or a multi-main topology in front of
# the pods, asserting on the name families rather than on individual variables
# is what makes this catch a licensed feature added later.

run "no_licensed_env_var_is_rendered" {
  command = plan

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv :
      e if startswith(e.name, "N8N_LICENSE_") || startswith(e.name, "N8N_MULTI_MAIN_") || startswith(e.name, "N8N_LOG_STREAMING_")
    ]) == 0
    error_message = "A licence-gated env var reached the pods. This module deploys Community-edition n8n and carries no licence."
  }
}

run "no_licence_or_multi_main_block_reaches_the_chart" {
  command = plan

  assert {
    condition     = !contains(keys(local.k8s_values_final), "license") && !contains(keys(local.k8s_values_final), "multiMain")
    error_message = "The chart values still carry a license or multiMain block; both are licensed features this module does not offer."
  }
}

run "task_runner_timeouts_are_gated_on_task_runners" {
  command = plan

  variables {
    n8n_task_runners_enabled = false
  }

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv :
      e if startswith(e.name, "N8N_RUNNERS_")
    ]) == 0
    error_message = "Task-runner env vars must not be rendered when task runners are disabled."
  }
}

# The idle-shutdown timeout has to reach the task-runner SIDECAR, and
# config.extraEnv reaches the n8n containers only. Emitting it there meant the
# input silently did nothing: callers set 0 and the sidecar stayed on the
# chart's default of 15.
run "the_runner_idle_shutdown_reaches_the_sidecar_not_the_n8n_containers" {
  command = plan

  variables {
    n8n_task_runners_enabled              = true
    n8n_task_runner_auto_shutdown_timeout = 0
  }

  assert {
    condition     = local.k8s_values_task_runners.taskRunners.launcher.autoShutdownTimeout == 0
    error_message = "The idle-shutdown timeout must be set on taskRunners.launcher.autoShutdownTimeout, the only key the chart renders into the sidecar's environment."
  }

  # Guards the regression directly: if this ever moves back into extraEnv it
  # lands on the n8n containers, where nothing reads it.
  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv :
      e if e.name == "N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT"
    ]) == 0
    error_message = "N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT must not be rendered into config.extraEnv; the launcher runs in the sidecar and never sees it there."
  }

  # The request timeout genuinely is an n8n-side setting, so it stays put. This
  # keeps the fix from over-correcting and moving both.
  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv :
      e if e.name == "N8N_RUNNERS_TASK_REQUEST_TIMEOUT"
    ]) == 1
    error_message = "N8N_RUNNERS_TASK_REQUEST_TIMEOUT is read by n8n itself and must stay in config.extraEnv."
  }
}

# F-015: both timeouts gain a whole-number floor.
run "task_runner_auto_shutdown_timeout_rejects_a_fraction" {
  command = plan

  variables {
    n8n_task_runner_auto_shutdown_timeout = 15.5
  }

  expect_failures = [var.n8n_task_runner_auto_shutdown_timeout]
}

run "task_runner_request_timeout_rejects_a_fraction" {
  command = plan

  variables {
    n8n_task_runner_request_timeout = 300.5
  }

  expect_failures = [var.n8n_task_runner_request_timeout]
}

run "task_runner_request_timeout_rejects_zero" {
  command = plan

  variables {
    n8n_task_runner_request_timeout = 0
  }

  expect_failures = [var.n8n_task_runner_request_timeout]
}

# ── Runner concurrency ───────────────────────────────────────────────────────
# The chart has no typed value for N8N_RUNNERS_MAX_CONCURRENCY, so it goes in
# the launcher ConfigMap's env-overrides, which is where the runner process
# actually reads it. Both runner types get it, and neither gets it when the
# input is null: JavaScript defaults to 10 and Python to 5, so any number this
# module invented as a default would silently move one of them.

run "runner_concurrency_reaches_both_runner_types" {
  command = plan

  variables {
    n8n_task_runners_enabled        = true
    n8n_task_runner_max_concurrency = 15
  }

  assert {
    condition = alltrue([
      for r in jsondecode(kubernetes_config_map_v1.task_runners_config[0].data["n8n-task-runners.json"])["task-runners"] :
      try(r["env-overrides"]["N8N_RUNNERS_MAX_CONCURRENCY"], null) == "15"
    ])
    error_message = "Both the javascript and python runner blocks must carry N8N_RUNNERS_MAX_CONCURRENCY, as the string \"15\": these are environment variables."
  }

  # The override must not displace what was already in each block.
  assert {
    condition = alltrue([
      try(jsondecode(kubernetes_config_map_v1.task_runners_config[0].data["n8n-task-runners.json"])["task-runners"][0]["env-overrides"]["N8N_RUNNERS_HEALTH_CHECK_SERVER_HOST"], null) == "0.0.0.0",
      try(jsondecode(kubernetes_config_map_v1.task_runners_config[0].data["n8n-task-runners.json"])["task-runners"][1]["env-overrides"]["N8N_RUNNERS_STDLIB_ALLOW"], null) == "*",
    ])
    error_message = "Merging the concurrency override must leave each runner's existing env-overrides in place."
  }
}

run "runner_concurrency_is_absent_when_the_caller_names_nothing" {
  command = plan

  variables {
    n8n_task_runners_enabled = true
  }

  assert {
    condition = alltrue([
      for r in jsondecode(kubernetes_config_map_v1.task_runners_config[0].data["n8n-task-runners.json"])["task-runners"] :
      !contains(keys(r["env-overrides"]), "N8N_RUNNERS_MAX_CONCURRENCY")
    ])
    error_message = "With n8n_task_runner_max_concurrency null the key must be omitted entirely, leaving JavaScript on 10 and Python on 5."
  }
}

run "a_runner_concurrency_of_zero_is_rejected" {
  command = plan

  variables {
    n8n_task_runners_enabled        = true
    n8n_task_runner_max_concurrency = 0
  }

  expect_failures = [var.n8n_task_runner_max_concurrency]
}

# F-074: the Python runner's own parser (parse_allowlist) raises
# ConfigurationError on "*" mixed with named modules and refuses to start;
# the plan now says no instead of every main/worker pod crash-looping on it.
run "python_stdlib_allow_rejects_the_wildcard_mixed_with_named_modules" {
  command = plan

  variables {
    n8n_python_stdlib_allow = "*,json"
  }

  expect_failures = [var.n8n_python_stdlib_allow]
}

run "python_stdlib_allow_accepts_a_plain_module_list" {
  command = plan

  variables {
    n8n_python_stdlib_allow = "json,time,math"
  }

  assert {
    condition     = var.n8n_python_stdlib_allow == "json,time,math"
    error_message = "A comma list with no wildcard must still be accepted."
  }
}

# ── The external Redis path honours what the caller configured ────────────────
# Every value below was hardcoded in the rendered values tree at one point, so
# a caller-supplied port, ACL username, TLS flag or timeout reached nothing.

run "an_external_redis_uses_the_caller_port_and_username" {
  command = plan

  variables {
    redis_backend    = "external"
    redis_host       = "redis.internal.example.com"
    redis_port       = 6380
    redis_username   = "n8n"
    redis_auth_token = "not-a-real-token"
  }

  assert {
    condition     = local.k8s_values_redis.redis.port == 6380
    error_message = "redis_port must reach the chart on the external path; 6379 is only correct for the in-cluster Service."
  }

  assert {
    condition     = local.k8s_values_redis.redis.username == "n8n"
    error_message = "redis_username must reach the chart, otherwise an ACL-authenticated endpoint cannot be used at all."
  }
}

# The scaler and the workload must consume the same endpoint the same way, or
# autoscaling silently watches nothing: a hardcoded :6379 on a caller port, a
# plaintext dial against a TLS listener, or the default ACL user where n8n
# authenticates as a named one all leave the queue depth unreadable while the
# workload itself runs fine.
run "the_keda_trigger_matches_the_external_endpoint" {
  command = plan

  variables {
    k8s_keda_installed               = true
    redis_backend                    = "external"
    redis_host                       = "redis.internal.example.com"
    redis_port                       = 6380
    redis_username                   = "n8n"
    redis_auth_token                 = "not-a-real-token"
    redis_transit_encryption_enabled = true
  }

  assert {
    condition     = alltrue([for t in local.k8s_values_keda.keda.worker.triggers : t.metadata.address == "redis.internal.example.com:6380"])
    error_message = "The trigger address must carry the caller's port, not a hardcoded 6379."
  }

  assert {
    condition     = alltrue([for t in local.k8s_values_keda.keda.worker.triggers : try(t.metadata.enableTLS, null) == "true"])
    error_message = "With redis_transit_encryption_enabled, the trigger must set enableTLS or the scaler dials the TLS listener in plaintext."
  }

  assert {
    condition     = alltrue([for t in local.k8s_values_keda.keda.worker.triggers : try(t.metadata.username, null) == "n8n"])
    error_message = "The trigger must authenticate as the same ACL user n8n does."
  }

  assert {
    condition     = alltrue([for t in local.k8s_values_keda.keda.worker.triggers : try(t.metadata.passwordFromEnv, null) == "QUEUE_BULL_REDIS_PASSWORD"])
    error_message = "With an AUTH token set, the trigger must resolve it from the worker's QUEUE_BULL_REDIS_PASSWORD."
  }
}

# One input, three consumers, all of which must move together: n8n's own key
# prefix (N8N_REDIS_KEY_PREFIX), Bull's (redis.prefix -> QUEUE_BULL_PREFIX) and
# the KEDA listName. An earlier version moved only the KEDA half, so setting
# the input froze worker autoscaling against lists Bull never wrote to.
run "the_redis_key_prefix_moves_all_three_consumers_together" {
  command = plan

  variables {
    k8s_keda_installed = true
    redis_key_prefix   = "tenant-a"
  }

  assert {
    condition     = try(local.k8s_values_redis.redis.prefix, null) == "tenant-a"
    error_message = "redis_key_prefix must reach the chart's redis.prefix (QUEUE_BULL_PREFIX)."
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "N8N_REDIS_KEY_PREFIX", value = "tenant-a" }
    )
    error_message = "redis_key_prefix must reach n8n as N8N_REDIS_KEY_PREFIX."
  }

  assert {
    condition     = toset([for t in local.k8s_values_keda.keda.worker.triggers : t.metadata.listName]) == toset(["tenant-a:jobs:wait", "tenant-a:jobs:active"])
    error_message = "The KEDA listName must follow the same prefix Bull writes under."
  }
}

run "an_unset_redis_key_prefix_leaves_every_default_in_place" {
  command = plan

  variables {
    k8s_keda_installed = true
  }

  assert {
    condition     = !contains(keys(local.k8s_values_redis.redis), "prefix")
    error_message = "With no prefix set, redis.prefix must be omitted so Bull's own default applies."
  }

  assert {
    condition     = !contains([for e in local.k8s_values_config.config.extraEnv : e.name], "N8N_REDIS_KEY_PREFIX")
    error_message = "With no prefix set, N8N_REDIS_KEY_PREFIX must be omitted so n8n's own default applies."
  }

  assert {
    condition     = toset([for t in local.k8s_values_keda.keda.worker.triggers : t.metadata.listName]) == toset(["bull:jobs:wait", "bull:jobs:active"])
    error_message = "With no prefix set, the KEDA listName must stay on Bull's default prefix."
  }
}

# ── Bull queue worker tuning (redis.worker.*) ─────────────────────────────────
# lockDuration/lockRenewTime/stalledInterval share the chart's redis.worker
# block with timeout (n8n_termination_grace_period), which always renders;
# these three must merge in beside it without disturbing it.
run "queue_worker_lock_and_stall_settings_reach_the_chart" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration    = 20000
    n8n_queue_worker_lock_renew_time  = 5000
    n8n_queue_worker_stalled_interval = 15000
  }

  assert {
    condition = (
      local.k8s_values_redis.redis.worker.lockDuration == 20000 &&
      local.k8s_values_redis.redis.worker.lockRenewTime == 5000 &&
      local.k8s_values_redis.redis.worker.stalledInterval == 15000
    )
    error_message = "n8n_queue_worker_lock_duration/_lock_renew_time/_stalled_interval must reach redis.worker.lockDuration/lockRenewTime/stalledInterval."
  }

  assert {
    condition     = local.k8s_values_redis.redis.worker.timeout == var.n8n_termination_grace_period
    error_message = "redis.worker.timeout must still carry n8n_termination_grace_period; the three new keys must not displace it."
  }
}

run "queue_worker_lock_and_stall_settings_stay_unset_by_default" {
  command = plan

  assert {
    condition = (
      !contains(keys(local.k8s_values_redis.redis.worker), "lockDuration") &&
      !contains(keys(local.k8s_values_redis.redis.worker), "lockRenewTime") &&
      !contains(keys(local.k8s_values_redis.redis.worker), "stalledInterval")
    )
    error_message = "With all three inputs left null, none of lockDuration/lockRenewTime/stalledInterval may render; the chart's own defaults (60000/10000/30000ms) must apply unstated."
  }
}

run "queue_worker_lock_duration_rejects_a_value_below_the_chart_minimum" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration = 500
  }

  expect_failures = [var.n8n_queue_worker_lock_duration]
}

run "queue_worker_lock_duration_rejects_a_fraction" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration = 60000.5
  }

  expect_failures = [var.n8n_queue_worker_lock_duration]
}

run "queue_worker_lock_renew_time_rejects_a_value_below_the_chart_minimum" {
  command = plan

  variables {
    n8n_queue_worker_lock_renew_time = 500
  }

  expect_failures = [var.n8n_queue_worker_lock_renew_time]
}

run "queue_worker_stalled_interval_rejects_zero" {
  command = plan

  variables {
    n8n_queue_worker_stalled_interval = 0
  }

  expect_failures = [var.n8n_queue_worker_stalled_interval]
}

run "queue_worker_stalled_interval_rejects_a_fraction" {
  command = plan

  variables {
    n8n_queue_worker_stalled_interval = 1500.5
  }

  expect_failures = [var.n8n_queue_worker_stalled_interval]
}

# Lowering the lock duration to the chart's own renewal default or below,
# while leaving the renewal interval null, guarantees the lock expires at or
# before the first renewal: the effective-value cross-check must catch it.
run "lowering_lock_duration_to_the_renewal_default_without_a_renewal_override_is_rejected" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration = 10000
  }

  expect_failures = [var.n8n_queue_worker_lock_renew_time]
}

# Setting the renewal interval explicitly below the lowered duration clears
# the same warning.
run "lowering_lock_duration_with_an_explicit_lower_renewal_is_accepted" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration   = 10000
    n8n_queue_worker_lock_renew_time = 5000
  }

  assert {
    condition     = local.k8s_values_redis.redis.worker.lockDuration == 10000
    error_message = "A lock duration lowered to the chart's renewal default, paired with an explicit lower renewal interval, must still reach redis.worker.lockDuration."
  }
}

# QUEUE_ is a module-managed prefix (n8n_managed_env_prefixes); this proves
# the specific new names, not just the prefix mechanism in the abstract.
run "queue_worker_lock_duration_name_is_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "QUEUE_WORKER_LOCK_DURATION", value = "20000" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "queue_worker_stalled_interval_name_is_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "QUEUE_WORKER_STALLED_INTERVAL", value = "15000" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "the_keda_trigger_carries_no_auth_metadata_without_auth" {
  command = plan

  variables {
    k8s_keda_installed = true
    redis_backend      = "external"
    redis_host         = "redis.internal.example.com"
  }

  assert {
    condition = alltrue([
      for t in local.k8s_values_keda.keda.worker.triggers :
      !contains(keys(t.metadata), "passwordFromEnv") && !contains(keys(t.metadata), "enableTLS") && !contains(keys(t.metadata), "username")
    ])
    error_message = "On a no-auth plaintext endpoint the trigger must carry none of passwordFromEnv, enableTLS or username: naming an env var that does not exist authenticates with an empty password against a server expecting none."
  }
}

# The chart's deployments guard the QUEUE_BULL_REDIS_PASSWORD secretKeyRef on
# `if and .name .key`, so an omitted passwordSecret renders no reference at
# all. Rendered unconditionally, it named "n8n-redis-secret" on the no-auth
# external path - a Secret the module only creates when auth is active - and
# every pod sat in CreateContainerConfigError over a Secret that never existed.
run "an_external_redis_without_auth_renders_no_password_secret" {
  command = plan

  variables {
    redis_backend = "external"
    redis_host    = "redis.internal.example.com"
  }

  assert {
    condition     = !contains(keys(local.k8s_values_redis.redis), "passwordSecret")
    error_message = "With no AUTH token, no passwordSecret may be rendered: it would point the pods at a Secret the module does not create."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "No module-managed Redis Secret should exist on the no-auth path."
  }
}

run "an_external_redis_with_auth_renders_the_password_secret" {
  command = plan

  variables {
    redis_backend    = "external"
    redis_host       = "redis.internal.example.com"
    redis_auth_token = "not-a-real-token"
  }

  assert {
    condition     = try(local.k8s_values_redis.redis.passwordSecret.name, null) == "n8n-redis-secret" && try(local.k8s_values_redis.redis.passwordSecret.key, null) == "password"
    error_message = "With an AUTH token, passwordSecret must point at the module-managed n8n-redis-secret."
  }

  # The reference alone is not enough - this PR exists because a reference to
  # a Secret nothing creates is a broken deployment. Assert the Secret too.
  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 1
    error_message = "The module must create the Secret the passwordSecret reference names."
  }
}

run "the_in_cluster_queue_still_renders_its_password_secret" {
  command = plan

  assert {
    condition     = try(local.k8s_values_redis.redis.passwordSecret.name, null) == "n8n-redis-auth" && try(local.k8s_values_redis.redis.passwordSecret.key, null) == "redis-password"
    error_message = "The valkey path always has a module-generated credential, so passwordSecret must keep pointing at it."
  }
}

run "the_in_cluster_queue_ignores_external_connection_inputs" {
  command = plan

  variables {
    redis_port     = 6380
    redis_username = "ignored"
  }

  assert {
    condition     = local.k8s_values_redis.redis.port == 6379
    error_message = "The in-cluster Valkey Service listens on 6379; an external port input must not override that."
  }

  assert {
    condition     = local.k8s_values_redis.redis.username == ""
    error_message = "The chart manages the in-cluster credential, so no username should be sent on the valkey path."
  }
}

run "declared_tls_reaches_the_pods_on_the_external_path" {
  command = plan

  variables {
    redis_backend                    = "external"
    redis_host                       = "redis.internal.example.com"
    redis_transit_encryption_enabled = true
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "QUEUE_BULL_REDIS_TLS", value = "true" }
    )
    error_message = "redis_transit_encryption_enabled must reach n8n; the chart has no redis.tls key, so it goes via the environment."
  }
}

run "the_redis_timeout_threshold_is_absent_unless_set" {
  command = plan

  # Left unset the chart's own 10000 applies, so an existing release renders
  # byte-identically rather than picking up a value this module invented.
  assert {
    condition     = !can(local.k8s_values_redis.redis.timeout)
    error_message = "No timeout key should be rendered when n8n_redis_timeout_threshold is null."
  }
}

# ── Autoscaling bounds are the caller's ───────────────────────────────────────

run "the_main_deployment_never_scales_past_one_pod" {
  command = plan

  # n8n elects a leader among main pods only under multi-main, which is
  # licensed. A second main would be a second leader: duplicate schedule
  # triggers and two owners of the same waiting executions. Queue mode carries
  # the load instead, workers and webhook processors are the pools that scale.
  assert {
    condition = (
      local.k8s_values_hpa.hpa.main.enabled == false &&
      local.k8s_values_hpa.hpa.main.maxReplicas == 1 &&
      local.k8s_values_replicas.replicaCount == 1
    )
    error_message = "The main Deployment must stay at one replica with its HPA off: leader election among mains is a licensed feature."
  }

  # Sticky sessions exist to pin a browser to one main. With one main there is
  # nothing to pin to, and the cookie annotations would be dead weight.
  assert {
    condition     = local.k8s_values_ingress.ingress.sticky.enabled == false
    error_message = "Session affinity must be off: there is only ever one main pod."
  }
}

# ── Volumes and logging ───────────────────────────────────────────────────────

run "extra_volumes_reach_the_chart" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "ca-bundle"
      config_map = { name = "corporate-ca" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "ca-bundle"
      mount_path = "/etc/ssl/corporate"
      read_only  = true
    }]
  }

  # Translated from snake_case into the chart's camelCase in locals, and then
  # for a long time not rendered anywhere.
  assert {
    condition     = length(local.k8s_values_volumes.extraVolumes) == 1
    error_message = "n8n_extra_volumes must reach the chart's extraVolumes."
  }

  assert {
    condition     = local.k8s_values_volumes.extraVolumeMounts[0].mountPath == "/etc/ssl/corporate"
    error_message = "n8n_extra_volume_mounts must reach the chart's extraVolumeMounts."
  }
}

run "log_level_and_pool_size_reach_the_pods" {
  command = plan

  variables {
    n8n_log_level           = "debug"
    db_postgresdb_pool_size = 20
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "N8N_LOG_LEVEL", value = "debug" }
    )
    error_message = "n8n_log_level must render N8N_LOG_LEVEL."
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "DB_POSTGRESDB_POOL_SIZE", value = "20" }
    )
    error_message = "db_postgresdb_pool_size must render DB_POSTGRESDB_POOL_SIZE."
  }
}

run "db_postgresdb_pool_size_rejects_a_fraction" {
  command = plan

  variables {
    db_postgresdb_pool_size = 20.5
  }

  expect_failures = [var.db_postgresdb_pool_size]
}

run "n8n_helm_timeout_rejects_a_fraction" {
  command = plan

  variables {
    n8n_helm_timeout = 600.5
  }

  expect_failures = [var.n8n_helm_timeout]
}

run "valkey_helm_timeout_defaults_to_600" {
  command = plan

  assert {
    condition     = alltrue([for r in helm_release.valkey : r.timeout == 600])
    error_message = "valkey_helm_timeout must default to 600, the same literal the Valkey helm_release hardcoded before this input existed."
  }
}

run "valkey_helm_timeout_reaches_the_release" {
  command = plan

  variables {
    valkey_helm_timeout = 1800
  }

  assert {
    condition     = alltrue([for r in helm_release.valkey : r.timeout == 1800])
    error_message = "valkey_helm_timeout must reach helm_release.valkey's timeout argument."
  }
}

run "valkey_helm_timeout_rejects_a_fraction" {
  command = plan

  variables {
    valkey_helm_timeout = 600.5
  }

  expect_failures = [var.valkey_helm_timeout]
}

run "valkey_helm_timeout_rejects_below_60" {
  command = plan

  variables {
    valkey_helm_timeout = 59
  }

  expect_failures = [var.valkey_helm_timeout]
}


# Database connection acquisition and health-check ping settings: the chart
# has no values path for any of the three, and DB_ is a module-managed
# prefix, so config.extraEnv is the only door, and these variables are the
# only way to reach it.
run "db_connection_and_ping_settings_reach_the_pods" {
  command = plan

  variables {
    db_postgresdb_connection_timeout_ms = 30000
    db_ping_timeout_ms                  = 8000
    db_ping_interval_seconds            = 5
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "DB_POSTGRESDB_CONNECTION_TIMEOUT", value = "30000" }
    )
    error_message = "db_postgresdb_connection_timeout_ms must render DB_POSTGRESDB_CONNECTION_TIMEOUT."
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "DB_PING_TIMEOUT_MS", value = "8000" }
    )
    error_message = "db_ping_timeout_ms must render DB_PING_TIMEOUT_MS."
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "DB_PING_INTERVAL_SECONDS", value = "5" }
    )
    error_message = "db_ping_interval_seconds must render DB_PING_INTERVAL_SECONDS."
  }
}

run "db_connection_and_ping_settings_stay_unset_by_default" {
  command = plan

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv :
      e if contains(["DB_POSTGRESDB_CONNECTION_TIMEOUT", "DB_PING_TIMEOUT_MS", "DB_PING_INTERVAL_SECONDS"], e.name)
    ]) == 0
    error_message = "With all three inputs left null, none of DB_POSTGRESDB_CONNECTION_TIMEOUT, DB_PING_TIMEOUT_MS or DB_PING_INTERVAL_SECONDS may render; n8n's own defaults must apply unstated."
  }
}

run "db_postgresdb_connection_timeout_ms_rejects_a_negative_value" {
  command = plan

  variables {
    db_postgresdb_connection_timeout_ms = -1
  }

  expect_failures = [var.db_postgresdb_connection_timeout_ms]
}

run "db_postgresdb_connection_timeout_ms_rejects_a_value_past_the_node_timer_ceiling" {
  command = plan

  variables {
    db_postgresdb_connection_timeout_ms = 2147483648
  }

  expect_failures = [var.db_postgresdb_connection_timeout_ms]
}

run "db_postgresdb_connection_timeout_ms_rejects_a_fraction" {
  command = plan

  variables {
    db_postgresdb_connection_timeout_ms = 1500.5
  }

  expect_failures = [var.db_postgresdb_connection_timeout_ms]
}

run "db_ping_timeout_ms_rejects_zero_and_below" {
  command = plan

  variables {
    db_ping_timeout_ms = 0
  }

  expect_failures = [var.db_ping_timeout_ms]
}

run "db_ping_interval_seconds_rejects_zero_and_below" {
  command = plan

  variables {
    db_ping_interval_seconds = 0
  }

  expect_failures = [var.db_ping_interval_seconds]
}

# DB_ is a module-managed prefix (n8n_managed_env_prefixes), so every name
# under it is already rejected generically; this proves the two new names
# specifically, not just the prefix mechanism in the abstract.
run "db_ping_timeout_ms_name_is_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "DB_PING_TIMEOUT_MS", value = "9000" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "db_postgresdb_connection_timeout_name_is_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "DB_POSTGRESDB_CONNECTION_TIMEOUT", value = "15000" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# The module provisions no object storage and writes none of these names, so a
# caller pointing n8n at their own bucket is a supported configuration rather
# than a collision with something the module manages. This asserts the pair
# together: the names the module does own must still be rejected, or the
# guardrail has been widened into uselessness.
run "object_storage_env_is_accepted_and_managed_env_is_still_rejected" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_EXTERNAL_STORAGE_S3_HOST", value = "minio.example.com" },
      { name = "AWS_ACCESS_KEY_ID", value = "AKIAEXAMPLE" },
    ]
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "N8N_EXTERNAL_STORAGE_S3_HOST", value = "minio.example.com" }
    )
    error_message = "Object-storage env must reach the chart: the module sets no S3 values of its own."
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "AWS_ACCESS_KEY_ID", value = "AKIAEXAMPLE" }
    )
    error_message = "AWS_* is not module-managed and must pass through to the pods."
  }
}

run "a_module_managed_env_name_is_still_rejected" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "DB_POSTGRESDB_HOST", value = "somewhere-else" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# ── SMTP and telemetry ──────────────────────────────────────────────────────
# Both are opt-in: at the defaults neither family may appear in extraEnv, so
# n8n's own behavior (no mail, telemetry on) stands untouched and unclaimed.

run "no_smtp_and_no_telemetry_env_at_the_defaults" {
  command = plan

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv : e.name
      if startswith(e.name, "N8N_SMTP_") || e.name == "N8N_EMAIL_MODE" || e.name == "N8N_DIAGNOSTICS_ENABLED"
    ]) == 0
    error_message = "With n8n_smtp and n8n_diagnostics_enabled unset, no SMTP or telemetry env var may be rendered; n8n's own defaults stand."
  }
}

run "smtp_renders_the_family_with_the_password_as_a_secret_ref" {
  command = plan

  variables {
    n8n_smtp = {
      host   = "mail.test.example.com"
      sender = "n8n <n8n@test.example.com>"
      user   = "n8n@test.example.com"
      password_secret_ref = {
        name = "smtp-credentials"
      }
    }
  }

  assert {
    condition = alltrue([
      for pair in [
        ["N8N_EMAIL_MODE", "smtp"],
        ["N8N_SMTP_HOST", "mail.test.example.com"],
        ["N8N_SMTP_PORT", "465"],
        ["N8N_SMTP_SSL", "true"],
        ["N8N_SMTP_STARTTLS", "true"],
        ["N8N_SMTP_SENDER", "n8n <n8n@test.example.com>"],
        ["N8N_SMTP_USER", "n8n@test.example.com"],
        ] : contains(
        [for e in local.k8s_values_config.config.extraEnv : "${e.name}=${try(e.value, "")}"],
        "${pair[0]}=${pair[1]}"
      )
    ])
    error_message = "Configuring n8n_smtp must render the full N8N_SMTP_* family with the object's values and the port/ssl/starttls defaults."
  }

  # The password is the one entry that must not be a value.
  assert {
    condition = anytrue([
      for e in local.k8s_values_config.config.extraEnv :
      try(e.valueFrom.secretKeyRef.name == "smtp-credentials" && e.valueFrom.secretKeyRef.key == "password", false)
      if e.name == "N8N_SMTP_PASS"
    ])
    error_message = "N8N_SMTP_PASS must be a secretKeyRef into the caller's Secret with the default key \"password\", never a literal value in the release."
  }
}

run "smtp_without_auth_renders_no_user_or_password_entry" {
  command = plan

  variables {
    n8n_smtp = {
      host   = "relay.test.example.com"
      sender = "n8n@test.example.com"
    }
  }

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv : e.name
      if e.name == "N8N_SMTP_USER" || e.name == "N8N_SMTP_PASS"
    ]) == 0
    error_message = "With no user and no password_secret_ref, neither N8N_SMTP_USER nor N8N_SMTP_PASS may render, for an unauthenticated relay."
  }
}

run "an_empty_smtp_host_is_rejected" {
  command = plan

  variables {
    n8n_smtp = {
      host   = ""
      sender = "n8n@test.example.com"
    }
  }

  expect_failures = [var.n8n_smtp]
}

run "telemetry_false_renders_the_off_switch" {
  command = plan

  variables {
    n8n_diagnostics_enabled = false
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : "${e.name}=${e.value}"],
      "N8N_DIAGNOSTICS_ENABLED=false",
    )
    error_message = "n8n_diagnostics_enabled = false must render N8N_DIAGNOSTICS_ENABLED=false to turn telemetry off."
  }
}

run "the_smtp_and_telemetry_names_cannot_ride_the_env_escape_hatch" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_SMTP_HOST", value = "evil.example.com" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "the_diagnostics_name_cannot_ride_the_env_escape_hatch" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_DIAGNOSTICS_ENABLED", value = "true" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# The secretKeyRef form has to land in the same config.extraEnv list as the
# plain one, because that list is the only place the chart reads caller env
# from. Asserting both in one run is the point: they are separate inputs
# concatenated separately, so a change that drops one would otherwise still
# pass the other's test.
run "secret_backed_env_renders_a_secretKeyRef_alongside_plain_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_ENABLED_MODULES", value = "instance-ai" },
    ]
    n8n_extra_env_from_secret = [
      {
        name        = "N8N_INSTANCE_AI_MODEL_API_KEY"
        secret_name = "ai-assistant-secrets"
        secret_key  = "anthropic-api-key"
      },
    ]
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      {
        name = "N8N_INSTANCE_AI_MODEL_API_KEY"
        valueFrom = {
          secretKeyRef = {
            name = "ai-assistant-secrets"
            key  = "anthropic-api-key"
          }
        }
      }
    )
    error_message = "n8n_extra_env_from_secret must render as a valueFrom.secretKeyRef entry in config.extraEnv."
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "N8N_ENABLED_MODULES", value = "instance-ai" }
    )
    error_message = "Adding a secret-backed entry must not displace the plain n8n_extra_env entries."
  }
}

# A single [a-z0-9.-] character class accepts both of these. The API server
# does not, so the reference resolves to nothing and the pod sticks in
# CreateContainerConfigError long after Helm reported success - the exact
# failure this validation exists to move forward to plan time.
# The module hardcodes the path segments n8n serves and then publishes them:
# n8n_webhook_path_prefixes, the webhook Ingress in every split example, and
# the /rest in n8n_oauth_callback_url. Repointing one through n8n_extra_env
# leaves all three advertising a path n8n no longer answers on, and nothing
# reports a conflict - the Ingress simply routes to a 404.
run "repointing_a_path_segment_is_rejected" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_ENDPOINT_REST", value = "api" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "repointing_the_webhook_segment_is_rejected_too" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_ENDPOINT_WEBHOOK", value = "hooks" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS was reserved under a comment claiming
# the module sets it; nothing anywhere ever did, so the reservation only
# blocked a caller from setting it themselves.
run "the_settings_file_permissions_switch_is_settable_through_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS", value = "true" },
    ]
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS", value = "true" },
    )
    error_message = "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS must reach config.extraEnv through n8n_extra_env; the module renders no typed input for it."
  }
}

# N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL was reserved with nothing behind it;
# n8n_external_secrets_enabled covers the switch but not its refresh interval.
run "the_external_secrets_refresh_interval_is_settable_through_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL", value = "600" },
    ]
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL", value = "600" },
    )
    error_message = "N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL must reach config.extraEnv through n8n_extra_env; the module renders no typed input for it."
  }
}

run "a_secret_name_with_an_empty_label_is_rejected" {
  command = plan

  variables {
    n8n_extra_env_from_secret = [
      {
        name        = "SOME_KEY"
        secret_name = "a..b"
        secret_key  = "key"
      },
    ]
  }

  expect_failures = [var.n8n_extra_env_from_secret]
}

run "a_secret_name_with_a_label_ending_in_a_hyphen_is_rejected" {
  command = plan

  variables {
    n8n_extra_env_from_secret = [
      {
        name        = "SOME_KEY"
        secret_name = "a-.b"
        secret_key  = "key"
      },
    ]
  }

  expect_failures = [var.n8n_extra_env_from_secret]
}

run "a_dotted_secret_name_is_still_accepted" {
  command = plan

  variables {
    n8n_extra_env_from_secret = [
      {
        name        = "SOME_KEY"
        secret_name = "team-a.ai-secrets"
        secret_key  = "key"
      },
    ]
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name],
      "SOME_KEY",
    )
    error_message = "A valid multi-label secret_name must still reach config.extraEnv."
  }
}

run "a_module_managed_env_name_is_rejected_in_the_secret_backed_input_too" {
  command = plan

  variables {
    n8n_extra_env_from_secret = [
      {
        name        = "N8N_ENCRYPTION_KEY"
        secret_name = "my-secrets"
        secret_key  = "key"
      },
    ]
  }

  expect_failures = [var.n8n_extra_env_from_secret]
}

# A name set in both inputs is not a Kubernetes error, which is exactly why it
# needs a plan-time one: the container keeps the last entry and discards the
# other without logging anything.
run "the_same_env_name_in_both_inputs_is_rejected" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_INSTANCE_AI_MODEL_API_KEY", value = "plaintext-by-mistake" },
    ]
    n8n_extra_env_from_secret = [
      {
        name        = "N8N_INSTANCE_AI_MODEL_API_KEY"
        secret_name = "ai-assistant-secrets"
        secret_key  = "anthropic-api-key"
      },
    ]
  }

  expect_failures = [var.n8n_extra_env_from_secret]
}

# Chart 1.16.0 added /mcp/ to the chart's own webhook Ingress
# (templates/ingress-webhook.yaml), closing the gap that used to leave it
# falling through to the main pods: before that, a webhook that looked
# delivered and never ran, because the main pods answered 200 with the
# editor's HTML and registered no handler for it. Confirmed by diffing
# ingress-webhook.yaml between chart 1.10.0 and 1.16.0.
#
# The module used to carry a derived "unrouted" subtraction and a
# supplementary kubernetes_ingress_v1.n8n_mcp resource to cover /mcp while
# the chart did not. Both were removed rather than left dormant: an
# unconditionally empty dynamic "path" block fails the Kubernetes provider's
# schema validation (an Ingress rule needs at least one path) even at
# count = 0, so "leave it in case the chart regresses" was not available as
# a shape once every prefix the module knows about is chart-routed.
run "the_chart_routes_every_webhook_prefix_itself" {
  command = plan

  assert {
    condition = length(setsubtract(local.n8n_webhook_path_prefixes, [
      "/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp",
    ])) == 0
    error_message = "Every prefix n8n_webhook_path_prefixes advertises must be one this chart version's own webhook Ingress routes. If the chart ever drops one, this module needs its supplementary Ingress back, not a passing test."
  }
}



# ip is a Cilium-specific convenience: it renders io.cilium/lb-ipam-ips, which
# only Cilium LB-IPAM reads. On MetalLB or kube-vip a caller setting ip alone
# would get an annotation their allocator ignores and an arbitrary address, so
# annotations is the general form and must win where both are set.
run "a_non_cilium_allocator_can_pin_the_lan_address" {
  command = plan

  variables {
    cnpg_lan_expose = {
      enabled     = true
      annotations = { "metallb.universe.tf/loadBalancerIPs" = "10.0.0.50" }
    }
    metrics_lan_expose = {
      enabled = true
      ip      = "10.0.0.51"
      annotations = {
        "kube-vip.io/loadbalancerIPs" = "10.0.0.52"
        "io.cilium/lb-ipam-ips"       = "10.0.0.52"
      }
    }
  }

  assert {
    condition     = kubernetes_service_v1.cnpg_lan[0].metadata[0].annotations["metallb.universe.tf/loadBalancerIPs"] == "10.0.0.50"
    error_message = "A caller-supplied allocator annotation must reach the Service."
  }

  assert {
    condition     = !contains(keys(kubernetes_service_v1.cnpg_lan[0].metadata[0].annotations), "io.cilium/lb-ipam-ips")
    error_message = "No Cilium annotation should be invented when the caller set none and left ip empty."
  }

  # Both set: annotations is merged last, so it decides.
  assert {
    condition     = kubernetes_service_v1.n8n_main_metrics_lan[0].metadata[0].annotations["io.cilium/lb-ipam-ips"] == "10.0.0.52"
    error_message = "annotations must override the ip-derived Cilium key, not lose to it."
  }
}

# The proxy settings describe how the controller carries n8n's traffic and are
# unrelated to TLS. They lived inside the cluster-issuer branch, so a caller
# bringing their own certificate, or serving without one, as on a local cluster
# where no ACME issuer can validate the hostname, lost all three and inherited
# nginx's 1m body limit and 60s timeouts. Binary uploads then fail with 413 and
# long executions are cut off mid-request, neither pointing at TLS.
run "proxy_annotations_survive_an_empty_cluster_issuer" {
  command = plan

  variables {
    k8s_ingress_cluster_issuer = ""
  }

  assert {
    condition     = local.k8s_ingress_annotations["nginx.ingress.kubernetes.io/proxy-body-size"] == "32m"
    error_message = "The body-size limit must not depend on cert-manager being in use."
  }

  assert {
    condition = alltrue([
      local.k8s_ingress_annotations["nginx.ingress.kubernetes.io/proxy-read-timeout"] == "3600",
      local.k8s_ingress_annotations["nginx.ingress.kubernetes.io/proxy-send-timeout"] == "3600",
    ])
    error_message = "Both proxy timeouts must survive an empty cluster issuer."
  }

  assert {
    condition     = !contains(keys(local.k8s_ingress_annotations), "cert-manager.io/cluster-issuer")
    error_message = "An empty cluster issuer must still suppress the cert-manager annotation."
  }
}

# One input, two env names, and they are not the same setting: the chart
# renders TZ (process clock) from config.timezone, and no chart template
# renders GENERIC_TIMEZONE, which is the timezone Schedule Triggers fire in
# and whose n8n default is America/New_York. Emitted only when n8n_timezone
# is set away from this module's own literal default ("UTC"), so a caller
# who leaves it alone sees no render change; a caller who customizes it away
# from UTC without this entry would have every schedule fire on US Eastern
# while the log timestamps made the configuration look honored.
run "the_scheduler_timezone_stays_unset_at_the_default" {
  command = plan

  assert {
    condition = !contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name],
      "GENERIC_TIMEZONE",
    )
    error_message = "GENERIC_TIMEZONE must not render at the default n8n_timezone (UTC), so this fix changes nothing for a caller who set nothing."
  }

  assert {
    condition     = local.k8s_values_config.config.timezone == "UTC"
    error_message = "config.timezone must still carry the default."
  }
}

run "a_timezone_override_moves_the_scheduler_timezone" {
  command = plan

  variables {
    n8n_timezone = "Europe/London"
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : "${e.name}=${e.value}"],
      "GENERIC_TIMEZONE=Europe/London",
    )
    error_message = "Overriding n8n_timezone must move GENERIC_TIMEZONE, or schedules fire in a different timezone than the one configured."
  }
}

run "the_scheduler_timezone_cannot_ride_the_env_escape_hatch" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "GENERIC_TIMEZONE", value = "America/Chicago" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# ── The webhook processor keeps an autoscaler on the KEDA path ────────────────
# The chart's own webhook HPA is gated on `not .Values.keda.enabled`, and its
# webhook ScaledObject needs keda.webhookProcessor.enabled, which this module
# leaves false on purpose. Without the supplementary HPA, attesting KEDA left
# the webhook pool with no autoscaler at all: and nothing failed, which is why
# this is asserted rather than assumed.

run "attesting_keda_still_leaves_the_webhook_processor_an_autoscaler" {
  command = plan

  variables {
    k8s_keda_installed                                    = true
    n8n_webhook_hpa_min_replicas                          = 3
    n8n_webhook_hpa_max_replicas                          = 9
    n8n_webhook_hpa_cpu_threshold                         = 55
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = 300
  }

  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook_processor) == 1
    error_message = "k8s_keda_installed = true must create the supplementary webhook HPA: the chart suppresses its own whenever keda.enabled is true."
  }

  assert {
    condition = (
      kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook_processor[0].spec[0].min_replicas == 3 &&
      kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook_processor[0].spec[0].max_replicas == 9
    )
    error_message = "The supplementary webhook HPA must take its bounds from n8n_webhook_hpa_min_replicas / n8n_webhook_hpa_max_replicas."
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook_processor[0].spec[0].scale_target_ref[0].name == local.n8n_webhook_service_name
    error_message = "The supplementary webhook HPA must target the webhook-processor Deployment."
  }

  # The window used to be a hardcoded 0 here, so the input worked on the
  # chart's own HPA and did nothing on the KEDA path: the one path
  # docs/troubleshooting.md tells callers to raise it on.
  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook_processor[0].spec[0].behavior[0].scale_up[0].stabilization_window_seconds == 300
    error_message = "The supplementary webhook HPA must take its scale-up stabilization window from n8n_webhook_hpa_scale_up_stabilization_window_seconds, not a literal."
  }
}

run "webhook_hpa_stabilization_window_rejects_a_fraction" {
  command = plan

  variables {
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = 300.5
  }

  expect_failures = [var.n8n_webhook_hpa_scale_up_stabilization_window_seconds]
}

# ── Pod network policy ────────────────────────────────────────────────────────
run "the_network_policy_is_off_by_default" {
  command = plan

  assert {
    condition     = local.k8s_values_final.networkPolicy.enabled == false
    error_message = "networkPolicy must default to off, matching the chart. It blocks plaintext http:// egress, which is a decision about the caller's workflows rather than one this module can make for them."
  }
}

run "the_network_policy_can_be_turned_on" {
  command = plan

  variables {
    n8n_network_policy_enabled = true
  }

  assert {
    condition     = local.k8s_values_final.networkPolicy.enabled == true
    error_message = "n8n_network_policy_enabled must reach the chart, or the input is accepted and discarded."
  }
}

# Both halves are module inputs, so the module can see the collision rather
# than leaving it to be discovered when the traces stop.
run "the_network_policy_warns_about_an_unreachable_otel_collector" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://otel-collector.observability.svc.cluster.local:4318"
  }

  expect_failures = [check.network_policy_blocks_the_otel_collector]
}

# A collector on 443 is reachable through the policy's own egress rule, so the
# warning must stay quiet: one that fires on a working configuration is one
# operators learn to ignore.
run "a_collector_on_443_draws_no_warning" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "https://otel.example.com"
  }

  assert {
    condition     = local.k8s_values_final.networkPolicy.enabled == true
    error_message = "The policy must still be rendered on this path."
  }
}

# The four cases below all reach their collector and must stay quiet. Each one
# is a port the policy permits, or traffic the policy never sees, and a warning
# that fires on a working configuration is one operators learn to ignore.

# Loopback never leaves the pod, so no NetworkPolicy applies to it. Writing the
# sidecar's address out explicitly has to behave the same as leaving the
# endpoint null and inheriting n8n's own localhost:4318.
run "an_explicit_loopback_collector_draws_no_warning" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://localhost:4318"
  }

  assert {
    condition     = local.n8n_otel_collector_reachable_under_network_policy
    error_message = "A collector on localhost is in the same pod, so the policy cannot block it."
  }
}

run "a_dotted_loopback_collector_draws_no_warning" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://127.0.0.1:4318"
  }

  assert {
    condition     = local.n8n_otel_collector_reachable_under_network_policy
    error_message = "127.0.0.0/8 is loopback for the same reason localhost is."
  }
}

# "127.something" is a hostname, not an address, and its A record can point at
# any host in the cluster. Only a numeric address is loopback.
run "a_hostname_beginning_with_127_is_still_warned_about" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://127.collector.example:4318"
  }

  expect_failures = [check.network_policy_blocks_the_otel_collector]
}

# ::1 has several spellings and they all name the same address.
run "an_expanded_ipv6_loopback_collector_draws_no_warning" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://[0:0:0:0:0:0:0:1]:4318"
  }

  assert {
    condition     = local.n8n_otel_endpoint_is_loopback
    error_message = "The expanded form of ::1 is the same loopback address as the compressed one."
  }
}

# The allowlist is not just 443. The chart writes an egress rule for the
# configured database port and another for the Redis port, both to any
# destination, so a collector sharing one of those ports is reachable. 5432 is
# an absurd port for a collector; it is here because the question under test is
# allowlist membership, not plausibility.
run "a_collector_on_the_database_port_draws_no_warning" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://otel.observability.svc.cluster.local:5432"
  }

  assert {
    condition     = contains(local.n8n_network_policy_allowed_ports, 5432)
    error_message = "The database port must be in the allowlist the check compares against."
  }

  assert {
    condition     = local.n8n_otel_collector_reachable_under_network_policy
    error_message = "A port the policy opens to every destination cannot make the collector unreachable."
  }
}

# The overlay is merged last, so a database.port set there is the port the chart
# writes into the policy. The allowlist has to move with it, or the check warns
# about the port the caller has replaced and stays quiet about the one in force.
run "an_overlay_moved_database_port_moves_the_allowlist" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://otel.observability.svc.cluster.local:6543"

    n8n_extra_helm_values = <<-YAML
      database:
        port: 6543
    YAML
  }

  assert {
    condition     = contains(local.n8n_network_policy_allowed_ports, 6543)
    error_message = "The overlay's database port is the one the rendered policy allows."
  }

  assert {
    condition     = !contains(local.n8n_network_policy_allowed_ports, 5432)
    error_message = "The port the overlay replaced is no longer in the rendered policy."
  }

  assert {
    condition     = local.n8n_otel_collector_reachable_under_network_policy
    error_message = "A collector on the overlay's database port is reachable."
  }
}

# redis.port takes the same route through the overlay, and the chart writes its
# own egress rule from it.
run "an_overlay_moved_redis_port_moves_the_allowlist" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://otel.observability.svc.cluster.local:6380"

    n8n_extra_helm_values = <<-YAML
      redis:
        port: 6380
    YAML
  }

  assert {
    condition     = contains(local.n8n_network_policy_allowed_ports, 6380)
    error_message = "The overlay's Redis port is the one the rendered policy allows."
  }

  assert {
    condition     = !contains(local.n8n_network_policy_allowed_ports, 6379)
    error_message = "The port the overlay replaced is no longer in the rendered policy."
  }

  assert {
    condition     = local.n8n_otel_collector_reachable_under_network_policy
    error_message = "A collector on the overlay's Redis port is reachable."
  }
}

# A bracketed IPv6 literal carries colons of its own, so the port is only the
# ":digits" after the closing bracket. With none, the scheme decides: this is
# https, so 443, which the policy allows.
run "a_bracketed_ipv6_collector_on_https_draws_no_warning" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "https://[2001:db8::1]"
  }

  assert {
    condition     = local.n8n_otel_endpoint_port == 443
    error_message = "An https:// URL with no explicit port is 443 whatever shape the host is."
  }

  assert {
    condition     = local.n8n_otel_collector_reachable_under_network_policy
    error_message = "The host's own colons must not be mistaken for a port separator."
  }
}

# The other half of the same widening: plain http with no port is 80, which the
# policy denies, and that must still warn.
run "a_plaintext_collector_on_the_default_port_is_warned_about" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://otel.observability.svc.cluster.local"
  }

  expect_failures = [check.network_policy_blocks_the_otel_collector]
}

# A null endpoint means n8n's own default of localhost:4318, which is a sidecar
# in the same pod, and same-pod traffic never passes a NetworkPolicy.
run "an_in_pod_collector_draws_no_warning" {
  command = plan

  variables {
    n8n_network_policy_enabled = true
    n8n_otel_enabled           = true
  }

  assert {
    condition = !contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name],
      "N8N_OTEL_EXPORTER_OTLP_ENDPOINT",
    )
    error_message = "A null endpoint must stay unrendered so n8n's own localhost default applies."
  }
}

# n8n_extra_helm_values is merged after this module's values and Helm gives the
# later file precedence, so the overlay decides whether the policy exists. The
# five merge outcomes are covered below. Chart 1.10.0 defaults
# networkPolicy.enabled to false, so the two deletion rows mean no policy, the
# same answer as an explicit false.
run "an_overlay_that_enables_the_policy_is_warned_about_too" {
  command = plan

  variables {
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://otel-collector.observability:4318"
    n8n_extra_helm_values           = <<-YAML
      networkPolicy:
        enabled: true
    YAML
  }

  # n8n_network_policy_enabled is left at its default of false. Reading the
  # input alone would say nothing here, and the traces would stop silently.
  expect_failures = [check.network_policy_blocks_the_otel_collector]
}

run "an_overlay_that_disables_the_policy_silences_the_warning" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://otel-collector.observability:4318"
    n8n_extra_helm_values           = <<-YAML
      networkPolicy:
        enabled: false
    YAML
  }

  assert {
    condition     = !local.n8n_network_policy_rendered
    error_message = "The overlay wins over the input, so no policy is rendered and there is no collision to warn about."
  }
}

run "nulling_the_network_policy_key_falls_back_to_the_charts_own_false" {
  command = plan

  variables {
    n8n_network_policy_enabled = true
    n8n_extra_helm_values      = "networkPolicy: null"
  }

  assert {
    condition     = local.n8n_extra_deletes_network_policy && !local.n8n_network_policy_rendered
    error_message = "An explicit null is a deletion rather than an absence, and what is left is the chart's own networkPolicy.enabled of false."
  }
}

run "nulling_only_network_policy_enabled_is_told_apart_from_the_whole_key" {
  command = plan

  variables {
    n8n_network_policy_enabled = true
    # The sibling is arbitrary: chart 1.10.0's networkPolicy block has only
    # `enabled`, so there is no real second key to use. It is here to make the
    # map non-empty, which is what separates a nested deletion from a
    # whole-key one.
    n8n_extra_helm_values = <<-YAML
      networkPolicy:
        enabled: null
        annotations: {}
    YAML
  }

  assert {
    condition     = local.n8n_extra_deletes_network_policy_enabled && !local.n8n_extra_deletes_network_policy
    error_message = "Nulling networkPolicy.enabled deletes only that key; the sibling survives the merge, so the whole-key deletion must stay false."
  }

  assert {
    condition     = !local.n8n_network_policy_rendered
    error_message = "Either deletion leaves networkPolicy.enabled unset, and the chart defaults it to false."
  }
}

run "an_overlay_declaring_the_key_without_enabled_keeps_the_module_value" {
  command = plan

  variables {
    n8n_network_policy_enabled      = true
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://otel-collector.observability:4318"
    n8n_extra_helm_values           = <<-YAML
      networkPolicy:
        annotations: {}
    YAML
  }

  # A map merge leaves this module's enabled = true standing, so the collision
  # is still real and the check must still fire.
  expect_failures = [check.network_policy_blocks_the_otel_collector]
}

# ── The CNPG primary's disruption budget ──────────────────────────────────────
# CloudNativePG creates a PodDisruptionBudget over the primary unless told
# otherwise, and at cnpg_instances = 1 that is minAvailable = 1 over a single
# pod: allowedDisruptions 0, and the node hosting Postgres can never be
# drained. Found on a live cluster, after the chart's own main-pod PDB was
# disabled for the same reason.
run "the_cnpg_pdb_is_off_for_a_single_instance" {
  command = plan

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.enablePDB == false
    error_message = "A single-instance CNPG cluster must not carry a PodDisruptionBudget: minAvailable = 1 over one pod is allowedDisruptions 0, which blocks every drain of the node Postgres landed on."
  }
}

# With replicas the budget does what a budget is for, so the default flips.
run "the_cnpg_pdb_is_on_when_there_are_replicas_to_protect" {
  command = plan

  variables {
    cnpg_instances = 3
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.enablePDB == true
    error_message = "With replicas the PDB stops a second Postgres node being drained while the first is still catching up, which is worth keeping."
  }
}

run "cnpg_instances_rejects_a_fraction" {
  command = plan

  variables {
    cnpg_instances = 1.5
  }

  expect_failures = [var.cnpg_instances]
}

run "the_cnpg_pdb_can_be_forced_either_way" {
  command = plan

  variables {
    cnpg_instances   = 3
    cnpg_pdb_enabled = false
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.enablePDB == false
    error_message = "An explicit cnpg_pdb_enabled must override the instance-count default."
  }
}

# Forcing the budget on at one instance is the configuration the variable
# description calls out as the one that blocks drains, so it must not be
# reachable without a warning.
run "forcing_the_cnpg_pdb_on_at_one_instance_is_warned_about" {
  command = plan

  variables {
    cnpg_pdb_enabled = true
    cnpg_instances   = 1
  }

  expect_failures = [check.cnpg_pdb_blocks_the_postgres_node_drain]
}

run "forcing_the_cnpg_pdb_on_with_replicas_draws_no_warning" {
  command = plan

  variables {
    cnpg_pdb_enabled = true
    cnpg_instances   = 2
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.enablePDB == true
    error_message = "With a replica to protect the budget is the point, so an explicit true stands."
  }
}

# ── CNPG backup passthrough ───────────────────────────────────────────────────
# Null renders no backup stanza at all, which is what this Cluster has always
# been. The key must be absent rather than present-and-empty: the CNPG webhook
# rejects an empty backup block naming a field the caller never wrote.
run "the_cnpg_cluster_writes_no_backup_stanza_by_default" {
  command = plan

  assert {
    condition     = !contains(keys(yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec), "backup")
    error_message = "spec.backup must be omitted when cnpg_backup is null, not rendered empty."
  }
}

run "cnpg_backup_reaches_the_cluster_spec" {
  command = plan

  variables {
    # A system image, so check.cnpg_backup_needs_barman_in_the_image stays
    # quiet: this run tests the passthrough, not the image pairing, which has
    # runs of its own below.
    cnpg_postgres_image_tag = "16"

    cnpg_backup = {
      retentionPolicy = "30d"
      barmanObjectStore = {
        destinationPath = "s3://n8n-backups/"
        endpointURL     = "https://minio.example.com"
      }
    }
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.backup.retentionPolicy == "30d"
    error_message = "cnpg_backup must reach spec.backup, or a caller configures archiving that never happens and believes they have backups."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.backup.barmanObjectStore.destinationPath == "s3://n8n-backups/"
    error_message = "Nested keys must pass through verbatim; the input is a passthrough precisely so the caller's own CNPG spelling survives."
  }

  # The rest of the spec has to survive the merge that added the stanza.
  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.instances == var.cnpg_instances
    error_message = "Adding a backup stanza must not disturb the rest of the Cluster spec."
  }
}

run "cnpg_backup_rejects_an_empty_object" {
  command = plan

  variables {
    cnpg_backup = {}
  }

  expect_failures = [var.cnpg_backup]
}

# On the external path there is no Cluster for this to reach, and the caller has
# written a destination and a credentials Secret by then, so the configuration
# reads as done while nothing archives.
run "cnpg_backup_on_the_external_backend_is_warned_about" {
  command = plan

  variables {
    postgres_backend = "external"
    db_host          = "postgres.example.com"
    db_password      = "not-a-real-password"

    cnpg_backup = {
      barmanObjectStore = {
        destinationPath = "s3://n8n-backups/"
      }
    }
  }

  expect_failures = [check.cnpg_backup_needs_the_cnpg_backend]
}

# ── CNPG-I plugins ────────────────────────────────────────────────────────────
# The passthrough to spec.plugins, wired the same way cnpg_backup is and
# covered the same way: present when set, absent when not, malformed shapes
# named at plan, and silence on the external path warned about.
run "the_cnpg_cluster_writes_no_plugins_stanza_by_default" {
  command = plan

  assert {
    condition     = !contains(keys(yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec), "plugins")
    error_message = "With cnpg_plugins unset, the Cluster spec must carry no plugins key at all: an empty stanza claims plugins and names none."
  }
}

run "cnpg_plugins_reach_the_cluster_spec" {
  command = plan

  variables {
    cnpg_plugins = [
      {
        name          = "barman-cloud.cloudnative-pg.io"
        isWALArchiver = true
        parameters    = { barmanObjectName = "n8n-backup-store" }
      }
    ]
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.plugins[0].name == "barman-cloud.cloudnative-pg.io"
    error_message = "cnpg_plugins must be passed through to spec.plugins verbatim; the first entry's name did not survive the trip."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.plugins[0].isWALArchiver == true
    error_message = "The passthrough must not reshape entries: isWALArchiver is what makes the plugin the archive command's owner, and dropping it silently changes who archives."
  }
}

run "cnpg_plugins_reject_an_empty_list" {
  command = plan

  variables {
    cnpg_plugins = []
  }

  expect_failures = [var.cnpg_plugins]
}

run "cnpg_plugins_reject_an_entry_without_a_name" {
  command = plan

  variables {
    cnpg_plugins = [{ isWALArchiver = true }]
  }

  expect_failures = [var.cnpg_plugins]
}

# The truth-test companion to the run above: a name that is present but empty
# dispatches to nothing just as surely, and it is the case a can()-wrapped
# alltrue would wave through, because can() tests only that the expression
# evaluates.
run "cnpg_plugins_reject_an_entry_with_an_empty_name" {
  command = plan

  variables {
    cnpg_plugins = [{ name = "" }]
  }

  expect_failures = [var.cnpg_plugins]
}

# And the type companion: a bare number satisfies a length-of-tostring check
# and then renders as a numeric name the CNPG schema rejects at apply, so the
# validation compares against tostring() instead, which Terraform's == makes
# hold only for an actual string.
run "cnpg_plugins_reject_a_numeric_name" {
  command = plan

  variables {
    cnpg_plugins = [{ name = 123 }]
  }

  expect_failures = [var.cnpg_plugins]
}

run "cnpg_plugins_on_the_external_backend_are_warned_about" {
  command = plan

  variables {
    postgres_backend = "external"
    db_host          = "postgres.example.com"
    db_password      = "not-a-real-password"

    cnpg_plugins = [{ name = "barman-cloud.cloudnative-pg.io" }]
  }

  expect_failures = [check.cnpg_plugins_need_the_cnpg_backend]
}

# ── Barman binaries and the image type ───────────────────────────────────────
# The in-tree spec.backup path runs barman-cloud binaries inside the operand
# image, and only the deprecated bare-tag system images still carry them. The
# default tag now names a minimal image, so the pairing that silently archives
# nothing is one default away and worth a warning with both names in it.
run "cnpg_backup_on_a_minimal_image_is_warned_about" {
  command = plan

  variables {
    cnpg_backup = {
      barmanObjectStore = {
        destinationPath = "s3://n8n-backups/"
      }
    }
  }

  expect_failures = [check.cnpg_backup_needs_barman_in_the_image]
}

run "cnpg_backup_on_a_system_image_draws_no_barman_warning" {
  command = plan

  variables {
    cnpg_postgres_image_tag = "16"

    cnpg_backup = {
      barmanObjectStore = {
        destinationPath = "s3://n8n-backups/"
      }
    }
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.backup.barmanObjectStore.destinationPath == "s3://n8n-backups/"
    error_message = "A bare-tag system image carries the barman-cloud binaries, so the in-tree backup on it is a working configuration and must pass without a warning."
  }
}

# The barman warning is about barmanObjectStore, not about spec.backup as a
# whole: a backup stanza carrying only volumeSnapshot settings runs no
# barman-cloud, so it is fine on the minimal default and must stay quiet.
run "cnpg_backup_of_snapshots_only_draws_no_barman_warning" {
  command = plan

  variables {
    cnpg_backup = {
      volumeSnapshot = {
        className = "csi-snapclass"
      }
    }
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.backup.volumeSnapshot.className == "csi-snapclass"
    error_message = "A snapshots-only backup stanza must pass through and draw no barman warning: nothing in it runs inside the operand image."
  }
}

# Both halves of the archive command claimed at once: barmanObjectStore in
# spec.backup and a plugin declaring isWALArchiver. The image is pinned to a
# system tag so the image-pairing check stays quiet and the only expected
# failure is the conflict itself.
run "cnpg_backup_with_a_wal_archiving_plugin_is_warned_about" {
  command = plan

  variables {
    cnpg_postgres_image_tag = "16"

    cnpg_backup = {
      barmanObjectStore = {
        destinationPath = "s3://n8n-backups/"
      }
    }

    cnpg_plugins = [
      {
        name          = "barman-cloud.cloudnative-pg.io"
        isWALArchiver = true
        parameters    = { barmanObjectName = "n8n-backup-store" }
      }
    ]
  }

  expect_failures = [check.cnpg_backup_and_a_wal_archiving_plugin_conflict]
}

# The same pairing without the archiver claim conflicts with nothing: a
# plugin that is not a WAL archiver shares the cluster with the in-tree
# backup fine.
run "cnpg_backup_with_a_non_archiving_plugin_draws_no_conflict" {
  command = plan

  variables {
    cnpg_postgres_image_tag = "16"

    cnpg_backup = {
      barmanObjectStore = {
        destinationPath = "s3://n8n-backups/"
      }
    }

    cnpg_plugins = [{ name = "some-other-plugin.example.io" }]
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.plugins[0].name == "some-other-plugin.example.io"
    error_message = "A plugin without isWALArchiver claims nothing the in-tree backup owns, so the combination must plan clean."
  }
}

run "the_default_image_tag_is_a_supported_upstream_spelling" {
  command = plan

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.imageName == "ghcr.io/cloudnative-pg/postgresql:18-minimal-trixie"
    error_message = "The default tag must be the qualified rolling major (18-minimal-trixie), not the deprecated bare spelling; got ${yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.imageName}."
  }
}


# ── Both Helm releases clean up after a failed release ────────────────────────
# A release that exceeds its timeout without atomic stays in the cluster while
# Terraform records no state for it, so every later apply fails with "cannot
# re-use a name that is still in use" until someone runs helm uninstall by
# hand. The n8n release was given the pair after exactly that happened; the
# Valkey release was left behind, and it is the worse half to diagnose, since
# the n8n release then waits on a queue that never arrives and reports its own
# timeout instead.
#
# The two flags are asserted separately because they cover different
# operations: atomic is what purges a failed install, and cleanup_on_fail is
# upgrade-only. Getting that backwards is how the install-side guard gets
# dropped while the suite stays green.
run "both_helm_releases_clean_up_after_a_failed_release" {
  command = plan

  # helm_release.valkey is count-gated on this, and an empty list makes
  # alltrue() below return true. Pinning the backend is what keeps the two
  # Valkey assertions from passing on a release that was never planned - it
  # is the default today, but a default is not a guarantee, and the failure
  # mode of getting this wrong is a green suite asserting nothing.
  variables {
    redis_backend = "valkey"
  }

  assert {
    condition     = helm_release.n8n.atomic && helm_release.n8n.cleanup_on_fail
    error_message = "helm_release.n8n must stay atomic with cleanup_on_fail, or a timed-out install strands a release Terraform does not know about."
  }

  assert {
    condition     = alltrue([for r in helm_release.valkey : r.atomic])
    error_message = "helm_release.valkey must be atomic for the same reason helm_release.n8n is: without it a timed-out install strands a release Terraform has no state for, and every later apply fails on the name still being in use."
  }

  assert {
    condition     = alltrue([for r in helm_release.valkey : r.cleanup_on_fail])
    error_message = "helm_release.valkey must set cleanup_on_fail, or a failed upgrade leaves behind the resources it created for a revision that was then rolled back."
  }
}

# F-006: the Helm provider resolves an https:// repository through its
# index.yaml, which needs the repository and the bare chart name as separate
# arguments; an oci:// reference carries the path in the chart argument
# instead. Only the oci:// shape was ever built, so an https:// mirror
# rendered an unresolvable reference no index-backed repository serves.
run "the_oci_chart_repository_keeps_its_own_shape" {
  command = plan

  assert {
    condition     = helm_release.n8n.repository == null && helm_release.n8n.chart == "${var.n8n_chart_repository}/n8n"
    error_message = "The default oci:// repository must render with a null repository argument and the full oci:// path folded into chart, exactly as before."
  }
}

run "an_https_chart_repository_resolves_through_its_index" {
  command = plan

  variables {
    n8n_chart_repository = "https://community-charts.github.io/helm-charts"
  }

  assert {
    condition     = helm_release.n8n.repository == "https://community-charts.github.io/helm-charts" && helm_release.n8n.chart == "n8n"
    error_message = "An https:// repository must render with the repository argument set and chart as the bare name, the same shape helm_release.valkey already uses; the oci:// shape renders no index this provider can resolve."
  }
}

# F-049: both chart repositories reject a trailing slash. The module appends
# /n8n to an OCI repository itself, so a mirror pasted with a slash would
# render a double-slash reference.
run "n8n_chart_repository_rejects_a_trailing_slash" {
  command = plan

  variables {
    n8n_chart_repository = "oci://ghcr.io/n8n-io/n8n-helm-chart/"
  }

  expect_failures = [var.n8n_chart_repository]
}

run "valkey_chart_repository_rejects_a_trailing_slash" {
  command = plan

  variables {
    valkey_chart_repository = "https://valkey-io.github.io/valkey-helm/"
  }

  expect_failures = [var.valkey_chart_repository]
}

# F-050: valkey_chart_version takes n8n_chart_version's exact-SemVer rule.
run "valkey_chart_version_rejects_a_range" {
  command = plan

  variables {
    valkey_chart_version = "~> 0.12.0"
  }

  expect_failures = [var.valkey_chart_version]
}

# ── The namespace gets long enough to finish deleting ─────────────────────────
# Deleting this namespace waits on a CNPG Cluster tearing down and PVCs whose
# provisioner has to detach real volumes, which ran past the 2m this used to
# allow. The destroy then reported "context deadline exceeded" for a deletion
# that completed on its own minutes later, leaving a namespace in state that
# no longer existed. Pinned because the failure only shows up on a real
# destroy, which no test performs.
run "the_namespace_delete_timeout_outlasts_a_real_teardown" {
  command = plan

  # kubernetes_namespace.n8n is count-gated on this, and alltrue() over an
  # empty list returns true. Pinned for the same reason the Valkey run above
  # pins redis_backend: it is the default today, but a default is not a
  # guarantee.
  variables {
    create_namespace = true
  }

  assert {
    condition     = alltrue([for n in kubernetes_namespace.n8n : n.timeouts.delete == "10m"])
    error_message = "kubernetes_namespace.n8n must allow 10m to delete. Shorter, and a destroy that is merely waiting on storage reclaim fails while the namespace goes on to delete successfully, which reads as a broken destroy against a cluster that is already clean."
  }
}

# ── Proxy hops ────────────────────────────────────────────────────────────────
# The count was a literal 1 gated on create_ingress, so a caller running their
# own routing got no N8N_PROXY_HOPS at all and n8n attributed every request to
# the ingress controller's own address. Both split-ingress examples worked
# around that through n8n_extra_env, which is the escape hatch doing a typed
# input's job.
run "proxy_hops_are_rendered_on_both_routing_paths" {
  command = plan

  assert {
    condition = one([
      for e in local.k8s_values_config.config.extraEnv : e.value if e.name == "N8N_PROXY_HOPS"
    ]) == "1"
    error_message = "N8N_PROXY_HOPS must render from n8n_proxy_hops when the module owns the Ingress."
  }
}

run "proxy_hops_reach_a_caller_owned_ingress_too" {
  command = plan

  variables {
    create_ingress = false
    n8n_proxy_hops = 2
  }

  assert {
    condition = one([
      for e in local.k8s_values_config.config.extraEnv : e.value if e.name == "N8N_PROXY_HOPS"
    ]) == "2"
    error_message = "N8N_PROXY_HOPS must render with create_ingress = false. A caller running their own routing is behind a proxy just the same, and emitting nothing there makes n8n read the ingress controller as the client for every request."
  }
}

# The module writes this name, so a second entry of the same name from the
# escape hatch is the duplicate that fails every later helm upgrade's
# strategic merge patch, rollback included.
run "proxy_hops_are_reserved_against_the_env_escape_hatch" {
  command = plan

  variables {
    n8n_extra_env = [{ name = "N8N_PROXY_HOPS", value = "3" }]
  }

  expect_failures = [var.n8n_extra_env]
}

# ── One payload limit, two consumers ───────────────────────────────────────────
# F-060/F-079: n8n_payload_size_max is null by default, which leaves n8n's own
# 16 MiB unset and the Ingress proxy-body-size annotation at its original
# literal (32m) exactly as today. Setting it derives both N8N_PAYLOAD_SIZE_MAX
# and the annotation from the same value plus 2 MiB of multipart-framing
# headroom, so the proxy and n8n cannot be made to disagree once either one is
# tuned. ingress_proxy_body_size mirrors the same derivation for
# create_ingress = false callers.

run "payload_size_max_null_leaves_todays_defaults_untouched" {
  command = plan

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv : e if e.name == "N8N_PAYLOAD_SIZE_MAX"
    ]) == 0
    error_message = "With n8n_payload_size_max left null, N8N_PAYLOAD_SIZE_MAX must not be rendered, so n8n keeps its own 16 MiB default unset."
  }

  assert {
    condition     = local.k8s_ingress_annotations["nginx.ingress.kubernetes.io/proxy-body-size"] == "32m"
    error_message = "With n8n_payload_size_max left null, the proxy-body-size annotation must stay at its original literal."
  }

  assert {
    condition     = output.ingress_proxy_body_size == "32m"
    error_message = "ingress_proxy_body_size must mirror the same literal while the input is unset."
  }
}

run "setting_the_payload_limit_moves_both_consumers_together" {
  command = plan

  variables {
    n8n_payload_size_max = 30
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : "${e.name}=${e.value}"],
      "N8N_PAYLOAD_SIZE_MAX=30",
    )
    error_message = "Setting n8n_payload_size_max must render N8N_PAYLOAD_SIZE_MAX on every pod type."
  }

  assert {
    condition     = local.k8s_ingress_annotations["nginx.ingress.kubernetes.io/proxy-body-size"] == "32m"
    error_message = "The proxy annotation must derive from the same input, with the 2 MiB headroom (30 + 2)."
  }

  assert {
    condition     = output.ingress_proxy_body_size == local.k8s_ingress_annotations["nginx.ingress.kubernetes.io/proxy-body-size"]
    error_message = "The exported body size must always equal the module's own rendered annotation, so a caller-owned Ingress cannot drift from it."
  }
}

run "payload_size_max_rejects_a_fraction" {
  command = plan

  variables {
    n8n_payload_size_max = 16.5
  }

  expect_failures = [var.n8n_payload_size_max]
}

run "payload_size_max_rejects_zero" {
  command = plan

  variables {
    n8n_payload_size_max = 0
  }

  expect_failures = [var.n8n_payload_size_max]
}

run "proxy_hops_reject_a_count_that_is_not_a_hop" {
  command = plan

  variables {
    n8n_proxy_hops = 1.5
  }

  expect_failures = [var.n8n_proxy_hops]
}

# Zero hops is legitimate, but only with nothing in front of the pods. Behind
# an Ingress the connecting address is always the controller's, so trusting no
# forwarded header makes every request look like it came from one host.
# create_ingress is only half the answer: n8n_extra_helm_values is merged last
# and decides whether an Ingress is really rendered, so the check reads the
# effective value and the five merge outcomes are each covered below.
run "zero_hops_behind_the_modules_own_ingress_is_caught" {
  command = plan

  variables {
    create_ingress = true
    n8n_proxy_hops = 0
  }

  expect_failures = [check.an_ingress_in_front_means_at_least_one_proxy_hop]
}

run "zero_hops_with_nothing_in_front_is_allowed" {
  command = plan

  variables {
    create_ingress = false
    n8n_proxy_hops = 0
  }

  assert {
    condition     = !local.n8n_ingress_rendered
    error_message = "With create_ingress = false and no overlay, no Ingress is rendered, so zero hops is the honest answer and the check must stay quiet."
  }
}

# The overlay can add the Ingress the module did not create. create_ingress is
# false here, so a check reading the input alone would say nothing.
run "an_overlay_that_adds_an_ingress_is_caught_too" {
  command = plan

  variables {
    create_ingress        = false
    n8n_proxy_hops        = 0
    n8n_extra_helm_values = <<-YAML
      ingress:
        enabled: true
    YAML
  }

  expect_failures = [check.an_ingress_in_front_means_at_least_one_proxy_hop]
}

# And it can remove the one the module did create, which is the false-positive
# direction: create_ingress is true, so a check reading the input alone would
# fire on a deployment that has no Ingress at all.
run "an_overlay_that_removes_the_ingress_silences_the_check" {
  command = plan

  variables {
    create_ingress        = true
    n8n_proxy_hops        = 0
    n8n_extra_helm_values = <<-YAML
      ingress:
        enabled: false
    YAML
  }

  assert {
    condition     = !local.n8n_ingress_rendered
    error_message = "An overlay setting ingress.enabled false wins over create_ingress, so nothing is in front of the pods and zero hops is correct."
  }
}

# Both deletion shapes. Helm treats an explicit null as a deletion rather than
# an absence, and what is left is chart 1.10.0's own ingress.enabled, which is
# false. So a deleted key means no Ingress, the same as an explicit false.
run "nulling_the_ingress_key_falls_back_to_the_charts_own_false" {
  command = plan

  variables {
    create_ingress        = true
    n8n_proxy_hops        = 0
    n8n_extra_helm_values = "ingress: null"
  }

  assert {
    condition     = local.n8n_extra_deletes_ingress && !local.n8n_ingress_rendered
    error_message = "ingress: null deletes the module's whole block, leaving the chart's own default of false."
  }
}

run "nulling_only_ingress_enabled_is_told_apart_from_the_whole_key" {
  command = plan

  variables {
    create_ingress        = true
    n8n_proxy_hops        = 0
    n8n_extra_helm_values = <<-YAML
      ingress:
        enabled: null
        className: nginx
    YAML
  }

  assert {
    condition     = local.n8n_extra_deletes_ingress_enabled && !local.n8n_extra_deletes_ingress
    error_message = "Nulling ingress.enabled deletes only that key; the sibling className survives the merge, so the whole-key deletion must stay false."
  }

  assert {
    condition     = !local.n8n_ingress_rendered
    error_message = "Either deletion leaves ingress.enabled unset, and the chart defaults it to false."
  }
}

# The two merge rows, where the module's value has to survive untouched.
run "an_overlay_declaring_ingress_without_enabled_keeps_the_module_value" {
  command = plan

  variables {
    create_ingress        = true
    n8n_proxy_hops        = 0
    n8n_extra_helm_values = <<-YAML
      ingress:
        className: nginx
    YAML
  }

  expect_failures = [check.an_ingress_in_front_means_at_least_one_proxy_hop]
}

# ── A worker floor of zero deletes the pool ───────────────────────────────────
# The input was documented as accepting 0 because "KEDA scales a ScaledObject
# to zero natively". KEDA does, but this value is also
# queueMode.workerReplicaCount, and chart 1.10.0 gates both the worker
# Deployment and the worker ScaledObject on `gt (int workerReplicaCount) 0`.
# So 0 rendered no Deployment, no ScaledObject and no HPA: the editor works,
# webhooks answer, the queue fills, and no execution ever runs.
run "a_worker_floor_of_zero_is_rejected" {
  command = plan

  variables {
    n8n_worker_keda_min_replicas = 0
  }

  expect_failures = [var.n8n_worker_keda_min_replicas]
}

# Rejected on the KEDA path too, which is the one the old justification was
# written for. The ScaledObject the reasoning depended on is gated on the same
# number, so attesting KEDA does not rescue it.
run "a_worker_floor_of_zero_is_rejected_even_with_keda" {
  command = plan

  variables {
    n8n_worker_keda_min_replicas = 0
    k8s_keda_installed           = true
  }

  expect_failures = [var.n8n_worker_keda_min_replicas]
}

run "the_worker_floor_keeps_a_pool_that_can_be_scaled" {
  command = plan

  assert {
    condition     = var.n8n_worker_keda_min_replicas >= 1
    error_message = "The default worker floor must render a worker Deployment, or the chart gates it away along with anything that could scale it back."
  }

  assert {
    condition     = local.k8s_values_final.queueMode.workerReplicaCount >= 1
    error_message = "queueMode.workerReplicaCount is what the chart gates the worker Deployment and ScaledObject on; below 1 it renders neither."
  }
}

# n8n_webhook_hpa_enabled exists to let a caller attach their own policy, and
# on the KEDA path it did not: the chart ignores hpa.webhookProcessor.enabled
# whenever keda.enabled is true, and this resource was gated on the KEDA
# attestation alone. Turning the input off removed nothing, so a caller's own
# VPA or custom-metrics HPA ended up fighting this one over the same
# Deployment.
run "disabling_the_webhook_hpa_removes_it_on_the_keda_path_too" {
  command = plan

  variables {
    k8s_keda_installed      = true
    n8n_webhook_hpa_enabled = false
  }

  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook_processor) == 0
    error_message = "n8n_webhook_hpa_enabled = false must remove the supplementary HPA on the KEDA path. Leaving it renders a controller the caller asked not to have, competing with whatever they attached instead."
  }

  # The chart must not quietly render one either, or disabling the input just
  # moves which controller owns the Deployment.
  assert {
    condition     = local.k8s_values_final.hpa.webhookProcessor.enabled == false
    error_message = "hpa.webhookProcessor.enabled must follow the same input, so that off means off on both sides."
  }

  # Replica count is a separate concern: the chart renders spec.replicas
  # unconditionally, so the pool holds its floor rather than dropping to zero.
  assert {
    condition     = local.k8s_values_final.webhookProcessor.replicaCount == var.n8n_webhook_hpa_min_replicas
    error_message = "With no autoscaler the webhook pool must still hold n8n_webhook_hpa_min_replicas; disabling autoscaling should remove what changes the count, not the count itself."
  }
}

run "without_keda_the_chart_owns_the_webhook_hpa_alone" {
  command = plan

  variables {
    k8s_keda_installed = false
  }

  # Two controllers on one Deployment fight over the replica count, so off the
  # KEDA path the module must render nothing and leave the chart's HPA to it.
  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook_processor) == 0
    error_message = "Without KEDA the chart renders its own webhook HPA; a second one would fight it for the replica count."
  }

  assert {
    condition     = local.k8s_values_hpa.hpa.webhookProcessor.enabled == true
    error_message = "The chart's webhook HPA must stay enabled on the non-KEDA path."
  }
}

# ── A null boolean input must omit its env var, not render an empty string ────
# tostring(null) is "", and n8n answers an empty boolean with "Invalid boolean
# value for N8N_UNVERIFIED_PACKAGES_ENABLED:" before ignoring it. Caught on a
# live cluster, in the first ten lines of the main pod's very first boot.

run "a_null_boolean_input_renders_no_env_var" {
  command = plan

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv :
      e if e.name == "N8N_UNVERIFIED_PACKAGES_ENABLED"
    ]) == 0
    error_message = "n8n_unverified_packages_enabled defaults to null, and its description promises that omits the variable entirely."
  }

  # Nothing else may render an empty value either: an empty string is a
  # configured-looking non-answer, and n8n treats each one differently.
  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv : e if e.value == ""
    ]) == 0
    error_message = "An env var rendered with an empty value reached the chart. Gate it on null instead."
  }
}

run "a_set_boolean_input_still_renders_its_env_var" {
  command = plan

  variables {
    n8n_unverified_packages_enabled = true
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "N8N_UNVERIFIED_PACKAGES_ENABLED", value = "true" }
    )
    error_message = "Setting n8n_unverified_packages_enabled must still reach the pods."
  }
}

# ── No env name may be rendered twice ─────────────────────────────────────────
# Kubernetes keys a container's env list by name. A duplicate applies fine on
# create, last-wins at runtime, and then fails the strategic merge patch on
# every subsequent helm upgrade, taking the automatic rollback down with it and
# leaving the release stuck in `failed`. Found only on the second live apply.
#
# local.n8n_managed_env_names is the list of names the chart renders itself, so
# an extraEnv entry sharing one of those names is the duplicate.

run "no_extra_env_name_collides_with_a_chart_rendered_name" {
  command = plan

  variables {
    create_ingress             = true
    k8s_ingress_cluster_issuer = "letsencrypt-prod"
    n8n_metrics_enabled        = true
    n8n_task_runners_enabled   = true
  }

  # Read off a live n8n-1.10.0 release, and updated for chart 1.16.0's rename
  # of WEBHOOK_URL to N8N_WEBHOOK_URL (confirmed by rendering this module's
  # values through the pinned chart): every name the chart puts in a
  # container's env list itself, via configMapKeyRef or secretKeyRef, across
  # all three pod types. Anything here has a typed chart value and must be set
  # that way, never appended.
  assert {
    condition = length(setintersection(
      toset([for e in local.k8s_values_config.config.extraEnv : e.name]),
      toset([
        "DB_POSTGRESDB_DATABASE", "DB_POSTGRESDB_HOST", "DB_POSTGRESDB_PASSWORD",
        "DB_POSTGRESDB_PORT", "DB_POSTGRESDB_SCHEMA", "DB_POSTGRESDB_USER",
        "DB_TYPE", "EXECUTIONS_MODE", "N8N_DISABLE_PRODUCTION_MAIN_PROCESS",
        "N8N_EDITOR_BASE_URL", "N8N_ENCRYPTION_KEY",
        "N8N_GRACEFUL_SHUTDOWN_TIMEOUT", "N8N_HOST", "N8N_NATIVE_PYTHON_RUNNER",
        "N8N_PORT", "N8N_PROTOCOL", "N8N_RUNNERS_AUTH_TOKEN",
        "N8N_RUNNERS_BROKER_LISTEN_ADDRESS", "N8N_RUNNERS_MODE",
        "N8N_WEBHOOK_TIMEOUT", "OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS",
        "QUEUE_BULL_REDIS_HOST", "QUEUE_BULL_REDIS_PASSWORD",
        "QUEUE_BULL_REDIS_PORT", "QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD",
        "QUEUE_WORKER_LOCK_DURATION", "QUEUE_WORKER_LOCK_RENEW_TIME",
        "QUEUE_WORKER_MAX_STALLED_COUNT", "QUEUE_WORKER_STALLED_INTERVAL",
        "TZ", "N8N_WEBHOOK_URL", "EXECUTIONS_DATA_SAVE_ON_SUCCESS",
        "EXECUTIONS_DATA_SAVE_ON_ERROR", "EXECUTIONS_DATA_SAVE_ON_PROGRESS",
        "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS",
      ]),
    )) == 0
    error_message = "An env var the chart already renders is also appended to config.extraEnv. The duplicate applies once and then fails every helm upgrade - set the chart's typed value instead."
  }

  assert {
    condition = length([for e in local.k8s_values_config.config.extraEnv : e.name]) == length(distinct([
      for e in local.k8s_values_config.config.extraEnv : e.name
    ]))
    error_message = "config.extraEnv renders the same name more than once."
  }
}

# The duplicate check above only sees what the module itself renders, because
# n8n_extra_env is empty in that run. n8n_metrics_enabled sets three names but
# only N8N_METRICS was reserved, so the other two could be appended by a caller
# and the module rendered one of them twice in a single container's env list.
# Kubernetes takes the last, silently, which is the exact failure the reserved
# list exists to prevent.

run "the_metrics_include_toggles_the_module_owns_are_reserved" {
  command = plan

  variables {
    n8n_metrics_enabled = true
    n8n_extra_env = [
      { name = "N8N_METRICS_INCLUDE_QUEUE_METRICS", value = "false" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "the_metrics_include_toggles_are_reserved_in_the_secret_form_too" {
  command = plan

  variables {
    n8n_metrics_enabled = true
    n8n_extra_env_from_secret = [
      { name = "N8N_METRICS_INCLUDE_CACHE_METRICS", secret_name = "s", secret_key = "k" },
    ]
  }

  expect_failures = [var.n8n_extra_env_from_secret]
}

# The other side of it: the module still sets all three, exactly once each. A
# reserved name that stops being rendered is just a name the caller can no
# longer set.
run "enabling_metrics_renders_all_three_env_vars_once" {
  command = plan

  variables {
    n8n_metrics_enabled = true
  }

  assert {
    condition = nonsensitive(length([
      for e in local.k8s_values_config.config.extraEnv :
      e if contains([
        "N8N_METRICS",
        "N8N_METRICS_INCLUDE_QUEUE_METRICS",
        "N8N_METRICS_INCLUDE_CACHE_METRICS",
      ], e.name) && e.value == "true"
    ])) == 3
    error_message = "n8n_metrics_enabled must render N8N_METRICS, N8N_METRICS_INCLUDE_QUEUE_METRICS and N8N_METRICS_INCLUDE_CACHE_METRICS, each once and each true."
  }
}

# The remaining N8N_METRICS_INCLUDE_* groups are the caller's. Reserving the
# whole N8N_METRICS_ prefix would have been the lazy fix and would have taken
# those away, leaving no way to turn on the webhook, scheduler or DB-pool
# families the module has no opinion about.
run "the_metrics_groups_the_module_does_not_set_stay_callable" {
  command = plan

  variables {
    n8n_metrics_enabled = true
    n8n_extra_env = [
      { name = "N8N_METRICS_INCLUDE_WORKFLOW_ID_LABEL", value = "true" },
    ]
  }

  assert {
    condition = nonsensitive(length([
      for e in local.k8s_values_config.config.extraEnv :
      e if e.name == "N8N_METRICS_INCLUDE_WORKFLOW_ID_LABEL"
    ])) == 1
    error_message = "A N8N_METRICS_INCLUDE_* group the module does not set must remain settable through n8n_extra_env."
  }
}

# ── The external Postgres path honours what the caller configured ─────────────
# The mirror of the external-Redis block above, and added for the same reason:
# port, database and user were hardcoded in the rendered values tree, the last
# two reading from inputs documented "Only used when postgres_backend = cnpg".
# An external Postgres therefore had to be n8n/n8n on 5432 or it was
# unreachable, and nothing failed at plan time to say so.

run "an_external_postgres_uses_the_caller_endpoint" {
  command = plan

  variables {
    postgres_backend = "external"
    db_host          = "postgres.internal.example.com"
    db_port          = 5433
    db_name          = "n8n_prod"
    db_user          = "n8n_app"
    db_password      = "not-a-real-password"
  }

  assert {
    condition     = local.k8s_values_database.database.host == "postgres.internal.example.com"
    error_message = "db_host must reach the chart on the external path."
  }

  assert {
    condition     = local.k8s_values_database.database.port == 5433
    error_message = "db_port must reach the chart on the external path; 5432 is only guaranteed for the CNPG rw Service."
  }

  assert {
    condition     = local.k8s_values_database.database.database == "n8n_prod"
    error_message = "db_name must reach the chart, otherwise an external server whose database is not called \"n8n\" cannot be used."
  }

  assert {
    condition     = local.k8s_values_database.database.user == "n8n_app"
    error_message = "db_user must reach the chart, otherwise an external server whose role is not called \"n8n\" cannot authenticate."
  }
}

run "the_in_cluster_postgres_ignores_external_connection_inputs" {
  command = plan

  variables {
    db_port = 5433
    db_name = "ignored"
    db_user = "ignored"
  }

  assert {
    condition     = local.k8s_values_database.database.port == 5432
    error_message = "The CNPG rw Service listens on 5432; an external port input must not override that."
  }

  assert {
    condition = (
      local.k8s_values_database.database.database == var.cnpg_database_name &&
      local.k8s_values_database.database.user == var.cnpg_database_owner
    )
    error_message = "On the cnpg path the database and owner are what the operator bootstrapped, so the cnpg_* inputs decide them."
  }
}

# F-050: both names are rendered unquoted into the Cluster CR and a connection
# string, so they are validated as unquoted Postgres identifiers.
run "cnpg_database_name_rejects_a_value_that_needs_quoting" {
  command = plan

  variables {
    cnpg_database_name = "n8n-prod"
  }

  expect_failures = [var.cnpg_database_name]
}

run "cnpg_database_owner_rejects_a_leading_digit" {
  command = plan

  variables {
    cnpg_database_owner = "9n8n"
  }

  expect_failures = [var.cnpg_database_owner]
}

# F-050: the two storage-size inputs take the same Kubernetes quantity shape
# every memory input here already enforces.
run "cnpg_storage_size_rejects_a_malformed_quantity" {
  command = plan

  variables {
    cnpg_storage_size = "10 gigs"
  }

  expect_failures = [var.cnpg_storage_size]
}

run "valkey_storage_size_rejects_a_malformed_quantity" {
  command = plan

  variables {
    valkey_storage_size = "8GB"
  }

  expect_failures = [var.valkey_storage_size]
}

run "the_external_postgres_defaults_match_the_cnpg_ones" {
  command = plan

  variables {
    postgres_backend = "external"
    db_host          = "postgres.internal.example.com"
    db_password      = "not-a-real-password"
  }

  # Unset, the two paths must describe the same deployment. Anything else makes
  # "point this at your own Postgres" a silent change of database name.
  assert {
    condition = (
      local.k8s_values_database.database.port == 5432 &&
      local.k8s_values_database.database.database == "n8n" &&
      local.k8s_values_database.database.user == "n8n"
    )
    error_message = "The external path's defaults must match the CNPG path: port 5432, database n8n, user n8n."
  }
}

run "no_cnpg_cluster_is_planned_on_the_external_path" {
  command = plan

  variables {
    postgres_backend = "external"
    db_host          = "postgres.internal.example.com"
    db_password      = "not-a-real-password"
  }

  assert {
    condition     = length(kubectl_manifest.cnpg_cluster) == 0
    error_message = "postgres_backend = \"external\" must plan no CNPG Cluster; the caller's server is the database."
  }
}

run "an_external_postgres_without_a_host_is_rejected" {
  command = plan

  variables {
    postgres_backend = "external"
    db_password      = "not-a-real-password"
  }

  expect_failures = [var.db_host]
}

run "a_database_port_outside_the_tcp_range_is_rejected" {
  command = plan

  variables {
    db_port = 70000
  }

  expect_failures = [var.db_port]
}

# ── Postgres TLS has exactly one source per name ──────────────────────────────
# DB_POSTGRESDB_SSL_ENABLED and DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED are
# expressed through config.extraEnv (db_postgresdb_ssl_enabled and
# db_postgresdb_ssl_reject_unauthorized), never through the chart's
# database.ssl.enabled/.rejectUnauthorized: before chart 1.15.0 the enable flag
# rendered DB_POSTGRESDB_SSL, a name n8n does not read, and rejectUnauthorized
# = false renders a name this module already emits unconditionally, which
# duplicates an env var and fails every later helm upgrade. The one exception
# is database.ssl.ca, the only way to deliver a CA bundle to the chart: see
# "a_ca_bundle_reaches_the_chart_without_duplicating_ssl_enabled" below for how
# that case avoids the same collision.

run "the_chart_ssl_key_stays_unset_without_a_ca" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled = true
  }

  assert {
    condition     = !contains(keys(local.k8s_values_database.database), "ssl")
    error_message = "database.ssl must stay unset with no CA configured: its enable flag renders DB_POSTGRESDB_SSL on charts before 1.15.0, and its rejectUnauthorized renders a name this module already emits."
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name if e.name == "DB_POSTGRESDB_SSL_ENABLED"],
      "DB_POSTGRESDB_SSL_ENABLED",
    )
    error_message = "DB_POSTGRESDB_SSL_ENABLED must be rendered through config.extraEnv when no CA is being delivered."
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED", value = "false" }
    )
    error_message = "db_postgresdb_ssl_reject_unauthorized must default to false, preserving this module's original behavior."
  }
}

run "disabling_tls_still_leaves_the_chart_key_unset" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled = false
  }

  assert {
    condition     = !contains(keys(local.k8s_values_database.database), "ssl")
    error_message = "database.ssl must stay unset on both sides of db_postgresdb_ssl_enabled."
  }
}

# A fixed, framing-valid test CA. Not a real issuing authority; only the PEM
# delimiters and ASCII content are exercised by the variable's own validation
# and by these plan-time assertions.
run "a_ca_bundle_reaches_the_chart_without_duplicating_ssl_enabled" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "  -----BEGIN CERTIFICATE-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A\n-----END CERTIFICATE-----  \n"
  }

  # The chart (pinned at n8n_chart_version's default) renders
  # DB_POSTGRESDB_SSL_ENABLED from database.ssl.enabled on its own at this
  # version, so the module must not also carry it in config.extraEnv: a
  # second entry of that name is the duplicate that fails every later helm
  # upgrade.
  assert {
    condition = !contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name],
      "DB_POSTGRESDB_SSL_ENABLED",
    )
    error_message = "DB_POSTGRESDB_SSL_ENABLED must not be rendered through config.extraEnv once the chart already carries it through database.ssl.enabled."
  }

  # config.extraEnv stays the one source of DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED
  # regardless: the chart's own database.ssl.rejectUnauthorized is pinned true
  # by local.postgres_ssl_ca_values, which suppresses its conditional render of
  # that same name.
  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED", value = "true" }
    )
    error_message = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED must still be rendered through config.extraEnv even while a CA is active."
  }

  assert {
    condition = local.k8s_values_database.database.ssl == {
      enabled            = true
      rejectUnauthorized = true
      ca                 = "-----BEGIN CERTIFICATE-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A\n-----END CERTIFICATE-----"
    }
    error_message = "database.ssl must carry the trimmed CA with enabled and rejectUnauthorized both pinned true."
  }
}

# A chart repository the module cannot verify (a mirror, here) falls back to
# keeping config.extraEnv's own DB_POSTGRESDB_SSL_ENABLED even while a CA is
# active, trading a possible duplicate for a possible missing entry: the safer
# direction per local.n8n_chart_renders_postgres_ssl_enabled in locals.tf.
run "an_unverifiable_chart_repository_keeps_its_own_ssl_enabled_entry" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A\n-----END CERTIFICATE-----"
    n8n_chart_repository                  = "oci://registry.example.com/mirror/n8n-helm-chart"
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name],
      "DB_POSTGRESDB_SSL_ENABLED",
    )
    error_message = "An unverified chart repository must keep config.extraEnv's own DB_POSTGRESDB_SSL_ENABLED entry rather than assume the mirrored chart renders it from database.ssl.enabled."
  }
}

# ── Postgres TLS plan-time warnings ────────────────────────────────────────────

run "a_ca_with_verification_off_is_warned_about" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = false
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A\n-----END CERTIFICATE-----"
  }

  expect_failures = [check.db_postgresdb_ssl_ca_pem_requires_verification]
}

run "a_ca_with_tls_off_entirely_is_warned_about_too" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled = false
    db_postgresdb_ssl_ca_pem  = "-----BEGIN CERTIFICATE-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A\n-----END CERTIFICATE-----"
  }

  expect_failures = [check.db_postgresdb_ssl_ca_pem_requires_verification]
}

run "verification_on_with_a_ca_draws_no_warning" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A\n-----END CERTIFICATE-----"
  }
}

# NODE_TLS_REJECT_UNAUTHORIZED=0 only matters on the no-CA verifying path: see
# the comment on check.postgres_ssl_verification_disabled_by_node_tls_env
# (n8n.tf) for why a CA makes the variable irrelevant.
run "node_tls_reject_unauthorized_env_defeats_verification_with_no_ca" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    n8n_extra_env = [
      { name = "NODE_TLS_REJECT_UNAUTHORIZED", value = "0" },
    ]
  }

  expect_failures = [check.postgres_ssl_verification_disabled_by_node_tls_env]
}

run "node_tls_reject_unauthorized_env_is_moot_once_a_ca_is_set" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A\n-----END CERTIFICATE-----"
    n8n_extra_env = [
      { name = "NODE_TLS_REJECT_UNAUTHORIZED", value = "0" },
    ]
  }
}

run "node_tls_reject_unauthorized_env_is_fine_with_verification_off" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = false
    n8n_extra_env = [
      { name = "NODE_TLS_REJECT_UNAUTHORIZED", value = "0" },
    ]
  }
}

# ── db_postgresdb_ssl_ca_pem's own validation ──────────────────────────────────

run "ca_pem_rejects_text_without_pem_framing" {
  command = plan

  variables {
    db_postgresdb_ssl_ca_pem = "not a certificate"
  }

  expect_failures = [var.db_postgresdb_ssl_ca_pem]
}

run "ca_pem_rejects_non_ascii_content" {
  command = plan

  variables {
    db_postgresdb_ssl_ca_pem = "-----BEGIN CERTIFICATE-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8Añ\n-----END CERTIFICATE-----"
  }

  expect_failures = [var.db_postgresdb_ssl_ca_pem]
}

# 128 * 1024 "A"s, well past what either bundle below needs; substr trims to
# the exact body length each test wants. Built from two nested range() calls,
# each under range()'s own 1024-value cap, rather than one call for the whole
# ~131 KB body.
run "ca_pem_rejects_a_bundle_over_the_env_var_size_limit" {
  command = plan

  variables {
    # One character of body past the 131050 trimmed-length limit.
    db_postgresdb_ssl_ca_pem = "-----BEGIN CERTIFICATE-----\n${substr(join("", [for i in range(128) : join("", [for j in range(1024) : "A"])]), 0, 131050 - length("-----BEGIN CERTIFICATE-----\n\n-----END CERTIFICATE-----") + 1)}\n-----END CERTIFICATE-----"
  }

  expect_failures = [var.db_postgresdb_ssl_ca_pem]
}

run "ca_pem_accepts_a_bundle_at_exactly_the_size_limit" {
  command = plan

  variables {
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\n${substr(join("", [for i in range(128) : join("", [for j in range(1024) : "A"])]), 0, 131050 - length("-----BEGIN CERTIFICATE-----\n\n-----END CERTIFICATE-----"))}\n-----END CERTIFICATE-----"
  }

  assert {
    condition     = length(trimspace(var.db_postgresdb_ssl_ca_pem)) == 131050
    error_message = "Test setup error: the generated bundle must be exactly 131050 trimmed characters to exercise the boundary."
  }
}

run "ca_pem_null_is_the_default" {
  command = plan

  assert {
    condition     = var.db_postgresdb_ssl_ca_pem == null
    error_message = "db_postgresdb_ssl_ca_pem must default to null."
  }
}

# ── Binary-data mode is the caller's to set, through the input ────────────────
# These two names went reserved, then unreserved, then reserved again, and the
# round trip is the point. The chart never renders them: 1.10.0 emits them only
# from the n8n.s3Env helper, gated on s3.enabled, which this module pins false.
# So the original guard blocked a name nothing set, and unreserving them was the
# right call at the time, because n8n defaults binary data to "database" in the
# scaling mode this module always runs and a caller needed some way to say
# otherwise. n8n_binary_data_mode is that way now, and it comes with the
# shared-mount check the raw env var could never have.

run "a_caller_can_choose_filesystem_binary_data" {
  command = plan

  variables {
    n8n_binary_data_mode = "filesystem"
    n8n_binary_data_path = "/opt/n8n-shared"

    n8n_extra_volumes = [{
      name                    = "shared"
      persistent_volume_claim = { claim_name = "n8n-shared" }
    }]

    n8n_extra_volume_mounts = [{
      name       = "shared"
      mount_path = "/opt/n8n-shared"
      read_only  = false
    }]
  }

  assert {
    condition = length(setintersection(
      toset([for e in local.k8s_values_config.config.extraEnv : e.name]),
      toset(["N8N_DEFAULT_BINARY_DATA_MODE", "N8N_STORAGE_PATH"]),
    )) == 2
    error_message = "A caller must be able to put binary data on a shared volume; both names have to reach config.extraEnv."
  }

  # Still exactly once each, the reason the guard existed at all.
  assert {
    condition = length([for e in local.k8s_values_config.config.extraEnv : e.name]) == length(distinct([
      for e in local.k8s_values_config.config.extraEnv : e.name
    ]))
    error_message = "config.extraEnv renders a duplicate name, which fails every later helm upgrade."
  }
}

# F-047/F-048: a trailing slash passed the old alltrue() list, because
# strcontains("//") cannot see the empty segment a trailing slash creates on
# its own, and handed n8n a double-slash storage path.
run "binary_data_path_rejects_a_trailing_slash" {
  command = plan

  variables {
    n8n_binary_data_mode = "filesystem"
    n8n_binary_data_path = "/opt/x/"
  }

  expect_failures = [var.n8n_binary_data_path]
}

run "the_s3_block_stays_off_so_the_chart_never_renders_those_names" {
  command = plan

  assert {
    condition     = local.k8s_values_s3_off.s3.enabled == false
    error_message = "s3.enabled must stay false: it is what keeps the chart's n8n.s3Env helper from rendering N8N_DEFAULT_BINARY_DATA_MODE, which a caller may now set."
  }
}

# ── Twelve inputs that reached nothing ────────────────────────────────────────
# Every input below was declared, documented, validated by a check block, and
# then never rendered into the chart values, so setting it passed validation and
# changed nothing in the cluster. tflint's terraform_unused_declarations cannot
# see this class of defect: a check-block reference counts as a use, so an input
# consulted only by an assertion looks used while doing nothing.
#
# These runs are the guard. They assert the wiring, not the validation, because
# the validation was already correct while the wiring was absent.

run "a_custom_image_repository_reaches_the_chart" {
  command = plan

  variables {
    n8n_image_repository      = "ghcr.io/example/n8n-with-nodes"
    n8n_image_tag             = "2.35.0-custom"
    n8n_task_runners_enabled  = true
    n8n_task_runner_image_tag = "2.35.0"
  }

  assert {
    condition     = local.k8s_values_image.image.repository == "ghcr.io/example/n8n-with-nodes"
    error_message = "n8n_image_repository must render image.repository, or a caller's custom image is accepted and then ignored while the pods run the chart default."
  }

  assert {
    condition     = local.k8s_values_image.image.tag == "2.35.0-custom"
    error_message = "n8n_image_tag must render image.tag."
  }

  assert {
    condition     = local.k8s_values_task_runners.taskRunners.image.tag == "2.35.0"
    error_message = "n8n_task_runner_image_tag must render taskRunners.image.tag: on a custom application image the chart's fallback resolves a runner tag that n8nio/runners never published."
  }
}

run "image_keys_stay_unset_when_the_caller_names_nothing" {
  command = plan

  assert {
    condition     = !contains(keys(local.k8s_values_image.image), "repository")
    error_message = "image.repository must be omitted when n8n_image_repository is null, so the chart's own repository applies."
  }

  assert {
    condition     = !contains(keys(local.k8s_values_task_runners.taskRunners), "image")
    error_message = "taskRunners.image must be omitted when n8n_task_runner_image_tag is null, so the chart falls back to the application image tag."
  }
}

# ── Pod shutdown budget ───────────────────────────────────────────────────────
# n8n_termination_grace_period reached N8N_GRACEFUL_SHUTDOWN_TIMEOUT (through
# the chart's redis.worker.timeout) and nothing else. The pod's own
# terminationGracePeriodSeconds stayed on the chart's 60, so n8n was killed
# before the budget it had been handed ran out, and raising the input widened
# the gap instead of closing it.
run "the_pod_outlives_the_shutdown_budget_it_was_given" {
  command = plan

  # Kubernetes starts the grace period at deletion, runs preStop, and sends
  # SIGTERM only once preStop returns. The pod therefore needs the drain sleep
  # plus n8n's budget, not the budget alone.
  assert {
    condition = local.k8s_values_final.lifecycle.main.terminationGracePeriodSeconds == (
      var.n8n_termination_grace_period + var.n8n_prestop_sleep
    )
    error_message = "The main pod's terminationGracePeriodSeconds must cover the preStop sleep plus n8n's shutdown budget, or the kubelet sends SIGKILL while n8n still believes it has time to finish."
  }

  assert {
    condition = local.k8s_values_final.lifecycle.worker.terminationGracePeriodSeconds == (
      var.n8n_termination_grace_period + var.n8n_prestop_sleep
    )
    error_message = "Workers are the family this matters most for: a SIGKILL here kills an execution mid-run."
  }

  # N8N_GRACEFUL_SHUTDOWN_TIMEOUT comes from the chart's shared ConfigMap, so
  # it reaches webhook processors too despite living under a redis.worker key.
  # The grace period has to follow it there.
  assert {
    condition = local.k8s_values_final.lifecycle.webhookProcessor.terminationGracePeriodSeconds == (
      var.n8n_termination_grace_period + var.n8n_prestop_sleep
    )
    error_message = "Webhook processors read the same N8N_GRACEFUL_SHUTDOWN_TIMEOUT, so they need the same pod grace period."
  }

  # The other half of the pair, which was already correct and must stay so:
  # the value n8n itself is told.
  assert {
    condition     = local.k8s_values_final.redis.worker.timeout == var.n8n_termination_grace_period
    error_message = "redis.worker.timeout must keep carrying n8n_termination_grace_period into N8N_GRACEFUL_SHUTDOWN_TIMEOUT; setting it a second way in config.extraEnv would render a duplicate env name and wedge the next helm upgrade."
  }
}

# The drain delay is a pod lifecycle hook, not application configuration. It
# was rendered as an N8N_PRESTOP_SLEEP environment variable that no chart
# template references and n8n does not declare, so raising the input changed
# nothing and the real window stayed on the chart's hardcoded `sleep 10`.
run "the_prestop_sleep_reaches_the_lifecycle_hook" {
  command = plan

  variables {
    n8n_prestop_sleep = 25
  }

  assert {
    condition     = local.k8s_values_final.lifecycle.main.preStop.command == ["/bin/sh", "-c", "sleep 25"]
    error_message = "n8n_prestop_sleep must render the preStop command, or the drain window stays on the chart's hardcoded sleep 10 whatever the caller sets."
  }

  assert {
    condition     = local.k8s_values_final.lifecycle.worker.preStop.command == ["/bin/sh", "-c", "sleep 25"]
    error_message = "Workers need the same drain delay: they hold the queue connection the main hands work to."
  }

  assert {
    condition     = local.k8s_values_final.lifecycle.webhookProcessor.preStop.command == ["/bin/sh", "-c", "sleep 25"]
    error_message = "Webhook processors take inbound production traffic, so they are the family where a missed endpoint removal is most visible."
  }

  assert {
    condition     = local.k8s_values_final.lifecycle.main.preStop.enabled == true
    error_message = "The preStop hook must stay enabled; the command is ignored when the chart's enabled flag is false."
  }
}

# The name is gone, not merely unused. An env var nobody reads is worse than
# absent: it reads as configuration, and the next person to debug a drain
# problem finds it set to the value they asked for and looks elsewhere.
run "the_dead_prestop_env_var_is_not_rendered" {
  command = plan

  assert {
    condition = !contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name],
      "N8N_PRESTOP_SLEEP",
    )
    error_message = "N8N_PRESTOP_SLEEP must not be rendered: chart 1.10.0 references it in no template and n8n declares no such variable, so it is configuration-shaped noise in every container's environment."
  }
}

# Raising the input has to move the pod's period with it. This is the case that
# failed before: asking for a long drain bought a longer n8n budget inside an
# unchanged 60 second pod lifetime.
run "a_longer_drain_moves_the_pod_grace_period_too" {
  command = plan

  variables {
    n8n_termination_grace_period = 300
    n8n_prestop_sleep            = 15
  }

  assert {
    condition     = local.k8s_values_final.lifecycle.worker.terminationGracePeriodSeconds == 315
    error_message = "A 300 second shutdown budget behind a 15 second drain needs a 315 second pod grace period; anything less kills executions the operator explicitly budgeted for."
  }

  assert {
    condition     = local.k8s_values_final.redis.worker.timeout == 300
    error_message = "n8n's own budget must still be the raw input, not the sum: it starts counting after preStop, not before."
  }
}

# Both inputs are added together to size an integer PodSpec field, so a
# fraction in either one renders a grace period Kubernetes will not take. The
# plan is the only place that can say so: `sleep 10.5` is a perfectly good
# hook, the helm release renders without complaint, and it is the API server
# that rejects the Deployment on apply.
run "a_fractional_drain_is_rejected_before_the_api_server_sees_it" {
  command = plan

  variables {
    n8n_prestop_sleep = 10.5
  }

  expect_failures = [var.n8n_prestop_sleep]
}

run "a_fractional_shutdown_budget_is_rejected_too" {
  command = plan

  variables {
    n8n_termination_grace_period = 90.5
  }

  expect_failures = [var.n8n_termination_grace_period]
}


# ── ServiceAccount ownership ──────────────────────────────────────────────────
# The chart renders imagePullSecrets nowhere, on the pod spec or on the
# ServiceAccount, so attaching them to the account the pods already run as is
# the only lever a private registry has. That means the module takes the
# account over, but only when there is something to attach.
#
# Both keys below were hardcoded (create = true, name = "n8n") while the locals
# and the ServiceAccount resource decided otherwise, so the whole input was a
# no-op: an account was created that no pod ever ran as. No assertion covered
# the serviceAccount values, which is exactly how it survived.
run "the_chart_keeps_its_service_account_by_default" {
  command = plan

  assert {
    condition     = local.k8s_values_final.serviceAccount.create == true
    error_message = "With no image pull secrets the chart must go on creating its own ServiceAccount, or an existing deployment's account changes owner for no reason."
  }

  assert {
    condition     = local.k8s_values_final.serviceAccount.name == "n8n"
    error_message = "The default account name must stay \"n8n\", the name the chart has always used, so nothing moves for a deployment that does not use image pull secrets."
  }
}

run "image_pull_secrets_hand_the_service_account_to_the_module" {
  command = plan

  variables {
    n8n_image_pull_secrets = ["registry-creds"]
    n8n_image_repository   = "registry.internal.example.com/n8n"
  }

  assert {
    condition     = local.k8s_values_final.serviceAccount.create == false
    error_message = "With image pull secrets set the chart must stop creating the account, or Helm and Terraform both own one and the apply fails on a name that already exists."
  }

  # The two owners use different names on purpose: the module's account is
  # created alongside the chart's on the apply that first enables this, rather
  # than colliding with it.
  assert {
    condition     = local.k8s_values_final.serviceAccount.name == "n8n-pull"
    error_message = "The chart must be pointed at the module's own account name. Pointing it at the chart's name collides with the account Helm still owns on the enabling apply."
  }

  assert {
    condition     = local.k8s_values_final.serviceAccount.name == local.n8n_service_account_name
    error_message = "The chart's serviceAccount.name and the ServiceAccount resource in n8n.tf must read the same local, or the pods run as an account that carries no pull secrets."
  }

  assert {
    condition     = one(kubernetes_service_account_v1.n8n[*].metadata[0].name) == "n8n-pull"
    error_message = "The module must create the account it points the chart at."
  }
}

# ── The single main pod's rollout strategy ────────────────────────────────────
# The chart ships `strategy: {}` behind a `with`, so it renders nothing and the
# Deployment takes Kubernetes' default: RollingUpdate at maxSurge 25%, which
# rounds up to one on a one-replica Deployment. That runs two n8n mains for the
# length of every rollout, and Community edition has no leader election to
# arbitrate them.
run "the_main_rolls_without_overlap_by_default" {
  command = plan

  assert {
    condition     = local.k8s_values_final.strategy.type == "Recreate"
    error_message = "The main Deployment must default to Recreate. Left unset, the chart renders no strategy and Kubernetes surges a second main on every rollout, which duplicates schedule triggers with nothing logging that it happened."
  }

  assert {
    condition     = !contains(keys(local.k8s_values_final.strategy), "rollingUpdate")
    error_message = "Recreate must not carry a rollingUpdate block; the API server rejects the combination."
  }
}

# The alternative has to be zero-overlap too. RollingUpdate without an explicit
# maxSurge = 0 is the surging default under another name, so rendering the type
# alone would reintroduce exactly the bug this input exists to remove.
run "rolling_update_is_rendered_with_no_surge" {
  command = plan

  variables {
    n8n_main_strategy = "RollingUpdate"
  }

  assert {
    condition     = local.k8s_values_final.strategy.type == "RollingUpdate"
    error_message = "n8n_main_strategy = RollingUpdate must reach the chart."
  }

  assert {
    condition     = local.k8s_values_final.strategy.rollingUpdate.maxSurge == 0
    error_message = "RollingUpdate must render maxSurge = 0. Without it Kubernetes defaults to 25%, which is one extra pod on a one-replica Deployment, which is two mains."
  }

  assert {
    condition     = local.k8s_values_final.strategy.rollingUpdate.maxUnavailable == 1
    error_message = "RollingUpdate with maxSurge = 0 needs maxUnavailable >= 1, or the Deployment can never make progress: it may neither add a pod nor remove one."
  }

  # maxSurge = 0 bounds the pod count, not the overlap: the outgoing pod stops
  # counting once its ReplicaSet is scaled to zero, and goes on serving through
  # its preStop hook and shutdown budget while the incoming pod starts. The
  # plan has to say so, or the strategy reads as equivalent to Recreate.
  expect_failures = [check.rolling_update_still_overlaps_two_mains]
}

# The typed input is not the only way to select a strategy. n8n_extra_helm_values
# is merged after the module's values and Helm gives the later file precedence,
# so an overlay setting strategy.type must reach the same warning.
run "an_extra_values_overlay_cannot_select_rolling_update_silently" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      strategy:
        type: RollingUpdate
    YAML
  }

  assert {
    condition     = local.n8n_main_strategy_effective == "RollingUpdate"
    error_message = "An overlay setting strategy.type must decide the effective strategy, since Helm lets it win over the module's own values."
  }

  expect_failures = [check.rolling_update_still_overlaps_two_mains]
}

# In Helm an explicit null deletes rather than defaults. `strategy: null` in the
# overlay removes the module's Recreate from the merged values, and the
# Deployment falls back to Kubernetes' own RollingUpdate at maxSurge 25% --
# strictly worse than selecting RollingUpdate here, which at least pins the
# surge to 0. A coalesce over the value alone reads this as "not set" and stays
# quiet on the most dangerous configuration of the three.
run "an_overlay_deleting_the_strategy_still_warns" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      strategy: null
    YAML
  }

  assert {
    condition     = local.n8n_main_strategy_left_to_kubernetes
    error_message = "An overlay setting strategy: null deletes the module's value in Helm, which must be recognised as handing the strategy to Kubernetes rather than as leaving the input in force."
  }

  expect_failures = [check.rolling_update_still_overlaps_two_mains]
}

# Emptying just the type is the same deletion one level down.
run "an_overlay_nulling_the_strategy_type_still_warns" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      strategy:
        type: null
    YAML
  }

  assert {
    condition     = local.n8n_main_strategy_left_to_kubernetes
    error_message = "An overlay setting strategy.type: null empties the field, which must be recognised as handing the strategy to Kubernetes."
  }

  expect_failures = [check.rolling_update_still_overlaps_two_mains]
}

# The two deletions are not interchangeable. Nulling the whole key removes the
# rollingUpdate settings with it, so Kubernetes has nothing left to read and
# applies its own maxSurge of 25%. Nulling only the type leaves the siblings in
# the merged values, so the surge is whatever those siblings ask for. The check
# fires either way, but it must not tell the reader 25% when the overlay has
# named a different number.
run "nulling_the_strategy_type_is_distinguished_from_nulling_the_key" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      strategy:
        type: null
        rollingUpdate:
          maxSurge: 2
    YAML
  }

  assert {
    condition     = local.n8n_extra_deletes_strategy_type && !local.n8n_extra_deletes_strategy
    error_message = "Nulling strategy.type deletes only the type; the whole-key deletion must stay false so the diagnostic does not claim rollingUpdate was removed too."
  }

  assert {
    condition     = local.n8n_main_strategy_left_to_kubernetes
    error_message = "Either deletion still hands the strategy type to Kubernetes, so the check must fire for both."
  }

  expect_failures = [check.rolling_update_still_overlaps_two_mains]
}

# A strategy mapping that carries no type key is a merge rather than a
# deletion: Helm keeps the module's own type and only adds whatever else the
# overlay brought. Reading that as a deletion warns about a Deployment that is
# still on Recreate, and a warning that fires on a safe configuration is the
# fastest way to teach people to ignore it.
run "an_overlay_declaring_strategy_without_a_type_keeps_the_module_value" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      strategy: {}
    YAML
  }

  assert {
    condition     = local.n8n_main_strategy_effective == "Recreate"
    error_message = "An empty strategy mapping merges over nothing, so the module's own type must survive it."
  }

  assert {
    condition     = !local.n8n_main_strategy_left_to_kubernetes
    error_message = "An empty mapping is not an explicit null, so it must not be read as deleting the module's strategy."
  }
}

# Same merge one level down, with a sibling key present to show the mapping is
# genuinely non-empty and still leaves the type alone.
run "an_overlay_setting_only_rolling_update_fields_keeps_the_module_type" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      strategy:
        rollingUpdate:
          maxUnavailable: 1
    YAML
  }

  assert {
    condition     = local.n8n_main_strategy_effective == "Recreate"
    error_message = "A strategy mapping that never mentions type must leave the module's type in force."
  }

  assert {
    condition     = !local.n8n_main_strategy_left_to_kubernetes
    error_message = "A missing type key is an absence, not a deletion, so nothing is handed to Kubernetes here."
  }
}

# An overlay that says nothing about the strategy must leave the input in force.
run "an_unrelated_overlay_leaves_the_strategy_alone" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      podLabels:
        team: platform
    YAML
  }

  assert {
    condition     = local.n8n_main_strategy_effective == "Recreate"
    error_message = "An overlay that never mentions strategy must leave n8n_main_strategy deciding."
  }

  assert {
    condition     = !local.n8n_main_strategy_left_to_kubernetes
    error_message = "An absent strategy key is not a deletion; only an explicit null is."
  }
}

# The default must not trip that warning, or it fires on every deployment and
# becomes noise.
run "the_default_strategy_warns_about_nothing" {
  command = plan

  assert {
    condition     = local.k8s_values_final.strategy.type == "Recreate"
    error_message = "The main Deployment must default to Recreate, the only strategy that waits for the old main to be gone."
  }

  assert {
    condition     = !contains(keys(local.k8s_values_final.strategy), "rollingUpdate")
    error_message = "Recreate must not carry a rollingUpdate block; the Deployment API rejects it."
  }
}

run "the_main_strategy_rejects_a_surging_value" {
  command = plan

  variables {
    n8n_main_strategy = "OnDelete"
  }

  expect_failures = [var.n8n_main_strategy]
}

# ── The single main pod's disruption budget ───────────────────────────────────
# Through chart 1.10.0, the chart defaulted pdb.enabled to true at
# minAvailable = 1 and rendered it over the main Deployment, which this
# module pins to one replica: allowedDisruptions = 0 for the life of the
# deployment, so the node holding the main pod could never be drained and a
# Talos node upgrade stalled behind it. Chart 1.16.0 closed that structurally
# (n8n-io/n8n-hosting#228): templates/pdb.yaml now renders only when main runs
# more than one replica, which this module never does, so the object no
# longer renders at all regardless of this input; see the comment above
# local.k8s_values_pdb in locals.tf, and tests/scripts/check-n8n-chart.sh,
# which renders the real chart to prove
# it. The assertions below are on the values tree the module hands to Helm,
# which is as far as a mocked plan can see either way.
run "the_main_pdb_is_off_by_default" {
  command = plan

  assert {
    condition     = local.k8s_values_pdb.pdb.enabled == false
    error_message = "pdb.enabled must render false by default. Before chart 1.16.0 the chart's own default was true at minAvailable = 1, which against replicaCount = 1 blocked every voluntary eviction and wedged node drains; chart 1.16.0 stopped rendering the object at all for a single main, but the module still states its own default explicitly rather than leaning on the chart's."
  }

  assert {
    condition     = local.k8s_values_final.pdb.enabled == false
    error_message = "pdb must reach the final values tree. A fragment that is assembled and never merged is the defect class this suite exists to catch."
  }

  # The main pod is the only one the chart puts a PDB over, so this input has
  # to leave the worker and webhook tiers alone.
  assert {
    condition     = local.k8s_values_final.replicaCount == 1
    error_message = "The main Deployment must stay at one replica, which is what makes the chart's PDB gate (main replicas > 1) permanently unsatisfied and this input's default moot either way."
  }
}

run "the_main_pdb_can_be_turned_back_on" {
  command = plan

  variables {
    n8n_main_pdb_enabled = true
  }

  assert {
    condition     = local.k8s_values_final.pdb.enabled == true
    error_message = "n8n_main_pdb_enabled = true must reach the chart, or the escape hatch is accepted and discarded."
  }

  # Reaching the chart's values tree is as far as a mocked plan can prove.
  # Whether the chart then actually renders a PodDisruptionBudget for this
  # module's single-replica main (it does not, as of chart 1.16.0) is a Helm
  # template question a plan-time check cannot ask; tests/scripts/check-n8n-chart.sh
  # renders the real chart with this exact scenario to prove that half.
}

# The typed input is not the only way in. n8n_extra_helm_values is merged after
# the module's own values and Helm gives the later file precedence, so the
# overlay can render the same object.
run "the_extra_values_overlay_can_also_ask_for_the_pdb" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      pdb:
        enabled: true
        minAvailable: 1
    YAML
  }

  assert {
    condition     = try(yamldecode(var.n8n_extra_helm_values).pdb.enabled, false) == true
    error_message = "The overlay setting pdb.enabled = true must be visible at plan time."
  }
}

# The detection must not fire on overlays that say nothing about the PDB.
run "an_unrelated_extra_values_overlay_leaves_the_pdb_detection_quiet" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      podLabels:
        team: platform
    YAML
  }

  assert {
    condition     = try(yamldecode(var.n8n_extra_helm_values).pdb.enabled, false) != true
    error_message = "An overlay that never mentions pdb must not read as enabling it."
  }
}

# The tag is the one image key the module does NOT leave to the chart. Before
# chart 1.12.0, the chart's default was the floating `stable`, resolved per
# node at pull time under IfNotPresent; from 1.12.0 on, an empty tag resolves
# to the pinned chart's own appVersion instead, which is a fixed version but
# still not one this module's CHANGELOG controls. Either way, leaving this
# unset lets a chart bump (or, pre-1.12.0, a rescheduled pod) move the running
# n8n version with no plan, no apply and no operator in the loop.
run "the_image_tag_is_pinned_by_default" {
  command = plan

  # A bare version, for two reasons at once: handing the choice to the chart
  # resolves to its appVersion (or `stable` pre-1.12.0) rather than a version
  # this module's CHANGELOG tracks; and whenever n8n_task_runner_image_tag is
  # null (its default) the chart derives the runner sidecar's tag from this
  # one, so a tag n8nio/runners never published fails the pull on every
  # worker pod.
  assert {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.n8n_image_tag))
    error_message = "n8n_image_tag must default to a concrete, bare n8n version: null lets the chart's own default (its appVersion, or `stable` pre-1.12.0) apply instead, and a non-version tag makes the derived n8nio/runners sidecar tag unpullable."
  }

  assert {
    condition     = local.k8s_values_image.image.tag == var.n8n_image_tag
    error_message = "image.tag must carry n8n_image_tag into the chart, or the pinned default is accepted and then discarded while the pods run the chart's own default instead."
  }
}

# Handing the tag back to the chart stays supported, and has to keep rendering
# no tag key at all rather than an empty string.
run "a_null_image_tag_hands_the_choice_back_to_the_chart" {
  command = plan

  variables {
    n8n_image_tag = null
  }

  assert {
    condition     = !contains(keys(local.k8s_values_image.image), "tag")
    error_message = "image.tag must be omitted when n8n_image_tag is null, so the chart's own default applies rather than an empty tag reaching the pod spec."
  }
}

# A mirror of the stock image is a custom repository with the module's own
# pinned tag, and the runner fallback resolves correctly for it. The check
# block must stay silent there: a warning that fires on the module's own
# default configuration is one operators learn to ignore.
run "a_mirrored_repository_on_the_default_tag_needs_no_runner_tag" {
  command = plan

  variables {
    n8n_image_repository     = "registry.internal.example.com/n8nio/n8n"
    n8n_task_runners_enabled = true
  }

  assert {
    condition     = local.k8s_values_image.image.repository == "registry.internal.example.com/n8nio/n8n"
    error_message = "A mirrored repository must reach the chart alongside the module's pinned tag."
  }

  assert {
    condition     = !contains(keys(local.k8s_values_task_runners.taskRunners), "image")
    error_message = "taskRunners.image must stay unset on a mirror using the module's pinned version tag; the chart's fallback to the application tag is correct there."
  }
}

run "custom_node_loading_reaches_the_pods" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes"
    n8n_image_repository       = "ghcr.io/example/n8n-with-nodes"
    n8n_image_tag              = "2.35.0-custom"
    n8n_task_runner_image_tag  = "2.35.0"
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name],
      "N8N_CUSTOM_EXTENSIONS",
    )
    error_message = "n8n_custom_extensions_path must render N8N_CUSTOM_EXTENSIONS, or nodes baked into a custom image are never scanned."
  }
}

# The webhook sizing here is not incidental. The check block in scaling.tf
# refuses n8n_reinstall_missing_packages against the default webhook resources,
# because those are the ones that failed in practice when npm install runs
# inside the pod.
run "reinstalling_missing_packages_reaches_the_pods" {
  command = plan

  variables {
    n8n_reinstall_missing_packages = true
    n8n_webhook_cpu_request        = "800m"
    n8n_webhook_cpu_limit          = "1500m"
    n8n_webhook_memory_request     = "1Gi"
    n8n_webhook_memory_limit       = "2Gi"
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name],
      "N8N_REINSTALL_MISSING_PACKAGES",
    )
    error_message = "n8n_reinstall_missing_packages must render N8N_REINSTALL_MISSING_PACKAGES when true."
  }
}

# F-083: check.webhook_resources_sized_for_reinstall_missing_packages
# interpolates all four webhook quantities and branches on this toggle, and
# Terraform evaluates a check's error_message alongside its condition rather
# than lazily on failure. Before nullable = false, an explicit null on any of
# the five aborted the plan from inside a block whose whole purpose is to
# warn without failing. The run proving the plan simply succeeds at the
# defaults, "explicit_nulls_on_webhook_resources_fall_back_to_defaults", now
# lives in
# tests/opentofu-gaps/nullable-variable-null-override-gap.tftest.hcl:
# OpenTofu v1.13.2's test runner does not fall an explicit `variables` block
# null on a nullable = false input back to its default the way `tofu`'s own
# documented language behaviour and real Terraform both do (see that file's
# header).

run "opentelemetry_reaches_the_pods_only_when_enabled" {
  command = plan

  variables {
    n8n_otel_enabled                   = true
    n8n_otel_exporter_otlp_endpoint    = "http://otel-collector:4318"
    n8n_otel_exporter_service_name     = "n8n"
    n8n_otel_traces_sample_rate        = 0.25
    n8n_otel_traces_include_node_spans = false
  }

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv : e.name if startswith(e.name, "N8N_OTEL")
    ]) == 5
    error_message = "Every non-null OpenTelemetry input must render its env var: the whole family was declared and validated while reaching nothing."
  }
}

# No variables here on purpose. The check block in n8n.tf already refuses any
# OTEL tuning input while the master switch is off, so the only reachable
# "disabled" state is the default one, and that is what this asserts.
run "opentelemetry_renders_nothing_when_off" {
  command = plan

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv : e.name if startswith(e.name, "N8N_OTEL")
    ]) == 0
    error_message = "No OpenTelemetry env var may render while n8n_otel_enabled is false: the SDK would be configured but never loaded."
  }
}

# ── Sidecars ──────────────────────────────────────────────────────────────────

run "a_sidecar_reaches_the_chart_in_kubernetes_spelling" {
  command = plan

  variables {
    n8n_extra_containers = [{
      name          = "log-shipper"
      image         = "ghcr.io/example/shipper:1.0.0"
      args          = ["--target", "loki:3100"]
      ports         = [{ name = "metrics", container_port = 9100 }]
      volume_mounts = [{ name = "logs", mount_path = "/var/log/n8n" }]
      resources     = { cpu_request = "50m", memory_limit = "128Mi" }
    }]
  }

  assert {
    condition     = local.k8s_values_containers.extraContainers[0].name == "log-shipper"
    error_message = "n8n_extra_containers must render extraContainers."
  }

  assert {
    condition     = local.k8s_values_containers.extraContainers[0].ports[0].containerPort == 9100
    error_message = "container_port must be translated to containerPort: the chart passes values through to the pod spec unchanged, so a snake_case key would be dropped by the API server."
  }

  assert {
    condition     = local.k8s_values_containers.extraContainers[0].volumeMounts[0].mountPath == "/var/log/n8n"
    error_message = "mount_path must be translated to mountPath."
  }

  # Only the two corners the caller set. A null request is rejected by the API
  # server, where an absent one inherits the namespace default, so the empty
  # halves have to be omitted rather than rendered.
  assert {
    condition = (
      length(local.k8s_values_containers.extraContainers[0].resources.requests) == 1 &&
      local.k8s_values_containers.extraContainers[0].resources.requests["cpu"] == "50m" &&
      length(local.k8s_values_containers.extraContainers[0].resources.limits) == 1 &&
      local.k8s_values_containers.extraContainers[0].resources.limits["memory"] == "128Mi"
    )
    error_message = "Sidecar resources must render only the corners the caller set."
  }
}

run "an_init_container_reaches_the_chart" {
  command = plan

  variables {
    n8n_extra_init_containers = [{
      name    = "fetch-ca"
      image   = "curlimages/curl:8.9.0"
      command = ["sh", "-c", "true"]
    }]
  }

  assert {
    condition     = local.k8s_values_containers.extraInitContainers[0].name == "fetch-ca"
    error_message = "n8n_extra_init_containers must render extraInitContainers."
  }
}

run "the_container_keys_stay_absent_by_default" {
  command = plan

  assert {
    condition     = length(keys(local.k8s_values_containers)) == 0
    error_message = "extraContainers and extraInitContainers must be omitted entirely when no sidecar is declared, so the chart's own defaults apply and `helm get values` stays readable."
  }
}

# ── PgBouncer pooler ──────────────────────────────────────────────────────────

run "the_pooler_is_off_by_default" {
  command = plan

  # A pooler is a second thing to run. A deployment whose worker tier never
  # leaves single digits does not need one, and defaulting it on would create
  # two PgBouncer pods for every caller who never reads this input.
  assert {
    condition     = var.cnpg_pooler_enabled == false
    error_message = "cnpg_pooler_enabled must default to false."
  }

  assert {
    condition     = length(kubectl_manifest.cnpg_pooler) == 0
    error_message = "No Pooler should be planned while cnpg_pooler_enabled is false."
  }
}

run "postgres_host_is_the_cluster_when_no_pooler" {
  command = plan

  assert {
    condition     = can(regex("-pg-rw", local.k8s_pg_host))
    error_message = "Without a pooler, n8n must connect to the CNPG rw Service; got: ${local.k8s_pg_host}"
  }
}

run "enabling_the_pooler_plans_one_and_moves_the_host" {
  command = plan

  variables {
    cnpg_pooler_enabled       = true
    db_postgresdb_ssl_enabled = false
  }

  assert {
    condition     = length(kubectl_manifest.cnpg_pooler) == 1
    error_message = "Expected exactly one Pooler when cnpg_pooler_enabled = true."
  }

  # The host moving is the whole contract. Everything downstream (the helm
  # values tree, the backing_services output, the smoke test) reads
  # local.k8s_pg_host, so this one assertion covers all of them.
  # Asserted against the Service name rather than local.cnpg_pooler_host, which
  # is what k8s_pg_host is defined as on this branch: comparing them confirms
  # the branch was taken and nothing about the host it produces.
  assert {
    condition     = startswith(local.k8s_pg_host, "n8n-pg-pooler-rw.")
    error_message = "n8n must connect to the Pooler Service when one is enabled; got: ${local.k8s_pg_host}"
  }
}

run "the_pooler_needs_the_cnpg_backend" {
  command = plan

  variables {
    cnpg_pooler_enabled       = true
    db_postgresdb_ssl_enabled = false
    postgres_backend          = "external"
    db_host                   = "postgres.example.com"
    db_password               = "s3cret-not-real"
  }

  # A Pooler attaches to a CNPG Cluster. On the external path there is none, so
  # the input would silently do nothing rather than fail, and the caller would
  # be left believing they had pooling.
  expect_failures = [var.cnpg_pooler_enabled]
}

run "the_pooler_refuses_to_run_with_tls_on" {
  command = plan

  variables {
    cnpg_pooler_enabled       = true
    db_postgresdb_ssl_enabled = true
  }

  # PgBouncer serves clients in plaintext and encrypts its own leg upstream.
  # Left true, n8n negotiates TLS against a listener that does not speak it and
  # the error names a connection failure with nothing pointing at the pooler.
  # Cheaper to refuse at plan time.
  expect_failures = [var.cnpg_pooler_enabled]
}

run "pooler_sizing_inputs_reject_nonsense" {
  command = plan

  variables {
    cnpg_pooler_enabled       = true
    db_postgresdb_ssl_enabled = false
    cnpg_pooler_instances     = 0
  }

  # Zero instances is a Pooler that exists in the API and answers nothing,
  # while n8n's DB host now points at its Service.
  expect_failures = [var.cnpg_pooler_instances]
}

run "the_pool_mode_is_constrained" {
  command = plan

  variables {
    cnpg_pooler_enabled       = true
    db_postgresdb_ssl_enabled = false
    cnpg_pooler_mode          = "transactional"
  }

  # PgBouncer takes transaction, session or statement. A near-miss like this
  # one is rejected by PgBouncer at startup, several minutes and one CrashLoop
  # after apply.
  expect_failures = [var.cnpg_pooler_mode]
}

run "transaction_mode_is_the_default_because_session_solves_nothing" {
  command = plan

  # Session mode holds a server connection for the life of the client session.
  # n8n's TypeORM pool is long-lived, so session mode reproduces the original
  # connection count exactly and the pooler buys nothing.
  assert {
    condition     = var.cnpg_pooler_mode == "transaction"
    error_message = "cnpg_pooler_mode must default to \"transaction\"; session mode does not decouple client count from server connections."
  }
}

# PgBouncer's "statement" mode forbids multi-statement transactions. n8n runs
# its TypeORM migrations inside one at every boot, so the mode is not a
# trade-off here, it is a release that cannot start. Refused at plan time
# rather than discovered in a migration crash loop.
run "cnpg_pooler_mode_rejects_statement" {
  command = plan

  variables {
    cnpg_pooler_mode = "statement"
  }

  expect_failures = [var.cnpg_pooler_mode]
}

# The pooler's whole job is to make pod count stop driving the connection
# budget, which it does by making pool_size x instances the entirety of what
# Postgres sees. Sizing that product past the Cluster's own max_connections
# recreates the exhaustion one hop upstream, where it reads as a PgBouncer
# problem rather than a Postgres one.
run "cnpg_pooler_pool_budget_rejects_oversubscription" {
  command = plan

  variables {
    postgres_backend          = "cnpg"
    cnpg_pooler_enabled       = true
    db_postgresdb_ssl_enabled = false
    cnpg_pooler_instances     = 4
    cnpg_pooler_pool_size     = 50
  }

  expect_failures = [var.cnpg_pooler_pool_size]
}

# The same product at the default instance count is inside the budget, so the
# validation has to let it through: a guard that rejects the documented default
# is worse than no guard.
run "cnpg_pooler_pool_budget_allows_the_defaults" {
  command = plan

  variables {
    postgres_backend          = "cnpg"
    cnpg_pooler_enabled       = true
    db_postgresdb_ssl_enabled = false
  }

  assert {
    condition     = var.cnpg_pooler_pool_size * var.cnpg_pooler_instances == 50
    error_message = "The documented default is 25 x 2 = 50 real connections; got ${var.cnpg_pooler_pool_size * var.cnpg_pooler_instances}."
  }
}

# The pooler budget is derived from cnpg_max_connections rather than from a
# literal copied out of postgres_cnpg.tf, so the two cannot drift and a caller
# who needs a larger pool has a way to get one. Same product the run above
# rejects at the default limit, accepted once the limit moves.
run "cnpg_pooler_pool_budget_follows_max_connections" {
  command = plan

  variables {
    postgres_backend          = "cnpg"
    cnpg_pooler_enabled       = true
    db_postgresdb_ssl_enabled = false
    cnpg_max_connections      = 400
    cnpg_pooler_instances     = 4
    cnpg_pooler_pool_size     = 50
  }

  assert {
    condition     = var.cnpg_pooler_pool_size * var.cnpg_pooler_instances <= floor(var.cnpg_max_connections * 0.75)
    error_message = "200 real connections must fit inside three quarters of a 400 limit."
  }
}

# And the limit the validation is measured against is the one the Cluster
# actually runs. Without this the input could be validated against a number the
# manifest never receives, which is the drift the derivation exists to prevent,
# reintroduced one layer down.
run "cnpg_cluster_renders_the_configured_max_connections" {
  command = plan

  variables {
    postgres_backend     = "cnpg"
    cnpg_max_connections = 321
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.postgresql.parameters.max_connections == "321"
    error_message = "The CNPG Cluster must run the cnpg_max_connections it was given; got ${yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.postgresql.parameters.max_connections}."
  }
}

# Postgres will not start with max_connections above its own ceiling, and the
# value goes straight into the Cluster spec, so without this the plan succeeds
# and the database is what refuses.
run "cnpg_max_connections_rejects_a_value_postgres_cannot_take" {
  command = plan

  variables {
    cnpg_max_connections = 262144
  }

  expect_failures = [var.cnpg_max_connections]
}

# ── Postgres connection budget advisory ───────────────────────────────────────
# postgres_connection_budget_check_enabled defaults false. Set oversized
# ceilings (10 x (1 + 50 + 8) = 590, far past cnpg_max_connections' default of
# 200) and prove the plan still succeeds with the toggle untouched: the check
# must be silent by default, not merely coincidentally fitting.
run "postgres_connection_budget_check_stays_silent_by_default" {
  command = plan

  variables {
    n8n_worker_keda_max_replicas = 50
  }
}

# Enabled, the same oversized ceiling against the cnpg path's known value
# (cnpg_max_connections, default 200) must warn: 10 x (1 + 20 + 8) = 290 > 200.
run "postgres_connection_budget_check_warns_when_ceilings_exceed_cnpg_max_connections" {
  command = plan

  variables {
    postgres_connection_budget_check_enabled = true
    n8n_worker_keda_max_replicas             = 20
  }

  expect_failures = [check.postgres_pool_size_fits_known_max_connections]
}

# Enabled with ceilings that fit (10 x (1 + 5 + 8) = 140 <= 200) must draw no
# warning.
run "postgres_connection_budget_check_passes_when_ceilings_fit" {
  command = plan

  variables {
    postgres_connection_budget_check_enabled = true
    n8n_worker_keda_max_replicas             = 5
  }
}

# Exact boundary: db_postgresdb_pool_size x (1 + worker + webhook) landing
# exactly on cnpg_max_connections' default of 200 (1 x (1 + 100 + 99) = 200)
# must not fire. The comparison is <=, so "fits" includes the limit itself.
run "postgres_connection_budget_check_stays_silent_exactly_at_the_limit" {
  command = plan

  variables {
    postgres_connection_budget_check_enabled = true
    db_postgresdb_pool_size                  = 1
    n8n_worker_keda_max_replicas             = 100
    n8n_webhook_hpa_max_replicas             = 99
  }
}

# One connection past the same limit (1 x (1 + 100 + 100) = 201) must fire.
# Paired with the previous run, this pins the inclusive boundary in both
# directions so an off-by-one in the comparison operator cannot pass silently.
run "postgres_connection_budget_check_warns_one_over_the_limit" {
  command = plan

  variables {
    postgres_connection_budget_check_enabled = true
    db_postgresdb_pool_size                  = 1
    n8n_worker_keda_max_replicas             = 100
    n8n_webhook_hpa_max_replicas             = 100
  }

  expect_failures = [check.postgres_pool_size_fits_known_max_connections]
}

# On the external path the module manages nothing on the server, so the known
# value falls back to PostgreSQL's own stock default of 100. The module's own
# default ceilings (10 x (1 + 10 + 8) = 190) already exceed that, which is
# exactly why the toggle defaults false.
run "postgres_connection_budget_check_uses_the_stock_default_on_the_external_path" {
  command = plan

  variables {
    postgres_connection_budget_check_enabled = true
    postgres_backend                         = "external"
    db_host                                  = "postgres.internal.example.com"
    db_password                              = "not-a-real-password"
  }

  expect_failures = [check.postgres_pool_size_fits_known_max_connections]
}

# Behind the pooler, pod count stops being a term in the connection
# arithmetic (the Pooler sets the real connection count instead), so the
# model does not apply and the check must stay silent even against ceilings
# that would otherwise warn.
run "postgres_connection_budget_check_stays_silent_behind_the_pooler" {
  command = plan

  variables {
    postgres_connection_budget_check_enabled = true
    cnpg_pooler_enabled                      = true
    db_postgresdb_ssl_enabled                = false
    n8n_worker_keda_max_replicas             = 20
  }
}

# Upstream's supported tags name the image type and distribution, and the bare
# major it defaults to here is the deprecated spelling. Rejecting the supported
# form would leave the module on the tags that are going away.
run "cnpg_postgres_image_tag_accepts_a_qualified_upstream_tag" {
  command = plan

  variables {
    cnpg_postgres_image_tag = "16.10-minimal-trixie"
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.imageName == "ghcr.io/cloudnative-pg/postgresql:16.10-minimal-trixie"
    error_message = "The tag is interpolated into imageName verbatim, whatever shape it is."
  }
}

# A registry or a digest in this input produces an imageName that resolves to
# something other than what it reads as, which is a pull failure at run time
# rather than a plan error.
run "cnpg_postgres_image_tag_rejects_a_digest" {
  command = plan

  variables {
    cnpg_postgres_image_tag = "16.10@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  }

  expect_failures = [var.cnpg_postgres_image_tag]
}

# A dot is a separator between suffix segments here, never a segment of its
# own. Both spellings below are well-formed image references that a registry
# would accept the shape of and then fail to resolve, which surfaces as
# ImagePullBackOff on the Postgres pod rather than as anything at plan time.
# The validation is deliberately narrower than the reference grammar so that
# the typo stops here instead.
run "cnpg_postgres_image_tag_rejects_a_stray_dot" {
  command = plan

  variables {
    cnpg_postgres_image_tag = "16.10-."
  }

  expect_failures = [var.cnpg_postgres_image_tag]
}

run "cnpg_postgres_image_tag_rejects_a_doubled_dot" {
  command = plan

  variables {
    cnpg_postgres_image_tag = "16.10-minimal..trixie"
  }

  expect_failures = [var.cnpg_postgres_image_tag]
}

# 128 characters is the limit the reference grammar puts on a tag. A longer one
# is not a pull that fails but a reference that never parses: the pod reports
# InvalidImageName, no registry is contacted, and nothing points back here.
run "cnpg_postgres_image_tag_rejects_one_past_the_length_limit" {
  command = plan

  variables {
    cnpg_postgres_image_tag = "16.10-${join("", [for i in range(123) : "a"])}"
  }

  expect_failures = [var.cnpg_postgres_image_tag]
}

# The same tag one character shorter is accepted, so the guard is a boundary
# rather than a ceiling that also catches what it should let through.
run "cnpg_postgres_image_tag_accepts_the_longest_legal_tag" {
  command = plan

  variables {
    cnpg_postgres_image_tag = "16.10-${join("", [for i in range(122) : "a"])}"
  }

  assert {
    condition     = length(var.cnpg_postgres_image_tag) == 128
    error_message = "This run exists to pin the boundary at exactly 128 characters; if the string is not that long it is testing nothing."
  }
}

# ── Binary data mode ──────────────────────────────────────────────────────────

# The output used to be the string "filesystem" regardless of configuration,
# which was wrong on the default path: the module always runs queue mode, and
# n8n puts binary data in Postgres there unless told otherwise. See issue #18.
run "binary_storage_output_reports_database_by_default" {
  command = plan

  assert {
    condition     = output.backing_services.binary_storage == "database"
    error_message = "With no binary data configuration the module leaves n8n at its queue-mode default, which is database; got ${output.backing_services.binary_storage}."
  }
}

# Database mode renders nothing. Emitting N8N_DEFAULT_BINARY_DATA_MODE=database
# would only restate n8n's own default while claiming a name a caller may be
# setting through n8n_extra_env.
run "binary_data_database_mode_emits_no_env" {
  command = plan

  assert {
    condition     = length([for e in local.k8s_values_config.config.extraEnv : e if e.name == "N8N_DEFAULT_BINARY_DATA_MODE"]) == 0
    error_message = "Database mode must not render N8N_DEFAULT_BINARY_DATA_MODE."
  }
}

# Filesystem mode renders the mode and the path together. The path is the half
# people miss: without it n8n writes under its own default rather than the
# volume that was mounted, which loses data exactly as quietly as no mount.
run "binary_data_filesystem_mode_emits_mode_and_path" {
  command = plan

  variables {
    n8n_binary_data_mode = "filesystem"
    n8n_binary_data_path = "/opt/n8n-shared"

    n8n_extra_volumes = [{
      name                    = "shared"
      persistent_volume_claim = { claim_name = "n8n-shared" }
    }]

    n8n_extra_volume_mounts = [{
      name       = "shared"
      mount_path = "/opt/n8n-shared"
      read_only  = false
    }]
  }

  assert {
    condition     = contains([for e in local.k8s_values_config.config.extraEnv : e.value if e.name == "N8N_DEFAULT_BINARY_DATA_MODE"], "filesystem")
    error_message = "Filesystem mode must render N8N_DEFAULT_BINARY_DATA_MODE=filesystem."
  }

  assert {
    condition     = contains([for e in local.k8s_values_config.config.extraEnv : e.value if e.name == "N8N_STORAGE_PATH"], "/opt/n8n-shared/storage")
    error_message = "Filesystem mode must render N8N_STORAGE_PATH under n8n_binary_data_path."
  }

  assert {
    condition     = output.backing_services.binary_storage == "filesystem"
    error_message = "The output must follow the configured mode; got ${output.backing_services.binary_storage}."
  }
}

# The whole point of the guard. Filesystem mode with no shared mount gives each
# pod its own empty directory, and in queue mode the pod that writes a payload
# is rarely the pod that reads it back. Nothing errors at runtime, which is why
# this has to error at plan.
run "binary_data_filesystem_mode_requires_a_mount" {
  command = plan

  variables {
    n8n_binary_data_mode = "filesystem"
  }

  expect_failures = [var.n8n_binary_data_mode]
}

# A read-only mount is not a place to write payloads to, and the pods would
# fail at the first binary rather than at plan.
run "binary_data_filesystem_mode_rejects_a_read_only_mount" {
  command = plan

  variables {
    n8n_binary_data_mode = "filesystem"
    n8n_binary_data_path = "/opt/n8n-shared"

    n8n_extra_volumes = [{
      name                    = "shared"
      persistent_volume_claim = { claim_name = "n8n-shared" }
    }]

    n8n_extra_volume_mounts = [{
      name       = "shared"
      mount_path = "/opt/n8n-shared"
      read_only  = true
    }]
  }

  expect_failures = [var.n8n_binary_data_mode]
}

# The mode is reachable one way, and it is the checked one. Left open through
# n8n_extra_env, filesystem mode skipped the shared-mount validation, skipped
# N8N_STORAGE_PATH, and still reported "filesystem" while the pods wrote to
# per-pod local disk: the guard two runs up, bypassed by the other door.
run "binary_data_mode_is_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_DEFAULT_BINARY_DATA_MODE", value = "filesystem" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# Same for the path, and for the secret-backed input, which shares the reserved
# list. A mode supplied from a Secret is invisible at plan, so the output could
# not have followed it even if the guard did.
run "binary_data_path_is_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_STORAGE_PATH", value = "/opt/n8n-shared/storage" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "binary_data_mode_is_rejected_from_extra_env_from_secret" {
  command = plan

  variables {
    n8n_extra_env_from_secret = [{
      name        = "N8N_DEFAULT_BINARY_DATA_MODE"
      secret_name = "whatever"
      secret_key  = "mode"
    }]
  }

  expect_failures = [var.n8n_extra_env_from_secret]
}

# The third door onto the same setting. Helm coalesces maps but replaces lists,
# so an overlay that sets config.extraEnv substitutes the module's whole
# environment list, and backing_services.binary_storage would keep reporting
# what the module rendered while the pods ran something else entirely.
run "extra_helm_values_may_not_replace_the_env_list" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      config:
        extraEnv:
          - name: N8N_DEFAULT_BINARY_DATA_MODE
            value: filesystem
    YAML
  }

  expect_failures = [var.n8n_extra_helm_values]
}

# Everything else the overlay reaches is still the escape hatch it is meant to
# be. A guard that rejected the whole input would be a different feature.
#
# No assert, deliberately. The guard is a variable validation, so an overlay it
# over-reached on would fail the plan and fail this run: the run completing is
# the assertion, and anything written in an assert block here would be
# restating the inputs above rather than checking an outcome.
run "extra_helm_values_still_reaches_everything_else" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      config:
        encryptionKeySecret: my-own-secret
      podAnnotations:
        example.com/owner: platform
    YAML
  }
}


# ── n8n_extra_ca_pem ─────────────────────────────────────────────────────────
# Ported from the AWS sibling (n8n-io/terraform-aws-n8n#202). Emission is
# proven against local.k8s_values_volumes/config/pod_annotations here;
# tests/scripts/check-n8n-chart.sh proves the real chart accepts the shape on
# all three pod types and keeps it off the task-runner sidecar.

run "n8n_extra_ca_pem_is_null_by_default_and_emits_nothing" {
  command = plan

  assert {
    condition     = length(local.k8s_values_volumes.extraVolumes) == 0 && length(local.k8s_values_volumes.extraVolumeMounts) == 0
    error_message = "With n8n_extra_ca_pem unset, no ca-bundle volume or mount should be rendered."
  }

  assert {
    condition     = length(local.n8n_ca_bundle_env) == 0
    error_message = "With n8n_extra_ca_pem unset, NODE_EXTRA_CA_CERTS must not be rendered."
  }

  assert {
    condition     = length(local.k8s_values_pod_annotations) == 0
    error_message = "With n8n_extra_ca_pem unset and valkey_password_rotation_roll_enabled at its default (false), no podAnnotations should be rendered."
  }
}

run "n8n_extra_ca_pem_reaches_the_chart" {
  command = plan

  variables {
    n8n_extra_ca_pem = <<-PEM
      -----BEGIN CERTIFICATE-----
      MIIBtest1234567890aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      -----END CERTIFICATE-----
    PEM
  }

  assert {
    condition = contains(
      local.k8s_values_volumes.extraVolumes,
      {
        name = "ca-bundle"
        secret = {
          secretName = "n8n-ca-bundle-secret"
          items      = [{ key = "ca.crt", path = "ca.crt" }]
        }
      }
    )
    error_message = "n8n_extra_ca_pem must render the ca-bundle volume."
  }

  assert {
    condition = contains(
      local.k8s_values_volumes.extraVolumeMounts,
      {
        name      = "ca-bundle"
        mountPath = "/etc/n8n-certs/ca-bundle.crt"
        subPath   = "ca.crt"
        readOnly  = true
      }
    )
    error_message = "n8n_extra_ca_pem must render the ca-bundle mount read-only at /etc/n8n-certs/ca-bundle.crt."
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "NODE_EXTRA_CA_CERTS", value = "/etc/n8n-certs/ca-bundle.crt" }
    )
    error_message = "n8n_extra_ca_pem must set NODE_EXTRA_CA_CERTS to the mounted path."
  }

  assert {
    condition     = local.k8s_values_pod_annotations.podAnnotations["checksum/extra-ca"] == sha256("${trimspace(var.n8n_extra_ca_pem)}\n")
    error_message = "The checksum/extra-ca pod annotation must be the sha256 of the (trimmed) PEM, so a changed PEM rolls the pods."
  }
}

run "n8n_extra_ca_pem_checksum_changes_with_the_pem" {
  command = plan

  variables {
    n8n_extra_ca_pem = <<-PEM
      -----BEGIN CERTIFICATE-----
      MIIBdifferent0987654321bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      -----END CERTIFICATE-----
    PEM
  }

  # The checksum is a pure function of this run's own PEM (sha256 of the
  # trimmed content, matching local.n8n_ca_bundle_pem), recomputed at every
  # plan rather than cached from a prior apply. Proving it matches the formula
  # here, against a PEM that differs from the one in the run above, is what
  # shows a changed PEM produces a changed annotation and so rolls the pods.
  assert {
    condition     = local.k8s_values_pod_annotations.podAnnotations["checksum/extra-ca"] == sha256("${trimspace(var.n8n_extra_ca_pem)}\n")
    error_message = "The checksum/extra-ca pod annotation must track this run's own PEM."
  }
}

run "n8n_extra_ca_pem_rejects_a_missing_certificate" {
  command = plan

  variables {
    n8n_extra_ca_pem = "not a certificate"
  }

  expect_failures = [var.n8n_extra_ca_pem]
}

run "n8n_extra_ca_pem_rejects_a_private_key" {
  command = plan

  variables {
    n8n_extra_ca_pem = <<-PEM
      -----BEGIN CERTIFICATE-----
      MIIBtest1234567890aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      -----END CERTIFICATE-----
      -----BEGIN PRIVATE KEY-----
      MIIBtest1234567890aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      -----END PRIVATE KEY-----
    PEM
  }

  expect_failures = [var.n8n_extra_ca_pem]
}

run "n8n_extra_ca_pem_reserves_the_ca_bundle_volume_name_while_set" {
  command = plan

  variables {
    n8n_extra_ca_pem = <<-PEM
      -----BEGIN CERTIFICATE-----
      MIIBtest1234567890aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      -----END CERTIFICATE-----
    PEM
    n8n_extra_volumes = [{
      name       = "ca-bundle"
      config_map = { name = "my-own-ca" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "ca-bundle"
      mount_path = "/etc/my-own-ca"
      read_only  = true
    }]
  }

  expect_failures = [var.n8n_extra_ca_pem]
}

# The same name is accepted when n8n_extra_ca_pem is unset: the reservation is
# conditional, not permanent, so this is the same configuration the
# "extra_volumes_reach_the_chart" run elsewhere in this file already exercises.
run "ca_bundle_volume_name_is_free_when_n8n_extra_ca_pem_is_unset" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "ca-bundle"
      config_map = { name = "my-own-ca" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "ca-bundle"
      mount_path = "/etc/my-own-ca"
      read_only  = true
    }]
  }

  assert {
    condition     = length(local.k8s_values_volumes.extraVolumes) == 1
    error_message = "A caller-owned \"ca-bundle\" volume must be accepted when n8n_extra_ca_pem is not set."
  }
}

run "n8n_extra_ca_pem_reserves_the_mount_path_while_set" {
  command = plan

  variables {
    n8n_extra_ca_pem = <<-PEM
      -----BEGIN CERTIFICATE-----
      MIIBtest1234567890aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      -----END CERTIFICATE-----
    PEM
    n8n_extra_volumes = [{
      name   = "my-ca"
      secret = { secret_name = "my-own-ca-secret" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "my-ca"
      mount_path = "/etc/n8n-certs/ca-bundle.crt"
      read_only  = true
    }]
  }

  expect_failures = [var.n8n_extra_ca_pem]
}

run "n8n_extra_ca_pem_reserves_node_extra_ca_certs_in_extra_env_while_set" {
  command = plan

  variables {
    n8n_extra_ca_pem = <<-PEM
      -----BEGIN CERTIFICATE-----
      MIIBtest1234567890aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      -----END CERTIFICATE-----
    PEM
    n8n_extra_env = [
      { name = "NODE_EXTRA_CA_CERTS", value = "/somewhere/else.crt" },
    ]
  }

  expect_failures = [var.n8n_extra_ca_pem]
}

run "n8n_extra_ca_pem_reserves_node_extra_ca_certs_in_extra_env_from_secret_while_set" {
  command = plan

  variables {
    n8n_extra_ca_pem = <<-PEM
      -----BEGIN CERTIFICATE-----
      MIIBtest1234567890aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      -----END CERTIFICATE-----
    PEM
    n8n_extra_env_from_secret = [{
      name        = "NODE_EXTRA_CA_CERTS"
      secret_name = "caller-ca-secret"
      secret_key  = "path"
    }]
  }

  expect_failures = [var.n8n_extra_ca_pem]
}

# NODE_EXTRA_CA_CERTS is free to use through n8n_extra_env when
# n8n_extra_ca_pem is unset, same conditional-reservation shape as the volume
# name and mount path above: a caller may mount their own bundle entirely
# through the generic escape hatches without ever touching this input.
run "node_extra_ca_certs_is_free_in_extra_env_when_n8n_extra_ca_pem_is_unset" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "NODE_EXTRA_CA_CERTS", value = "/opt/my-ca/bundle.crt" },
    ]
  }

  assert {
    condition = contains(
      local.k8s_values_config.config.extraEnv,
      { name = "NODE_EXTRA_CA_CERTS", value = "/opt/my-ca/bundle.crt" }
    )
    error_message = "NODE_EXTRA_CA_CERTS must reach the chart via n8n_extra_env when n8n_extra_ca_pem is not set."
  }
}

# ── DNS-name validation: n8n_domain / n8n_additional_domains ─────────────────
# The regex used to be a single character class that admitted "a--b..com": no
# per-label structure, so a doubled dot or a hyphen-only label passed. These
# cover the shapes the tightened grammar now rejects, and that a legitimate
# name with hyphens still passes.

run "n8n_domain_rejects_a_doubled_dot" {
  command = plan

  variables {
    n8n_domain = "n8n..example.com"
  }

  expect_failures = [var.n8n_domain]
}

run "n8n_domain_rejects_a_label_starting_with_a_hyphen" {
  command = plan

  variables {
    n8n_domain = "-n8n.example.com"
  }

  expect_failures = [var.n8n_domain]
}

run "n8n_domain_rejects_a_label_ending_with_a_hyphen" {
  command = plan

  variables {
    n8n_domain = "n8n-.example.com"
  }

  expect_failures = [var.n8n_domain]
}

run "n8n_domain_rejects_a_label_over_63_characters" {
  command = plan

  variables {
    n8n_domain = "${join("", [for i in range(64) : "a"])}.example.com"
  }

  expect_failures = [var.n8n_domain]
}

run "n8n_domain_accepts_internal_hyphens" {
  command = plan

  variables {
    n8n_domain = "n8n-prod.example.com"
  }

  assert {
    condition     = var.n8n_domain == "n8n-prod.example.com"
    error_message = "A hyphen inside a label, away from its edges, must still be accepted."
  }
}

run "n8n_additional_domains_rejects_a_doubled_dot" {
  command = plan

  variables {
    n8n_additional_domains = ["hooks..example.com"]
  }

  expect_failures = [var.n8n_additional_domains]
}

run "n8n_additional_domains_rejects_a_label_over_63_characters" {
  command = plan

  variables {
    n8n_additional_domains = ["${join("", [for i in range(64) : "a"])}.example.com"]
  }

  expect_failures = [var.n8n_additional_domains]
}


# ── V8 heap tuning: n8n_node_max_old_space_size_mb ───────────────────────────

run "node_max_old_space_size_omits_node_options_by_default" {
  command = plan

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv : e if e.name == "NODE_OPTIONS"
    ]) == 0
    error_message = "With n8n_node_max_old_space_size_mb left null, no NODE_OPTIONS entry should render at all."
  }
}

run "node_max_old_space_size_renders_the_flag" {
  command = plan

  variables {
    n8n_node_max_old_space_size_mb = 3072
  }

  assert {
    condition = one([
      for e in local.k8s_values_config.config.extraEnv : e.value if e.name == "NODE_OPTIONS"
    ]) == "--max-old-space-size=3072"
    error_message = "n8n_node_max_old_space_size_mb must render NODE_OPTIONS=--max-old-space-size=<value> in config.extraEnv."
  }
}

run "node_max_old_space_size_rejects_below_256" {
  command = plan

  variables {
    n8n_node_max_old_space_size_mb = 128
  }

  expect_failures = [var.n8n_node_max_old_space_size_mb]
}

run "node_max_old_space_size_rejects_a_fractional_value" {
  command = plan

  variables {
    n8n_node_max_old_space_size_mb = 3072.5
  }

  expect_failures = [var.n8n_node_max_old_space_size_mb]
}

# NODE_OPTIONS is reserved in n8n_extra_env only while the tuning input is set:
# with it null there is nothing of the module's for a caller's own NODE_OPTIONS
# (unrelated flags) to clobber.
run "node_options_is_free_in_extra_env_when_the_tuning_input_is_unset" {
  command = plan

  variables {
    n8n_extra_env = [{ name = "NODE_OPTIONS", value = "--enable-source-maps" }]
  }

  assert {
    condition = one([
      for e in local.k8s_values_config.config.extraEnv : e.value if e.name == "NODE_OPTIONS"
    ]) == "--enable-source-maps"
    error_message = "With n8n_node_max_old_space_size_mb null, NODE_OPTIONS must be free for n8n_extra_env to set."
  }
}

run "node_options_is_reserved_in_extra_env_once_the_tuning_input_is_set" {
  command = plan

  variables {
    n8n_node_max_old_space_size_mb = 2048
    n8n_extra_env                  = [{ name = "NODE_OPTIONS", value = "--enable-source-maps" }]
  }

  expect_failures = [var.n8n_extra_env]
}


# ── Credential overwrites: n8n_credentials_overwrite_secret_ref ──────────────

run "credentials_overwrite_renders_no_volume_by_default" {
  command = plan

  assert {
    condition     = length([for v in local.k8s_values_volumes.extraVolumes : v if v.name == "credentials-overwrite"]) == 0
    error_message = "With n8n_credentials_overwrite_secret_ref null, no credentials-overwrite volume should render."
  }

  assert {
    condition     = length(local.n8n_credentials_overwrite_env) == 0
    error_message = "With n8n_credentials_overwrite_secret_ref null, no CREDENTIALS_OVERWRITE_DATA_FILE entry should render."
  }
}

run "credentials_overwrite_reaches_the_rendered_values" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "n8n-credentials-overwrite"
    }
  }

  assert {
    condition = one([
      for v in local.k8s_values_volumes.extraVolumes : v if v.name == "credentials-overwrite"
    ]).secret.secretName == "n8n-credentials-overwrite"
    error_message = "n8n_credentials_overwrite_secret_ref.name must reach the rendered Secret volume."
  }

  assert {
    condition = one([
      for v in local.k8s_values_volumes.extraVolumes : v if v.name == "credentials-overwrite"
    ]).secret.items[0].key == "credentials-overwrite.json"
    error_message = "key must default to \"credentials-overwrite.json\"."
  }

  assert {
    condition = one([
      for m in local.k8s_values_volumes.extraVolumeMounts : m if m.name == "credentials-overwrite"
    ]).mountPath == "/etc/n8n/credentials-overwrite"
    error_message = "The mount path must be /etc/n8n/credentials-overwrite."
  }

  assert {
    condition = one([
      for m in local.k8s_values_volumes.extraVolumeMounts : m if m.name == "credentials-overwrite"
    ]).readOnly == true
    error_message = "The credentials-overwrite mount must be read-only."
  }

  assert {
    condition = one([
      for e in local.k8s_values_config.config.extraEnv : e.value if e.name == "CREDENTIALS_OVERWRITE_DATA_FILE"
    ]) == "/etc/n8n/credentials-overwrite/credentials-overwrite.json"
    error_message = "CREDENTIALS_OVERWRITE_DATA_FILE must point at the mounted file path."
  }
}

run "credentials_overwrite_honors_a_custom_key" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "n8n-credentials-overwrite"
      key  = "overwrite.json"
    }
  }

  assert {
    condition = one([
      for e in local.k8s_values_config.config.extraEnv : e.value if e.name == "CREDENTIALS_OVERWRITE_DATA_FILE"
    ]) == "/etc/n8n/credentials-overwrite/overwrite.json"
    error_message = "A custom key must be reflected in both the mounted path and CREDENTIALS_OVERWRITE_DATA_FILE."
  }
}

run "credentials_overwrite_rejects_a_bad_secret_name" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "Not_A_Valid_Name"
    }
  }

  expect_failures = [var.n8n_credentials_overwrite_secret_ref]
}

run "credentials_overwrite_rejects_a_bad_key" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "n8n-credentials-overwrite"
      key  = ".."
    }
  }

  expect_failures = [var.n8n_credentials_overwrite_secret_ref]
}

run "credentials_overwrite_conflicts_with_extra_env" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "n8n-credentials-overwrite"
    }
    n8n_extra_env = [{ name = "CREDENTIALS_OVERWRITE_DATA_FILE", value = "/tmp/whatever" }]
  }

  expect_failures = [var.n8n_credentials_overwrite_secret_ref]
}

run "credentials_overwrite_reserves_the_volume_name" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "n8n-credentials-overwrite"
    }
    n8n_extra_volumes = [{
      name   = "credentials-overwrite"
      secret = { secret_name = "something-else" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "credentials-overwrite"
      mount_path = "/opt/something-else"
    }]
  }

  expect_failures = [var.n8n_credentials_overwrite_secret_ref]
}

run "credentials_overwrite_reserves_the_mount_path" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "n8n-credentials-overwrite"
    }
    n8n_extra_volumes = [{
      name   = "my-own-mount"
      secret = { secret_name = "something-else" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "my-own-mount"
      mount_path = "/etc/n8n/credentials-overwrite"
    }]
  }

  expect_failures = [var.n8n_credentials_overwrite_secret_ref]
}

# n8n_credentials_overwrite_secret_ref's own collision validation only
# checked n8n_extra_env (the plain escape hatch), not
# n8n_extra_env_from_secret (the Secret-backed one), even though both render
# into the same config.extraEnv list: a caller using the Secret-backed input
# instead of the plain one hit no guard at all until the matching validation
# was added above.
run "credentials_overwrite_conflicts_with_extra_env_from_secret" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "n8n-credentials-overwrite"
    }
    n8n_extra_env_from_secret = [
      { name = "CREDENTIALS_OVERWRITE_DATA_FILE", secret_name = "something-else", secret_key = "value" },
    ]
  }

  expect_failures = [var.n8n_credentials_overwrite_secret_ref]
}

# ── Pod DNS: n8n_dns_config ───────────────────────────────────────────────────

run "dns_config_omits_the_key_by_default" {
  command = plan

  assert {
    condition     = !contains(keys(local.k8s_values_dns), "dnsConfig")
    error_message = "With n8n_dns_config null, the dnsConfig key must be omitted from the values tree entirely."
  }
}

run "dns_config_renders_ndots" {
  command = plan

  variables {
    n8n_dns_config = {
      options = [{ name = "ndots", value = "1" }]
    }
  }

  assert {
    condition     = local.k8s_values_dns.dnsConfig.options[0].name == "ndots" && local.k8s_values_dns.dnsConfig.options[0].value == "1"
    error_message = "n8n_dns_config.options must reach the chart's dnsConfig.options."
  }
}

run "dns_config_renders_nameservers_and_searches" {
  command = plan

  variables {
    n8n_dns_config = {
      nameservers = ["10.0.0.10"]
      searches    = ["svc.cluster.local"]
    }
  }

  assert {
    condition     = tolist(local.k8s_values_dns.dnsConfig.nameservers) == tolist(["10.0.0.10"])
    error_message = "n8n_dns_config.nameservers must reach the chart's dnsConfig.nameservers."
  }

  assert {
    condition     = tolist(local.k8s_values_dns.dnsConfig.searches) == tolist(["svc.cluster.local"])
    error_message = "n8n_dns_config.searches must reach the chart's dnsConfig.searches."
  }
}

run "dns_config_rejects_more_than_three_nameservers" {
  command = plan

  variables {
    n8n_dns_config = {
      nameservers = ["10.0.0.10", "10.0.0.11", "10.0.0.12", "10.0.0.13"]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_a_malformed_nameserver" {
  command = plan

  variables {
    n8n_dns_config = {
      nameservers = ["not-an-ip"]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_an_out_of_range_ndots" {
  command = plan

  variables {
    n8n_dns_config = {
      options = [{ name = "ndots", value = "16" }]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_a_fractional_ndots" {
  command = plan

  variables {
    n8n_dns_config = {
      options = [{ name = "ndots", value = "1.5" }]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

# ── The queue survives a crash, and an in-place upgrade does not deadlock ─────
# The chart's generated valkey.conf carries no persistence directives, so the
# server's built-in defaults apply: RDB snapshots only, appendonly no, up to
# an hour of accepted jobs lost silently on a crash. And in standalone mode
# the chart renders a Deployment whose default RollingUpdate strategy starts
# the new pod against a ReadWriteOnce PVC the old pod still holds, so the
# first in-place values change deadlocks on Multi-Attach. The Recreate fix
# carries no input and is unconditional (and changing only a Deployment's
# strategy.type never itself restarts anything, so adopting it alone is
# quiet); the persistence toggle and the rotation-roll checksum both default
# off, so all three are asserted separately with no override_resource needed
# at the defaults.
run "the_valkey_deployment_recreates_rather_than_rolling" {
  command = plan

  variables {
    redis_backend = "valkey"
  }

  assert {
    condition = alltrue([
      for r in helm_release.valkey :
      yamldecode(r.values[0]).deploymentStrategy == "Recreate"
    ])
    error_message = "The Valkey Deployment must use Recreate: RollingUpdate against the chart's ReadWriteOnce PVC deadlocks every in-place upgrade on Multi-Attach."
  }

  assert {
    condition = alltrue([
      for r in helm_release.valkey :
      !can(yamldecode(r.values[0]).valkeyConfig)
    ])
    error_message = "valkey_append_only_enabled defaults to false, so the default plan must render no valkeyConfig at all, which is the chart's own default, not an empty string that would still mount a config file."
  }

  assert {
    condition = alltrue([
      for r in helm_release.valkey :
      !can(yamldecode(r.values[0]).podAnnotations)
    ])
    error_message = "valkey_password_rotation_roll_enabled defaults to false, so the default plan must render no podAnnotations at all: introducing that key is itself a pod-template change, and a default caller who rotated nothing and asked for nothing should not eat the one-time Recreate outage that adding it causes."
  }
}

run "enabling_append_only_persists_the_queue_across_a_crash" {
  command = plan

  variables {
    redis_backend              = "valkey"
    valkey_append_only_enabled = true
  }

  assert {
    condition = alltrue([
      for r in helm_release.valkey :
      strcontains(yamldecode(r.values[0]).valkeyConfig, "appendonly yes")
    ])
    error_message = "valkey_append_only_enabled = true must render appendonly yes into valkeyConfig, or a queue crash silently loses every job accepted since the last RDB snapshot."
  }

  assert {
    condition = alltrue([
      for r in helm_release.valkey :
      strcontains(yamldecode(r.values[0]).valkeyConfig, "appendfsync everysec")
    ])
    error_message = "appendfsync everysec must accompany appendonly, bounding the loss window to about one second of writes."
  }

  assert {
    condition = alltrue([
      for r in helm_release.valkey :
      yamldecode(r.values[0]).deploymentStrategy == "Recreate"
    ])
    error_message = "Recreate is not tied to the persistence toggle: the Multi-Attach deadlock exists either way."
  }
}

# ── Rotating the generated Valkey password rolls both sides, opt-in ───────────
# The n8n pods resolve the password from a secretKeyRef once at start and
# Valkey loads its ACL file once at start, so without a checksum annotation on
# both releases a rotation restarts nothing and the first unrelated restart on
# either side lands on the other side's generation, breaking the queue.
# valkey_password_rotation_roll_enabled defaults to false: introducing the
# checksum key into podAnnotations for the first time is itself a
# pod-template change, and with deploymentStrategy = Recreate already in
# place that first change takes Valkey fully down and back up once, not an
# overlap. A default caller who rotated nothing and asked for nothing should
# not eat that outage as a side effect of a module upgrade, so the whole
# mechanism is opt-in and renders nothing until explicitly turned on.
run "the_valkey_password_checksum_is_absent_until_opted_in" {
  command = plan

  variables {
    redis_backend = "valkey"
  }

  assert {
    condition     = length(local.k8s_values_pod_annotations) == 0
    error_message = "With valkey_password_rotation_roll_enabled at its default (false), no podAnnotations should be rendered on the n8n release."
  }

  assert {
    condition = alltrue([
      for r in helm_release.valkey :
      !can(yamldecode(r.values[0]).podAnnotations)
    ])
    error_message = "With valkey_password_rotation_roll_enabled at its default (false), the Valkey release must render no podAnnotations key."
  }
}

# The external-redis path has no module-generated credential to hash, and the
# gate keeps its rendered values byte-identical regardless of the toggle.
run "the_external_redis_path_renders_no_pod_annotations_even_when_enabled" {
  command = plan

  variables {
    redis_backend                         = "external"
    redis_host                            = "redis.internal.example.com"
    valkey_password_rotation_roll_enabled = true
  }

  assert {
    condition     = !contains(keys(local.k8s_values_final), "podAnnotations")
    error_message = "No podAnnotations key may render on the external-redis path; the checksum exists only for the credential the module itself generates, regardless of the toggle."
  }
}

# ── The n8n release waits for Postgres, not just for the Cluster manifest ─────
# A plan-time test cannot observe a race. What it can hold is the shape of the
# barrier: that a readiness gate exists on the CNPG path, that it polls the
# Cluster's own rw Service with no carriage returns in the script, that it is
# sized rather than BestEffort, that it carries no TTL (a TTL deletes the Job
# object itself, which would recreate it on every later plan, forever), and
# that it is absent on the external backend where the database is the
# caller's and already running. The edge from the release to this Job is the
# part that removes the race, and it is proven at apply by the graph itself
# rather than here.
run "the_cnpg_backend_gets_a_postgres_readiness_barrier" {
  command = plan

  assert {
    condition     = length(kubernetes_job_v1.cnpg_ready) == 1
    error_message = "The CNPG backend must create a readiness Job: kubectl_manifest applies the Cluster without waiting for it, so without this the n8n release starts against a database that may not exist yet."
  }

  assert {
    condition = strcontains(
      kubernetes_job_v1.cnpg_ready[0].spec[0].template[0].spec[0].container[0].command[2],
      local.cnpg_service_host
    )
    error_message = "The readiness Job must poll the CNPG Cluster's rw Service, which is the host the release connects to when no pooler is in front of it."
  }

  assert {
    condition     = !strcontains(kubernetes_job_v1.cnpg_ready[0].spec[0].template[0].spec[0].container[0].command[2], "\r")
    error_message = "The readiness script must contain no carriage returns: /bin/sh in the container is dash, and it reads `then\\r` as a word rather than a keyword, so a CRLF checkout would die on the script's first `if`."
  }

  # Reuses the operand image on purpose. A second image would be another pull
  # to schedule, another tag to keep current, and another thing to mirror on an
  # air-gapped cluster, for a binary the operand already ships.
  assert {
    condition     = kubernetes_job_v1.cnpg_ready[0].spec[0].template[0].spec[0].container[0].image == "ghcr.io/cloudnative-pg/postgresql:${var.cnpg_postgres_image_tag}"
    error_message = "The readiness Job must run the same operand image as the Cluster, which is where pg_isready comes from."
  }

  assert {
    condition     = kubernetes_job_v1.cnpg_ready[0].spec[0].ttl_seconds_after_finished == null
    error_message = "The readiness Job must not set ttl_seconds_after_finished: the TTL controller deletes the Job object itself, not just its completed pod, so Terraform would recreate it on every plan run past the TTL window, forever."
  }

  assert {
    condition = alltrue([
      kubernetes_job_v1.cnpg_ready[0].spec[0].template[0].spec[0].container[0].resources[0].requests.cpu == "50m",
      kubernetes_job_v1.cnpg_ready[0].spec[0].template[0].spec[0].container[0].resources[0].requests.memory == "64Mi",
      kubernetes_job_v1.cnpg_ready[0].spec[0].template[0].spec[0].container[0].resources[0].limits.cpu == "200m",
      kubernetes_job_v1.cnpg_ready[0].spec[0].template[0].spec[0].container[0].resources[0].limits.memory == "128Mi",
    ])
    error_message = "The readiness Job's container must declare requests and limits, or it cannot schedule where a ResourceQuota requires them and a LimitRange default applies unseen."
  }
}

run "an_external_postgres_gets_no_readiness_barrier" {
  command = plan

  variables {
    postgres_backend = "external"
    db_host          = "postgres.example.com"
    db_password      = "not-a-real-password"
  }

  assert {
    condition     = length(kubernetes_job_v1.cnpg_ready) == 0
    error_message = "The readiness Job belongs to the CNPG Cluster this module creates. On the external backend there is no Cluster to wait for, and polling a database the module does not own would fail an apply over the caller's own infrastructure."
  }
}

# cnpg_ready_timeout governs the same barrier: the default must reproduce the
# hardcoded 300-attempt / 2s-sleep budget this module shipped before the input
# existed, so a deployment that leaves it unset behaves unchanged.
run "cnpg_ready_timeout_defaults_to_the_original_budget" {
  command = plan

  assert {
    condition     = strcontains(kubernetes_job_v1.cnpg_ready[0].spec[0].template[0].spec[0].container[0].command[2], "-ge 300")
    error_message = "cnpg_ready_timeout must default to 600s, reproducing the 300-attempt threshold (300 x 2s sleep) this module hardcoded before the input existed."
  }

  assert {
    condition     = strcontains(kubernetes_job_v1.cnpg_ready[0].spec[0].template[0].spec[0].container[0].command[2], "within 600s")
    error_message = "The failure message must name the actual configured budget."
  }
}

# Raising it moves both the attempt threshold and the failure message, so a
# caller with a healthy but slow bootstrap (large WAL replay, cold storage)
# gets more time independent of n8n_helm_timeout, which this Job completes
# before helm_release.n8n's own wait even starts.
run "cnpg_ready_timeout_is_configurable" {
  command = plan

  variables {
    cnpg_ready_timeout = 1800
  }

  assert {
    condition     = strcontains(kubernetes_job_v1.cnpg_ready[0].spec[0].template[0].spec[0].container[0].command[2], "-ge 900")
    error_message = "cnpg_ready_timeout = 1800 must raise the attempt threshold to 900 (1800s / 2s sleep), not stay pinned at the old hardcoded 300."
  }

  assert {
    condition     = strcontains(kubernetes_job_v1.cnpg_ready[0].spec[0].template[0].spec[0].container[0].command[2], "within 1800s")
    error_message = "The failure message must name the raised budget, not the old hardcoded 10 minutes."
  }
}

run "cnpg_ready_timeout_rejects_a_fraction" {
  command = plan

  variables {
    cnpg_ready_timeout = 600.5
  }

  expect_failures = [var.cnpg_ready_timeout]
}

run "cnpg_ready_timeout_rejects_below_60" {
  command = plan

  variables {
    cnpg_ready_timeout = 59
  }

  expect_failures = [var.cnpg_ready_timeout]
}

# ── The database, pooler and queue are sized only when asked ──────────────────
# All twelve sizing inputs default null, rendering no resources key at all:
# today's BestEffort scheduling, unchanged for a caller who sets nothing.
run "backend_resources_are_absent_at_defaults" {
  command = plan

  assert {
    condition     = !contains(keys(yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec), "resources")
    error_message = "The CNPG Cluster must render no resources key while every cnpg_*_request/_limit input is null, or an existing deployment's BestEffort scheduling changes on adoption."
  }

  assert {
    condition = alltrue([
      for r in helm_release.valkey :
      !can(yamldecode(r.values[0]).resources)
    ])
    error_message = "The Valkey release must render no resources key while every valkey_*_request/_limit input is null."
  }

  assert {
    condition     = local.n8n_backend_cpu_request_millis["postgres"] == 0 && local.n8n_backend_cpu_request_millis["pooler"] == 0 && local.n8n_backend_cpu_request_millis["valkey"] == 0
    error_message = "Every backend term in the capacity model must be 0 while its sizing inputs are unset, matching the rendered reality that nothing was requested."
  }
}

run "cnpg_cluster_resources_reach_the_spec_when_set" {
  command = plan

  variables {
    cnpg_cpu_request    = "500m"
    cnpg_cpu_limit      = "2000m"
    cnpg_memory_request = "1Gi"
    cnpg_memory_limit   = "2Gi"
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.resources.requests.cpu == "500m"
    error_message = "cnpg_cpu_request must reach the Cluster spec verbatim."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.resources.requests.memory == "1Gi"
    error_message = "cnpg_memory_request must reach the Cluster spec verbatim."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.resources.limits.cpu == "2000m" && yamldecode(kubectl_manifest.cnpg_cluster[0].yaml_body).spec.resources.limits.memory == "2Gi"
    error_message = "cnpg_cpu_limit and cnpg_memory_limit must reach the Cluster spec verbatim."
  }
}

run "cnpg_cpu_request_rejects_a_memory_quantity" {
  command = plan

  variables {
    cnpg_cpu_request = "128Mi"
  }

  expect_failures = [var.cnpg_cpu_request]
}

run "cnpg_cpu_request_rejects_whitespace" {
  command = plan

  variables {
    cnpg_cpu_request = " 500m"
  }

  expect_failures = [var.cnpg_cpu_request]
}

run "cnpg_cpu_limit_rejects_a_memory_quantity" {
  command = plan

  variables {
    cnpg_cpu_limit = "256Mi"
  }

  expect_failures = [var.cnpg_cpu_limit]
}

run "cnpg_cpu_limit_rejects_whitespace" {
  command = plan

  variables {
    cnpg_cpu_limit = " 2000m"
  }

  expect_failures = [var.cnpg_cpu_limit]
}

run "cnpg_memory_request_rejects_a_cpu_quantity" {
  command = plan

  variables {
    cnpg_memory_request = "500m"
  }

  expect_failures = [var.cnpg_memory_request]
}

run "cnpg_memory_request_rejects_whitespace" {
  command = plan

  variables {
    cnpg_memory_request = "1Gi "
  }

  expect_failures = [var.cnpg_memory_request]
}

run "cnpg_memory_limit_rejects_a_cpu_quantity" {
  command = plan

  variables {
    cnpg_memory_limit = "2000m"
  }

  expect_failures = [var.cnpg_memory_limit]
}

run "cnpg_memory_limit_rejects_whitespace" {
  command = plan

  variables {
    cnpg_memory_limit = "2Gi "
  }

  expect_failures = [var.cnpg_memory_limit]
}

run "cnpg_pooler_resources_reach_the_spec_when_set" {
  command = plan

  variables {
    cnpg_pooler_enabled        = true
    db_postgresdb_ssl_enabled  = false
    cnpg_pooler_cpu_request    = "100m"
    cnpg_pooler_cpu_limit      = "500m"
    cnpg_pooler_memory_request = "128Mi"
    cnpg_pooler_memory_limit   = "256Mi"
  }

  assert {
    condition = alltrue([
      for m in kubectl_manifest.cnpg_pooler :
      yamldecode(m.yaml_body).spec.template.spec.containers[0].resources.requests.cpu == "100m"
    ])
    error_message = "The Pooler's pgbouncer container must carry cnpg_pooler_cpu_request; every database connection runs through it when enabled."
  }

  assert {
    condition = alltrue([
      for m in kubectl_manifest.cnpg_pooler :
      yamldecode(m.yaml_body).spec.template.spec.containers[0].resources.limits.memory == "256Mi"
    ])
    error_message = "The Pooler's pgbouncer container must carry cnpg_pooler_memory_limit."
  }
}

run "cnpg_pooler_cpu_request_rejects_a_memory_quantity" {
  command = plan

  variables {
    cnpg_pooler_cpu_request = "128Mi"
  }

  expect_failures = [var.cnpg_pooler_cpu_request]
}

run "cnpg_pooler_cpu_request_rejects_whitespace" {
  command = plan

  variables {
    cnpg_pooler_cpu_request = " 100m"
  }

  expect_failures = [var.cnpg_pooler_cpu_request]
}

run "cnpg_pooler_cpu_limit_rejects_a_memory_quantity" {
  command = plan

  variables {
    cnpg_pooler_cpu_limit = "256Mi"
  }

  expect_failures = [var.cnpg_pooler_cpu_limit]
}

run "cnpg_pooler_cpu_limit_rejects_whitespace" {
  command = plan

  variables {
    cnpg_pooler_cpu_limit = " 500m"
  }

  expect_failures = [var.cnpg_pooler_cpu_limit]
}

run "cnpg_pooler_memory_request_rejects_a_cpu_quantity" {
  command = plan

  variables {
    cnpg_pooler_memory_request = "100m"
  }

  expect_failures = [var.cnpg_pooler_memory_request]
}

run "cnpg_pooler_memory_request_rejects_whitespace" {
  command = plan

  variables {
    cnpg_pooler_memory_request = "128Mi "
  }

  expect_failures = [var.cnpg_pooler_memory_request]
}

run "cnpg_pooler_memory_limit_rejects_a_cpu_quantity" {
  command = plan

  variables {
    cnpg_pooler_memory_limit = "500m"
  }

  expect_failures = [var.cnpg_pooler_memory_limit]
}

run "cnpg_pooler_memory_limit_rejects_whitespace" {
  command = plan

  variables {
    cnpg_pooler_memory_limit = "256Mi "
  }

  expect_failures = [var.cnpg_pooler_memory_limit]
}

run "valkey_resources_reach_the_chart_values_when_set" {
  command = plan

  variables {
    redis_backend         = "valkey"
    valkey_cpu_request    = "250m"
    valkey_cpu_limit      = "1000m"
    valkey_memory_request = "256Mi"
    valkey_memory_limit   = "1Gi"
  }

  assert {
    condition = alltrue([
      for r in helm_release.valkey :
      yamldecode(r.values[0]).resources.requests.cpu == "250m" && yamldecode(r.values[0]).resources.requests.memory == "256Mi"
    ])
    error_message = "valkey_cpu_request and valkey_memory_request must reach the chart values verbatim."
  }

  assert {
    condition = alltrue([
      for r in helm_release.valkey :
      yamldecode(r.values[0]).resources.limits.cpu == "1000m" && yamldecode(r.values[0]).resources.limits.memory == "1Gi"
    ])
    error_message = "valkey_cpu_limit and valkey_memory_limit must reach the chart values verbatim."
  }
}

run "valkey_cpu_request_rejects_a_memory_quantity" {
  command = plan

  variables {
    valkey_cpu_request = "256Mi"
  }

  expect_failures = [var.valkey_cpu_request]
}

run "valkey_cpu_request_rejects_whitespace" {
  command = plan

  variables {
    valkey_cpu_request = " 250m"
  }

  expect_failures = [var.valkey_cpu_request]
}

run "valkey_cpu_limit_rejects_a_memory_quantity" {
  command = plan

  variables {
    valkey_cpu_limit = "1Gi"
  }

  expect_failures = [var.valkey_cpu_limit]
}

run "valkey_cpu_limit_rejects_whitespace" {
  command = plan

  variables {
    valkey_cpu_limit = " 1000m"
  }

  expect_failures = [var.valkey_cpu_limit]
}

run "valkey_memory_request_rejects_a_cpu_quantity" {
  command = plan

  variables {
    valkey_memory_request = "250m"
  }

  expect_failures = [var.valkey_memory_request]
}

run "valkey_memory_request_rejects_whitespace" {
  command = plan

  variables {
    valkey_memory_request = "256Mi "
  }

  expect_failures = [var.valkey_memory_request]
}

run "valkey_memory_limit_rejects_a_cpu_quantity" {
  command = plan

  variables {
    valkey_memory_limit = "1000m"
  }

  expect_failures = [var.valkey_memory_limit]
}

run "valkey_memory_limit_rejects_whitespace" {
  command = plan

  variables {
    valkey_memory_limit = "1Gi "
  }

  expect_failures = [var.valkey_memory_limit]
}

# The guard mirrors cnpg_resource_request_not_above_limit (postgres_cnpg.tf):
# a request above its own limit is a shape the Kubernetes API rejects
# outright, so the warning here must actually fire rather than only
# type-check.
run "valkey_cpu_request_above_its_limit_is_warned_about" {
  command = plan

  variables {
    redis_backend      = "valkey"
    valkey_cpu_request = "1000m"
    valkey_cpu_limit   = "500m"
  }

  expect_failures = [check.valkey_resource_request_not_above_limit]
}

run "valkey_memory_request_above_its_limit_is_warned_about" {
  command = plan

  variables {
    redis_backend         = "valkey"
    valkey_memory_request = "1Gi"
    valkey_memory_limit   = "256Mi"
  }

  expect_failures = [check.valkey_resource_request_not_above_limit]
}

run "valkey_request_at_its_limit_draws_no_warning" {
  command = plan

  variables {
    redis_backend         = "valkey"
    valkey_cpu_request    = "250m"
    valkey_cpu_limit      = "250m"
    valkey_memory_request = "256Mi"
    valkey_memory_limit   = "256Mi"
  }
}

# The Kubernetes rejection this check warns about only happens to a Valkey
# pod this module actually renders. On the external redis backend,
# helm_release.valkey never renders (redis_valkey.tf's count is gated on
# local.valkey_enabled), so a mismatched pair here is inert and must not
# warn, the same shape as postgres_cnpg.tf's cnpg_enabled gate.
run "valkey_resource_mismatch_on_the_external_backend_draws_no_warning" {
  command = plan

  variables {
    redis_backend      = "external"
    redis_host         = "redis.external.example.com"
    valkey_cpu_request = "1000m"
    valkey_cpu_limit   = "500m"
  }
}

# Hand-computed against this module's own defaults so a silent term change
# fails loudly: main 1 × (1000m + 200m task runner), workers 10 × (500m +
# 200m), webhooks 8 × 300m = 10600m with nothing backend-sized. Postgres and
# Valkey are both enabled by default (postgres_backend = "cnpg", redis_backend
# = "valkey"), but their terms stay 0 until their sizing inputs are set.
run "the_capacity_model_counts_nothing_from_unset_backends" {
  command = plan

  assert {
    condition     = local.n8n_peak_cpu_request_millis == 10600
    error_message = "Peak demand at the defaults must be 10600m: main 1200m, workers 7000m, webhooks 2400m, and zero from every backend whose sizing inputs are unset."
  }
}

run "the_capacity_model_counts_backend_terms_only_when_set" {
  command = plan

  variables {
    cnpg_cpu_request   = "500m"
    valkey_cpu_request = "250m"
  }

  assert {
    condition     = local.n8n_peak_cpu_request_millis == 11350
    error_message = "Peak demand must be 11350m: the 10600m base plus postgres 1 × 500m plus valkey 1 × 250m, now that both are set."
  }
}

run "the_pooler_term_counts_only_while_the_pooler_is_enabled" {
  command = plan

  variables {
    cnpg_pooler_enabled       = true
    db_postgresdb_ssl_enabled = false
    cnpg_pooler_cpu_request   = "100m"
  }

  assert {
    condition     = local.n8n_peak_cpu_request_millis == 10800
    error_message = "Peak demand must be 10800m: the 10600m base plus the pooler's 2 (cnpg_pooler_instances) × 100m, with postgres and valkey both still unsized."
  }
}

# A mismatched request/limit pair on the external backend reaches no Cluster
# or Pooler at all (both are documented "only used when postgres_backend =
# cnpg" / "cnpg_pooler_enabled"), so the check must stay silent there, unlike
# every other case above where cnpg is the active backend. A run with no
# expect_failures fails outright if the check still fired.
run "the_resource_limit_check_stays_quiet_on_the_external_backend" {
  command = plan

  variables {
    postgres_backend        = "external"
    db_host                 = "postgres.example.com"
    db_password             = "not-a-real-password"
    cnpg_cpu_request        = "2000m"
    cnpg_cpu_limit          = "500m"
    cnpg_pooler_cpu_request = "500m"
    cnpg_pooler_cpu_limit   = "100m"
  }

  assert {
    condition     = length(kubectl_manifest.cnpg_cluster) == 0
    error_message = "postgres_backend = \"external\" must plan no CNPG Cluster; the caller's server is the database."
  }
}

# A mismatched Pooler request/limit pair reaches no Pooler at all while
# cnpg_pooler_enabled stays at its default (false), even with the Cluster
# itself active (postgres_backend = "cnpg"). Gating this half of the check
# on cnpg_enabled alone, rather than cnpg_pooler_enabled, would warn about a
# Pooler pod that is never rendered.
run "the_pooler_resource_limit_check_stays_quiet_with_the_pooler_disabled" {
  command = plan

  variables {
    cnpg_pooler_cpu_request = "500m"
    cnpg_pooler_cpu_limit   = "100m"
  }

  assert {
    condition     = length(kubectl_manifest.cnpg_pooler) == 0
    error_message = "cnpg_pooler_enabled defaults to false, so no Pooler should be planned."
  }
}

# ── The namespace takes the caller's labels and annotations ───────────────────
# Pod Security Admission is switched on by labeling the namespace, an object
# the caller cannot otherwise reach on the path where the module creates it.
run "namespace_labels_and_annotations_reach_the_namespace" {
  command = plan

  variables {
    k8s_namespace_labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
    k8s_namespace_annotations = {
      "owner" = "platform-team"
    }
  }

  assert {
    condition     = kubernetes_namespace.n8n[0].metadata[0].labels["pod-security.kubernetes.io/enforce"] == "restricted"
    error_message = "Caller labels must reach the namespace; the PSA enforce label is the reason the input exists."
  }

  assert {
    condition     = kubernetes_namespace.n8n[0].metadata[0].labels["app.kubernetes.io/managed-by"] == "terraform-kubernetes-n8n"
    error_message = "The module's managed-by label must survive the merge when the caller does not override it."
  }

  assert {
    condition     = kubernetes_namespace.n8n[0].metadata[0].annotations["owner"] == "platform-team"
    error_message = "Caller annotations must reach the namespace."
  }
}

run "namespace_labels_and_annotations_are_empty_by_default" {
  command = plan

  assert {
    condition     = try(length(kubernetes_namespace.n8n[0].metadata[0].annotations), 0) == 0
    error_message = "With k8s_namespace_annotations at its default ({}), the namespace must carry no annotations, matching today's rendered namespace exactly."
  }

  assert {
    condition     = lookup(kubernetes_namespace.n8n[0].metadata[0].labels, "app.kubernetes.io/managed-by", null) == "terraform-kubernetes-n8n"
    error_message = "With k8s_namespace_labels at its default ({}), the namespace must still carry the module's own managed-by label."
  }

  assert {
    condition     = try(length(kubernetes_namespace.n8n[0].metadata[0].labels), 0) == 1
    error_message = "With k8s_namespace_labels at its default ({}), the namespace must carry exactly one label, the module's own managed-by, matching today's rendered namespace exactly."
  }
}

# ── Official n8n names are carved out of the DB_/QUEUE_ guard ─────────────────
# The DB_ and QUEUE_ reservations exist to protect module-written connection
# settings, but they also caught official n8n names the module writes nowhere:
# the external-Postgres mutual-TLS material the chart's own values comment
# says to supply via config.extraEnv, and the client tuning families. Those
# exact names pass; everything else under the prefixes stays blocked.
run "a_carved_out_db_name_passes_the_env_escape_hatch" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "DB_POSTGRESDB_SSL_CERT", value = "-----BEGIN CERTIFICATE-----\nMIIBtest\n-----END CERTIFICATE-----" },
      { name = "DB_POSTGRESDB_STATEMENT_TIMEOUT", value = "30000" },
    ]
  }

  assert {
    condition = alltrue([
      for wanted in ["DB_POSTGRESDB_SSL_CERT", "DB_POSTGRESDB_STATEMENT_TIMEOUT"] :
      contains([for e in local.k8s_values_config.config.extraEnv : e.name], wanted)
    ])
    error_message = "Carved-out DB_ names must pass validation and render; without them an external Postgres requiring mutual TLS cannot be wired at all."
  }
}

run "a_carved_out_name_passes_the_secret_backed_input_too" {
  command = plan

  variables {
    n8n_extra_env_from_secret = [
      {
        name        = "DB_POSTGRESDB_SSL_KEY"
        secret_name = "db-client-tls"
        secret_key  = "tls.key"
      },
    ]
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name],
      "DB_POSTGRESDB_SSL_KEY",
    )
    error_message = "The carve-out must apply to the secret-backed input as well; key material is exactly what belongs in a Secret rather than in values."
  }
}

run "a_connection_coordinate_is_still_refused_despite_the_carveouts" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "DB_POSTGRESDB_HOST", value = "not-the-module-database" },
    ]
  }

  # The carve-out is exact names, not a prefix hole: module-written connection
  # coordinates stay blocked, or the escape hatch could silently repoint the
  # deployment at another database.
  expect_failures = [var.n8n_extra_env]
}

run "ssl_ca_stays_refused_because_it_already_has_a_typed_door" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "DB_POSTGRESDB_SSL_CA", value = "-----BEGIN CERTIFICATE-----\nMIIBtest\n-----END CERTIFICATE-----" },
    ]
  }

  # Deliberately not carved out, unlike DB_POSTGRESDB_SSL_CERT/_KEY just above:
  # db_postgresdb_ssl_ca_pem already renders this exact destination through
  # the chart's own database.ssl.ca value, so opening this name here would let
  # a caller set the same thing two ways.
  expect_failures = [var.n8n_extra_env]
}

run "a_queue_client_tls_carveout_reaches_the_secret_backed_input" {
  command = plan

  variables {
    n8n_extra_env_from_secret = [
      {
        name        = "QUEUE_BULL_REDIS_TLS_SERVERNAME"
        secret_name = "redis-client-tls"
        secret_key  = "servername"
      },
    ]
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name],
      "QUEUE_BULL_REDIS_TLS_SERVERNAME",
    )
    error_message = "QUEUE_BULL_REDIS_TLS_SERVERNAME is a carved-out name with no chart value of its own; it must pass the secret-backed guard."
  }
}

# ── Two silent misconfigurations now warn at plan time ────────────────────────

run "a_database_with_no_backup_warns_until_acknowledged" {
  command = plan

  variables {
    cnpg_backup_acknowledged = null
  }

  expect_failures = [check.cnpg_has_no_backup_configured]
}

run "acknowledging_the_backup_trade_silences_the_warning" {
  command = plan

  # The fixture's acknowledged = true is exactly this case; asserted
  # explicitly so the silencing path is pinned rather than incidental.
  assert {
    condition     = var.cnpg_backup_acknowledged == true
    error_message = "The fixture must acknowledge the backup trade, or every run in this file would warn."
  }
}

run "configuring_a_backup_silences_the_warning_by_fixing_it" {
  command = plan

  variables {
    cnpg_backup_acknowledged = null
    cnpg_backup = {
      barmanObjectStore = {
        destinationPath = "s3://backups/n8n"
        endpointURL     = "https://minio.internal.example.com"
      }
    }
    # The default image type cannot serve the in-tree barman path; that
    # pairing has its own check, out of scope here.
    cnpg_postgres_image_tag = "16"
  }

  # No expect_failures: with a backup configured the check passes.
  assert {
    condition     = var.cnpg_backup != null
    error_message = "This run exists to prove the check stays quiet when a backup is configured."
  }
}

run "a_lan_ip_without_allocator_annotations_warns" {
  command = plan

  variables {
    metrics_lan_expose = {
      enabled = true
      ip      = "192.0.2.10"
    }
  }

  expect_failures = [check.lan_expose_ip_is_allocator_specific]
}

run "the_cnpg_half_of_the_lan_expose_warning_fires_too" {
  command = plan

  variables {
    cnpg_lan_expose = {
      enabled = true
      ip      = "192.0.2.11"
    }
  }

  expect_failures = [check.lan_expose_ip_is_allocator_specific]
}

run "an_allocator_annotation_silences_the_lan_expose_warning" {
  command = plan

  variables {
    metrics_lan_expose = {
      enabled = true
      ip      = "192.0.2.10"
      annotations = {
        "io.cilium/lb-ipam-ips" = "192.0.2.10"
      }
    }
  }

  # No expect_failures: an explicit allocator annotation is the caller saying
  # they have met their allocator, whichever one it is.
  assert {
    condition     = length(var.metrics_lan_expose.annotations) > 0
    error_message = "This run exists to prove the check stays quiet when annotations are set."
  }
}
