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

  # Through the chart's typed key, never as a second config.extraEnv entry: the
  # chart already emits WEBHOOK_URL from its own ConfigMap, and two entries of
  # one name in a container's env list fail the strategic merge patch on every
  # later helm upgrade.
  assert {
    condition     = !contains([for e in local.k8s_values_config.config.extraEnv : e.name], "WEBHOOK_URL")
    error_message = "WEBHOOK_URL must not also be appended to config.extraEnv; the duplicate breaks helm upgrade."
  }
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

  assert {
    condition     = local.k8s_values_webhook.webhook.url == "https://hooks.test.example.com"
    error_message = "n8n_webhook_url must override the value derived from n8n_domain."
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

run "execution_limits_and_pruning_reach_the_chart" {
  command = plan

  variables {
    n8n_execution_timeout           = 3600
    n8n_execution_timeout_max       = 7200
    n8n_execution_concurrency_limit = 25
    n8n_pruning_max_count           = 15000
  }

  assert {
    condition     = local.k8s_values_config.config.executions.timeout == 3600
    error_message = "n8n_execution_timeout must reach config.executions.timeout."
  }

  assert {
    condition     = local.k8s_values_config.config.executions.timeoutMax == 7200
    error_message = "n8n_execution_timeout_max must reach config.executions.timeoutMax."
  }

  assert {
    condition     = local.k8s_values_config.config.executions.concurrency.productionLimit == 25
    error_message = "n8n_execution_concurrency_limit must reach config.executions.concurrency.productionLimit."
  }

  assert {
    condition     = local.k8s_values_config.config.executions.pruning.maxCount == 15000
    error_message = "n8n_pruning_max_count must reach config.executions.pruning.maxCount."
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

# ── Binary-data mode is the caller's to set ───────────────────────────────────
# These two names were reserved as chart-rendered. Chart 1.10.0 emits them only
# from the n8n.s3Env helper, gated on s3.enabled, which this module pins false
# with no input to turn it on, so the guard blocked a name nothing set. It
# matters because n8n defaults binary data to "database" in scaling mode, which
# is the only mode this module runs: without this setting a shared volume
# mounts and stays empty.

run "a_caller_can_choose_filesystem_binary_data" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_DEFAULT_BINARY_DATA_MODE", value = "filesystem" },
      { name = "N8N_STORAGE_PATH", value = "/opt/n8n-shared/storage" },
    ]
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
