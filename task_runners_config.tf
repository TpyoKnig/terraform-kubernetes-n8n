# Copyright (c) 2026 TpyoKnig
# SPDX-License-Identifier: MIT

# ── Task runner allowlist ─────────────────────────────────────────────────────
# The n8nio/runners image ships a launcher config whose defaults are
# N8N_RUNNERS_STDLIB_ALLOW="" and N8N_RUNNERS_EXTERNAL_ALLOW="", which blocks
# every Python import, stdlib like time / math included. The chart does not set
# those; it mounts whatever config it is pointed at, and with no
# taskRunners.customConfig it leaves the image's own file in place.
#
# For a k8s-backend default the Python task runner should be usable out of the
# box, so this ConfigMap supplies a config permitting stdlib and, optionally,
# external packages via var.n8n_python_external_allow.
#
# Chart 1.17.0 is what n8n_chart_version pins and what this file is written
# against: it declares taskRunners.customConfig (values.yaml:144-149) and mounts
# the named ConfigMap at /etc/n8n-task-runners.json (deployment-main.yaml).
#
# Standing risk: this mounted config REPLACES the runners image's own
# launcher config wholesale, including command, args and interpreter paths
# (/usr/local/bin/node, /opt/runners/task-runner-python/.venv/bin/python)
# that belong to that image, not to this module. A runners-image release
# that moves any of those paths breaks both the JavaScript and Python
# runners at once, silently, because the mounted config wins over whatever
# the image ships. See docs/upgrading-n8n.md for the pre-bump step that
# catches this before it reaches a cluster.

locals {
  # N8N_RUNNERS_MAX_CONCURRENCY, or nothing at all. The chart has no typed value
  # for it, so it goes in the env-overrides block of this ConfigMap. That is the
  # correct place regardless: the runner process reads it (BaseRunnerConfig for
  # JavaScript, TaskRunnerConfig for Python), not n8n, so config.extraEnv would
  # put it on containers that never look at it.
  #
  # Not the only possible place: the chart also has taskRunners.extraEnv,
  # rendered into the sidecar by the taskRunnerSidecarEnv define in
  # _configmap-env.tpl, which would reach the sidecar's environment too. This
  # stays in the ConfigMap because the launcher's own config file is where the
  # runner's settings belong and the module already renders one, not because
  # the chart offers no alternative.
  #
  # Omitted entirely when null, rather than defaulted to a number here, because
  # the two runners disagree about the default: 10 for JavaScript, 5 for
  # Python. Any value this module picked would silently move one of them.
  #
  # Stringified because these are environment variables. The other overrides in
  # both blocks are strings, so an un-stringified number would be converted by
  # type unification anyway; doing it here keeps that visible rather than
  # incidental.
  task_runner_concurrency_override = var.n8n_task_runner_max_concurrency == null ? {} : {
    N8N_RUNNERS_MAX_CONCURRENCY = tostring(var.n8n_task_runner_max_concurrency)
  }
}

resource "kubernetes_config_map_v1" "task_runners_config" {
  count = var.n8n_task_runners_enabled ? 1 : 0

  metadata {
    name      = "${local.cnpg_release_name}-task-runners"
    namespace = local.namespace_name
  }

  data = {
    "n8n-task-runners.json" = jsonencode({
      task-runners = [
        {
          runner-type = "javascript"
          workdir     = "/home/runner"
          command     = "/usr/local/bin/node"
          args = [
            "--disallow-code-generation-from-strings",
            "--disable-proto=delete",
            "/opt/runners/task-runner-javascript/dist/start.js",
          ]
          health-check-server-port = "5681"
          allowed-env = [
            "PATH", "GENERIC_TIMEZONE", "NODE_OPTIONS", "NODE_PATH",
            "N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT",
            "N8N_RUNNERS_TASK_TIMEOUT",
            "N8N_RUNNERS_MAX_CONCURRENCY",
            "N8N_SENTRY_DSN", "N8N_VERSION",
            "ENVIRONMENT", "DEPLOYMENT_NAME", "HOME",
          ]
          env-overrides = merge({
            NODE_FUNCTION_ALLOW_BUILTIN          = var.n8n_js_builtin_allow
            NODE_FUNCTION_ALLOW_EXTERNAL         = var.n8n_js_external_allow
            N8N_RUNNERS_HEALTH_CHECK_SERVER_HOST = "0.0.0.0"
          }, local.task_runner_concurrency_override)
        },
        {
          runner-type              = "python"
          workdir                  = "/home/runner"
          command                  = "/opt/runners/task-runner-python/.venv/bin/python"
          args                     = ["-I", "-B", "-X", "disable_remote_debug", "-m", "src.main"]
          health-check-server-port = "5682"
          allowed-env = [
            "PATH",
            "N8N_RUNNERS_LAUNCHER_LOG_LEVEL",
            "N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT",
            "N8N_RUNNERS_TASK_TIMEOUT",
            "N8N_RUNNERS_MAX_CONCURRENCY",
            "N8N_SENTRY_DSN", "N8N_VERSION",
            "ENVIRONMENT", "DEPLOYMENT_NAME",
          ]
          env-overrides = merge({
            N8N_RUNNERS_STDLIB_ALLOW   = var.n8n_python_stdlib_allow
            N8N_RUNNERS_EXTERNAL_ALLOW = var.n8n_python_external_allow
          }, local.task_runner_concurrency_override)
        },
      ]
    })
  }

  depends_on = [kubernetes_namespace_v1.n8n]
}
