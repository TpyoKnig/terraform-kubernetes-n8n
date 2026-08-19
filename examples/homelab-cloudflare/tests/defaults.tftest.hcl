# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# Plan-time tests for the homelab example using mocked providers.
#
# Exercises the example end-to-end with the in-cluster backing services
# selected: postgres_backend = "cnpg" + redis_backend = "valkey".
#
# The mocked-provider limitations documented in AGENTS.md apply here too:
# helm_release.values (and the k8s helm_release block itself) resolves to
# (known after apply) through the mocked kubernetes_namespace attribute chain,
# so asserts on the planned helm_release.n8n attributes (name, chart,
# namespace) are not possible under mocks. What IS assertable is that the
# module-level backing_services output resolves through local.k8s_pg_host /
# local.k8s_redis_host, which the CNPG + Valkey wiring both feed. Those
# assertions cover the "planned on the right backend" contract without
# reaching into resources whose attributes the mock provider defers.
#
# Run: terraform test
#   (from examples/homelab/, mocks require terraform >= 1.11)

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

# Required even though this example plans no Cloudflare resource by default.
# The provider block in providers.tf is configured unconditionally, and the
# real plugin rejects an empty configuration with "must provide exactly one of
# api_key, api_token or api_user_service_key" before it ever reaches the
# question of whether a resource uses it.
mock_provider "cloudflare" {}

run "backing_services_output_populated_on_k8s_backend" {
  command = plan

  assert {
    condition     = module.n8n.backing_services.postgres_host != ""
    error_message = "backing_services.postgres_host should be populated on the k8s backend; got empty string."
  }
}

run "postgres_host_names_cnpg_service" {
  command = plan

  # local.cnpg_service_host is "<release>-pg-rw.<namespace>.svc.cluster.local".
  # When postgres_backend = "cnpg" the backing-services output resolves to
  # that DNS name, so a substring match is enough to confirm the CNPG path.
  assert {
    condition     = can(regex("-pg-rw", module.n8n.backing_services.postgres_host))
    error_message = "backing_services.postgres_host should reference the CNPG rw Service DNS name when postgres_backend = \"cnpg\"; got: ${module.n8n.backing_services.postgres_host}"
  }
}

run "redis_host_names_valkey_service" {
  command = plan

  # local.valkey_host is "<release>-redis-valkey.<namespace>.svc.cluster.local".
  assert {
    condition     = can(regex("-redis-valkey", module.n8n.backing_services.redis_host))
    error_message = "backing_services.redis_host should reference the Valkey Service DNS name when redis_backend = \"valkey\"; got: ${coalesce(module.n8n.backing_services.redis_host, "<null>")}"
  }
}

# This run used to assert "filesystem" unconditionally, which passed against an
# output that was the constant "filesystem" and wrong on this very path: with no
# shared_storage_class there is no volume for the three pod types to share, so
# the module leaves n8n at its queue-mode default and payloads go to Postgres.
# The test encoded the bug rather than catching it. See issue #18.
run "binary_storage_is_database_without_a_shared_volume" {
  command = plan

  assert {
    condition     = module.n8n.backing_services.binary_storage == "database"
    error_message = "Without shared_storage_class there is no volume all three pod types can see, so binary data stays in Postgres and the output must say so. Got: ${module.n8n.backing_services.binary_storage}"
  }
}

# ponytail: whether a resource inside the module is planned (helm_release.valkey,
# helm_release.n8n) is not reachable from an `assert` block, because the harness
# exposes no planned-resource-set expression and a module's internal addresses
# are not in scope here. That coverage comes from the module's own
# tests/defaults.tftest.hcl (variable-contract assertions) plus a real
# `terraform plan` against a live cluster.
#
# A count-gated resource in this root is a different case and is assertable:
# `length(kubernetes_persistent_volume_claim_v1.shared)` is an ordinary
# expression over a resource this configuration declares, which is what the
# shared-storage runs below use.

run "no_shared_claim_without_a_class" {
  command = plan

  # Off by default: binary data stays in Postgres, which is n8n's own default in
  # queue mode. The example has to stay applicable on a cluster with no RWX
  # class, so the claim is opt-in rather than required.
  assert {
    condition     = length(kubernetes_persistent_volume_claim_v1.shared) == 0
    error_message = "No claim should be planned when shared_storage_class is null."
  }

  # The namespace is this example's on every path, shared storage or not, so
  # that turning shared storage on later cannot move it between two resource
  # addresses. See storage.tf for what that used to cost.
  assert {
    condition     = kubernetes_namespace.n8n.metadata[0].name == var.namespace
    error_message = "The example must own the namespace on every path, shared claim or not; its name should equal var.namespace."
  }
}

run "a_class_produces_one_rwx_claim" {
  command = plan

  variables {
    shared_storage_class = "nfs-csi"
  }

  assert {
    condition     = length(kubernetes_persistent_volume_claim_v1.shared) == 1
    error_message = "Expected exactly one shared claim."
  }

  # Membership rather than equality: access_modes is a set, and comparing a set
  # to a list literal fails on type before it ever compares contents.
  #
  # ReadWriteOnce would bind to one node and leave the other two pod types
  # unable to mount it, which is the failure this whole file exists to avoid.
  assert {
    condition = (
      contains(kubernetes_persistent_volume_claim_v1.shared[0].spec[0].access_modes, "ReadWriteMany") &&
      length(kubernetes_persistent_volume_claim_v1.shared[0].spec[0].access_modes) == 1
    )
    error_message = "The shared claim must be exactly ReadWriteMany; three pod types mount it."
  }

  # Same namespace resource as the run above, unconditional now, which is what
  # the claim needs to be created into before the release.
  assert {
    condition     = kubernetes_namespace.n8n.metadata[0].name == var.namespace
    error_message = "The example must own the namespace when it owns the claim; its name should equal var.namespace."
  }
}

run "shared_mount_path_must_be_absolute" {
  command = plan

  variables {
    shared_storage_class = "nfs-csi"
    shared_mount_path    = "opt/n8n-shared"
  }

  expect_failures = [var.shared_mount_path]
}

run "an_empty_storage_class_is_rejected" {
  command = plan

  variables {
    shared_storage_class = ""
  }

  # "" is not null, so it used to enable the claim and then set
  # storageClassName to "", which asks Kubernetes for no class at all rather
  # than for the default one. The claim sits Pending with nothing saying why.
  expect_failures = [var.shared_storage_class]
}

run "a_whitespace_padded_storage_class_is_rejected" {
  command = plan

  variables {
    shared_storage_class = " nfs-csi"
  }

  # The claim is created with the value as given, so a padded name asks for a
  # class no cluster has. Same Pending claim as the empty string, with a name
  # that looks right in the plan output.
  expect_failures = [var.shared_storage_class]
}

run "the_kubeconfig_path_is_quoted_for_the_shell" {
  command = plan

  variables {
    kubeconfig_path = "/home/me/my kube/config"
  }

  # smoke-test.sh evals this. Unquoted, the export took "/home/me/my" and left
  # "kube/config" as a stray word.
  assert {
    condition     = output.kubectl_config_command == "export KUBECONFIG=\"/home/me/my kube/config\""
    error_message = "kubectl_config_command must quote the path; got ${output.kubectl_config_command}."
  }
}

run "a_tilde_path_becomes_HOME_so_quoting_does_not_break_it" {
  command = plan

  # Tilde expansion does not happen inside quotes, so the default would have
  # become a literal ~ directory once the value was quoted.
  assert {
    condition     = output.kubectl_config_command == "export KUBECONFIG=\"$HOME/.kube/config\""
    error_message = "A leading ~/ must become $HOME/; got ${output.kubectl_config_command}."
  }
}

run "a_shell_metacharacter_in_the_kubeconfig_path_is_rejected" {
  command = plan

  variables {
    kubeconfig_path = "/tmp/$(id).kube"
  }

  expect_failures = [var.kubeconfig_path]
}

run "a_trailing_backslash_in_the_kubeconfig_path_is_rejected" {
  command = plan

  # Escapes the closing quote of the generated export, so smoke-test.sh evals
  # an unterminated command and silently skips it.
  variables {
    kubeconfig_path = "/home/me/kube/\\"
  }

  expect_failures = [var.kubeconfig_path]
}

run "an_empty_kubeconfig_path_is_rejected" {
  command = plan

  # abspath("") is the example directory, so the smoke test would export a
  # directory as KUBECONFIG. nullable = false stops null, not empty.
  variables {
    kubeconfig_path = ""
  }

  expect_failures = [var.kubeconfig_path]
}

run "a_posix_backslash_is_a_filename_character_not_a_separator" {
  command = plan

  # Normalising unconditionally pointed the smoke test at /tmp/kube/config
  # while the providers opened this file. Only a drive-qualified path gets its
  # separators rewritten; everything else keeps its backslashes and has them
  # escaped, because the shell collapses a backslash pair inside the double
  # quotes smoke-test.sh evals. Escaped, eval reproduces the literal.
  variables {
    kubeconfig_path = "/tmp/kube\\config"
  }

  assert {
    condition     = output.kubectl_config_command == "export KUBECONFIG=\"/tmp/kube\\\\config\""
    error_message = "A backslash in a POSIX path must survive; got ${output.kubectl_config_command}."
  }
}

run "a_windows_unc_path_survives_the_shell_eval" {
  command = plan

  # Absolute, so abspath must not touch it, and its separators are backslashes
  # that the eval would otherwise collapse in pairs. Escaped, the shell hands
  # kubectl back the path that was configured.
  variables {
    kubeconfig_path = "\\\\server\\share\\config"
  }

  assert {
    condition     = output.kubectl_config_command == "export KUBECONFIG=\"\\\\\\\\server\\\\share\\\\config\""
    error_message = "A UNC path must survive the eval intact; got ${output.kubectl_config_command}."
  }
}

run "a_drive_relative_windows_path_is_resolved_not_passed_through" {
  command = plan

  # "C:config" names a path against the current directory of drive C, not its
  # root, so it is relative. Asserted as "not passed through unchanged" rather
  # than against a literal, because what abspath resolves it to depends on
  # where the test runs.
  variables {
    kubeconfig_path = "C:config"
  }

  assert {
    condition     = output.kubectl_config_command != "export KUBECONFIG=\"C:config\""
    error_message = "A drive-relative path must be resolved, not treated as absolute; got ${output.kubectl_config_command}."
  }
}
