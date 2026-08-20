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

  assert {
    condition     = length(module.cluster_capacity) == 1
    error_message = "The kubernetes backend must instantiate modules/cluster-capacity: it is the only sizing diagnostic on this path."
  }
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

# WEBHOOK_URL sits in kubernetes_secret.n8n, but the chart wires only four keys
# from secretRefs.existingSecret, so on this backend it was never read. n8n then
# built webhook URLs from N8N_PROTOCOL + N8N_HOST - and N8N_PROTOCOL is "http",
# because TLS terminates at the ingress. Every advertised URL was http:// for an
# https:// endpoint, and n8n_webhook_url did nothing at all.
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
    error_message = "With no override, WEBHOOK_URL must be https:// against the canonical ingress host."
  }

  # On a single host the callback follows the same name as everything else.
  # Asserted here too so the output is covered on the path where the chart,
  # not the module, renders N8N_EDITOR_BASE_URL.
  assert {
    condition     = output.n8n_oauth_callback_url == "https://n8n.test.example.com/rest/oauth2-credential/callback"
    error_message = "On a single host the OAuth callback URL must follow the ingress host; got ${output.n8n_oauth_callback_url}."
  }

  # Through the chart's typed key, never as a second config.extraEnv entry: the
  # chart already emits WEBHOOK_URL from its own ConfigMap, and two entries of
  # one name in a container's env list fail the strategic merge patch on every
  # later helm upgrade.
  assert {
    condition     = !contains([for e in local.k8s_values_config.config.extraEnv : e.name], "WEBHOOK_URL")
    error_message = "WEBHOOK_URL must not also be appended to config.extraEnv; the duplicate breaks helm upgrade."
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
  # what the single-host run above asserts. Chart 1.10.0 derives
  # N8N_EDITOR_BASE_URL from webhook.url when it has no ingress host to read,
  # so leaving it set labels the editor with the webhook hostname and every
  # OAuth2 redirect URI 404s. Emptying it suppresses both chart keys and both
  # configMapKeyRef entries, so the module can set them from extraEnv without
  # the duplicate that breaks helm upgrade.
  assert {
    condition     = local.k8s_values_webhook.webhook.url == ""
    error_message = "On a split ingress the chart's webhook.url must be empty so it renders neither URL key."
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : "${e.name}=${e.value}"],
      "WEBHOOK_URL=https://hooks.test.example.com",
    )
    error_message = "Emptying webhook.url drops the chart's WEBHOOK_URL, so extraEnv must carry it back."
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

# The chart's taskRunners.enabled renders the sidecar but never emits
# N8N_RUNNERS_ENABLED, and n8n's own default is false: the broker never
# starts, the sidecar never registers, and Code nodes silently run in n8n's
# own process while the pod reports 2/2 Ready. The module has to emit the
# variable itself.
run "enabling_task_runners_starts_the_broker_not_just_the_sidecar" {
  command = plan

  variables {
    n8n_task_runners_enabled = true
  }

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv :
      e if e.name == "N8N_RUNNERS_ENABLED" && e.value == "true"
    ]) == 1
    error_message = "N8N_RUNNERS_ENABLED=true must be rendered into config.extraEnv when task runners are enabled; the chart never emits it and n8n's default is false, so without it the sidecar renders but the task broker never starts."
  }
}

# The broker toggle stands alone: n8n_runners_enabled = true without the
# sidecar starts n8n's task broker for the internal launcher or for runners
# operated outside this module. The sidecar values and its request timeout
# must NOT come with it - those belong to n8n_task_runners_enabled.
run "the_broker_toggle_works_without_the_sidecar" {
  command = plan

  variables {
    n8n_task_runners_enabled = false
    n8n_runners_enabled      = true
  }

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv :
      e if e.name == "N8N_RUNNERS_ENABLED" && e.value == "true"
    ]) == 1
    error_message = "n8n_runners_enabled must emit N8N_RUNNERS_ENABLED=true on its own; it exists for broker-without-sidecar deployments."
  }

  assert {
    condition     = local.k8s_values_task_runners.taskRunners.enabled == false
    error_message = "n8n_runners_enabled must not drag the sidecar in; taskRunners.enabled follows n8n_task_runners_enabled only."
  }

  assert {
    condition = length([
      for e in local.k8s_values_config.config.extraEnv :
      e if e.name == "N8N_RUNNERS_TASK_REQUEST_TIMEOUT"
    ]) == 0
    error_message = "The request timeout is a sidecar-path setting and must stay gated on n8n_task_runners_enabled, not on the broker toggle."
  }
}

# N8N_RUNNERS_ENABLED has exactly one door: the two toggles above. The
# N8N_RUNNERS_ prefix reservation must catch it in both extra-env inputs, or
# a caller can flip the broker without the module knowing - the same
# two-doors-one-checked failure the binary-data reservation exists for.
run "runners_enabled_is_rejected_from_extra_env" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_RUNNERS_ENABLED", value = "true" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "runners_enabled_is_rejected_from_the_secret_backed_input_too" {
  command = plan

  variables {
    n8n_extra_env_from_secret = [
      {
        name        = "N8N_RUNNERS_ENABLED"
        secret_name = "some-secret"
        secret_key  = "enabled"
      },
    ]
  }

  expect_failures = [var.n8n_extra_env_from_secret]
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

# The chart's webhook Ingress renders four of the five prefixes n8n serves from
# the webhook processors. The fifth (/mcp) falls through to the main pods, which
# answer 200 with the editor's HTML because no handler is registered, a webhook
# that looks delivered and never runs. Confirmed live against chart 1.10.0.
run "the_prefixes_the_chart_does_not_route_get_their_own_ingress" {
  command = plan

  assert {
    condition     = contains(local.n8n_unrouted_webhook_prefixes, "/mcp")
    error_message = "/mcp is not routed by the chart's own Ingress, so it must be in the supplementary set."
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n_mcp) == 1
    error_message = "create_ingress = true must render the supplementary Ingress while any prefix is unrouted."
  }

  assert {
    condition = alltrue([
      for p in kubernetes_ingress_v1.n8n_mcp[0].spec[0].rule[0].http[0].path :
      p.backend[0].service[0].name == local.n8n_webhook_service_name
    ])
    error_message = "Every supplementary path must target the webhook processors, not the main Service."
  }

  # The set is a subtraction, so a prefix added to one list and not the other
  # shows up here rather than as a silent routing hole in production.
  assert {
    condition = length(setsubtract(
      local.n8n_webhook_path_prefixes,
      setunion(local.n8n_chart_routed_webhook_prefixes, local.n8n_unrouted_webhook_prefixes)
    )) == 0
    error_message = "Every advertised webhook prefix must be either chart-routed or in the supplementary Ingress."
  }
}

run "the_supplementary_ingress_is_absent_when_the_caller_owns_routing" {
  command = plan

  variables {
    create_ingress = false
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n_mcp) == 0
    error_message = "create_ingress = false must render no Ingress at all, supplementary included."
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

# ── The webhook processor keeps an autoscaler on the KEDA path ────────────────
# The chart's own webhook HPA is gated on `not .Values.keda.enabled`, and its
# webhook ScaledObject needs keda.webhookProcessor.enabled, which this module
# leaves false on purpose. Without the supplementary HPA, attesting KEDA left
# the webhook pool with no autoscaler at all: and nothing failed, which is why
# this is asserted rather than assumed.

run "attesting_keda_still_leaves_the_webhook_processor_an_autoscaler" {
  command = plan

  variables {
    k8s_keda_installed            = true
    n8n_webhook_hpa_min_replicas  = 3
    n8n_webhook_hpa_max_replicas  = 9
    n8n_webhook_hpa_cpu_threshold = 55
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

  # Read off a live n8n-1.10.0 release: every name the chart puts in a
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
        "TZ", "WEBHOOK_URL",
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

# ── Postgres TLS has exactly one source ───────────────────────────────────────
# The chart offers database.ssl, and this module must not use it. Its enable
# flag renders DB_POSTGRESDB_SSL, a name n8n does not read (the image reads
# DB_POSTGRESDB_SSL_ENABLED), and its rejectUnauthorized = false renders a name
# this module already emits, which duplicates an env var and fails every later
# helm upgrade. TLS is expressed through config.extraEnv alone.

run "the_chart_ssl_key_is_never_set" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled = true
  }

  assert {
    condition     = !contains(keys(local.k8s_values_database.database), "ssl")
    error_message = "database.ssl must stay unset: its enable flag renders DB_POSTGRESDB_SSL, which n8n does not read, and its rejectUnauthorized renders a name this module already emits."
  }

  assert {
    condition = contains(
      [for e in local.k8s_values_config.config.extraEnv : e.name if e.name == "DB_POSTGRESDB_SSL_ENABLED"],
      "DB_POSTGRESDB_SSL_ENABLED",
    )
    error_message = "DB_POSTGRESDB_SSL_ENABLED must be rendered through config.extraEnv, which is the only source of Postgres TLS."
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
# The chart defaults pdb.enabled to true at minAvailable = 1 and renders it over
# the main Deployment, which this module pins to one replica. That is
# allowedDisruptions = 0 for the life of the deployment: the node holding the
# main pod can never be drained, so a Talos node upgrade stalls behind it.
run "the_main_pdb_is_off_by_default" {
  command = plan

  assert {
    condition     = local.k8s_values_pdb.pdb.enabled == false
    error_message = "pdb.enabled must render false by default. The chart's own default is true at minAvailable = 1, which against replicaCount = 1 blocks every voluntary eviction and wedges node drains."
  }

  assert {
    condition     = local.k8s_values_final.pdb.enabled == false
    error_message = "pdb must reach the final values tree. A fragment that is assembled and never merged is the defect class this suite exists to catch."
  }

  # The main pod is the only one the chart puts a PDB over, so this input has
  # to leave the worker and webhook tiers alone.
  assert {
    condition     = local.k8s_values_final.replicaCount == 1
    error_message = "The main Deployment must stay at one replica, which is what makes minAvailable = 1 unsatisfiable and this input necessary."
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

  # Reaching the chart is only half of it. Turning this on is exactly the
  # configuration that wedges a node drain, so the plan has to say so: a
  # warning nobody sees is the same as no warning. This asserts the diagnostic
  # fires, not that the plan fails, since a check block warns rather than
  # errors.
  expect_failures = [check.main_pdb_blocks_the_main_pod_node_drain]
}

# The typed input is not the only way in. n8n_extra_helm_values is merged after
# the module's own values and Helm gives the later file precedence, so the
# overlay can render the same object with the same consequence. A check that
# only read the input would stay silent on exactly the configuration it exists
# to catch.
run "the_extra_values_overlay_cannot_re_enable_the_pdb_silently" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      pdb:
        enabled: true
        minAvailable: 1
    YAML
  }

  assert {
    condition     = local.n8n_pdb_enabled_via_extra_values
    error_message = "The overlay setting pdb.enabled = true must be visible at plan time, or the check cannot warn about it."
  }

  expect_failures = [check.main_pdb_blocks_the_main_pod_node_drain]
}

# The detection must not fire on overlays that say nothing about the PDB, or
# the warning becomes noise on every deployment that uses the escape hatch at
# all, and a warning people learn to ignore is worse than none.
run "an_unrelated_extra_values_overlay_leaves_the_pdb_check_quiet" {
  command = plan

  variables {
    n8n_extra_helm_values = <<-YAML
      podLabels:
        team: platform
    YAML
  }

  assert {
    condition     = !local.n8n_pdb_enabled_via_extra_values
    error_message = "An overlay that never mentions pdb must not read as enabling it."
  }
}

# The tag is the one image key the module does NOT leave to the chart. The
# chart's default is the floating `stable`, resolved per node at pull time
# under IfNotPresent, so leaving it unset lets a rescheduled pod cross a
# version boundary and run n8n's one-way startup migrations with no plan, no
# apply and no operator in the loop.
run "the_image_tag_is_pinned_by_default" {
  command = plan

  # A bare version, for two reasons at once: the chart's own fallback is
  # `stable`, which resolves per node at pull time; and whenever
  # n8n_task_runner_image_tag is null (its default) the chart derives the
  # runner sidecar's tag from this one, so a tag n8nio/runners never
  # published fails the pull on every main and worker pod.
  assert {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.n8n_image_tag))
    error_message = "n8n_image_tag must default to a concrete, bare n8n version: null or a floating tag lets the chart's `stable` resolve per node at pull time, and a non-version tag makes the derived n8nio/runners sidecar tag unpullable."
  }

  assert {
    condition     = local.k8s_values_image.image.tag == var.n8n_image_tag
    error_message = "image.tag must carry n8n_image_tag into the chart, or the pinned default is accepted and then discarded while the pods run `stable`."
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
