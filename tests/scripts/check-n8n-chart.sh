#!/usr/bin/env bash
# check-n8n-chart.sh: render this module's own values tree through the
# pinned n8n Helm chart, offline.
#
# terraform test (tests/defaults.tftest.hcl) runs against the mocked
# providers, so it can pin the SHAPE of local.k8s_values_final at plan time,
# but it never calls Helm: helm_release.values is unknown under plan-time
# mocks (AGENTS.md), so nothing in the mocked suite can say whether the real
# chart actually does what the module's values ask for. This script closes
# that gap without a cluster: `terraform console` evaluates the real locals
# against an empty, throwaway state, and `helm template`/`helm pull` render
# the real chart from the result.
#
# Requires: terraform (initialized with `terraform init -backend=false` at
# the module root first), helm, jq, openssl (used to generate a throwaway
# CA certificate for the postgres TLS scenario). No cluster, no credentials,
# no plan or apply.
#
# Usage: tests/scripts/check-n8n-chart.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

for tool in terraform helm jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool missing: $tool" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1" >&2
  FAIL=1
}

# A fixed, valid 64-hex-char key, exactly the shape
# random_id.n8n_encryption_key (byte_length = 32) always produces, so the
# console evaluates local.k8s_values_final without needing that resource to
# exist in state.
FAKE_KEY="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

console() {
  # grep -v blank | tail -1: the kubernetes provider can emit a deprecation
  # warning to stdout ahead of the actual result (AGENTS.md documents why
  # this module still uses the unversioned kubernetes_namespace resource).
  # terraform console has no flag to suppress or redirect warnings away from
  # stdout, and every expression evaluated here is a single-line
  # jsonencode(...)/string result, so the last non-blank line is always the
  # real value regardless of how many warning blocks precede it.
  terraform console -no-color -state="$tmp/terraform.tfstate" \
    -var='n8n_domain=n8n.test.example.com' \
    -var="n8n_encryption_key=$FAKE_KEY" \
    -var='postgres_backend=external' -var='db_host=db.test.example.com' -var='db_password=test' \
    -var='redis_backend=external' -var='redis_host=redis.test.example.com' \
    "$@" | grep -v '^[[:space:]]*$' | tail -1
}

# $1: output file, $2+: extra -var args. Writes this module's real
# local.k8s_values_final to $1 as JSON.
# console prints an expression's HCL representation, so a string result comes
# back double-quoted and escaped (it's printing the JSON text AS a string
# literal). jq -r . unwraps that one layer, leaving the real JSON.
render_values() {
  local out="$1"
  shift
  # shellcheck disable=SC2068 # intentional word-splitting of the caller's -var args
  console $@ <<<'nonsensitive(jsonencode(local.k8s_values_final))' | jq -r . >"$out"
}

# $1: a rendered YAML manifest file -> prints it as JSON. Needs no YAML
# parser of its own: terraform's own yamldecode does the work. Same
# double-quoting as render_values above.
yaml_to_json() {
  console <<<"jsonencode(yamldecode(file(\"$1\")))" | jq -r .
}

chart_version=$(console <<<'var.n8n_chart_version' | tr -d '"')
chart_repository=$(console <<<'var.n8n_chart_repository' | tr -d '"')
# helm pull takes a bare <repo>/<chart> reference only for OCI registries; an
# https:// chart repository would need `--repo <url> n8n` instead.
# n8n_chart_repository accepts both schemes (chart-values-diff.sh documents
# and enforces the same split), so fail clearly here too rather than let helm
# produce a confusing raw error if the default ever moves to an https mirror.
case "$chart_repository" in
  oci://*) ;;
  *)
    echo "check-n8n-chart.sh only supports oci:// chart repositories; n8n_chart_repository's default is $chart_repository" >&2
    exit 1
    ;;
esac
helm pull "$chart_repository/n8n" --version "$chart_version" --untar --untardir "$tmp"
chart_dir="$tmp/n8n"

app_version=$(sed -n 's/^appVersion:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' "$chart_dir/Chart.yaml" | head -1)
echo "Chart $chart_version, appVersion $app_version" >&2

# The chart's appVersion (2.44.5) is a number several comments and docs cite
# as "what an unset n8n_image_tag resolves to". n8n_image_tag's own default
# is pinned separately and may sit above or below it. A chart bump that moves
# appVersion needs those citations reviewed, not auto-updated.
[[ "$app_version" == "2.44.5" ]] ||
  fail "chart $chart_version ships appVersion=$app_version, expected 2.44.5; review every comment/doc citing 2.44.5"

# ── PDB: chart 1.16.0 gates templates/pdb.yaml on main running more than one
# replica (n8n-io/n8n-hosting#228). This module always sets replicaCount = 1
# and hpa.main.enabled = false (n8n.tf / locals.tf), so the object must not
# render even when n8n_main_pdb_enabled = true asks for it. See the comment
# in n8n.tf where the check that used to warn about this used to live.
render_values "$tmp/values-default.json"
jq -e '.pdb.enabled == false and .replicaCount == 1 and .hpa.main.enabled == false' "$tmp/values-default.json" >/dev/null ||
  fail "default values tree is not this test's assumed shape (pdb off, replicaCount 1, hpa.main off); re-check the scenario before trusting the PDB assertion below"

render_values "$tmp/values-pdb.json" -var=n8n_main_pdb_enabled=true
helm template n8n "$chart_dir" -f "$tmp/values-pdb.json" --set secretRefs.existingSecret=test-core >"$tmp/all-pdb.yaml"
if grep -q '^kind: PodDisruptionBudget$' "$tmp/all-pdb.yaml"; then
  fail "n8n_main_pdb_enabled = true rendered a PodDisruptionBudget on chart $chart_version against this module's single-replica main; the chart's render gate changed, docs/helm-chart-coverage.md and the n8n.tf comment need to catch up"
else
  pass "chart $chart_version renders no PodDisruptionBudget for this module's single-replica main even with n8n_main_pdb_enabled = true"
fi

# ── Worker health probes: chart 1.17.0 switched redis.healthCheck.enabled's
# default from false to true and the worker's readiness/liveness probes from
# an always-passing `pgrep -f 'n8n worker'` exec check to real httpGet probes
# against the worker's own /healthz and /healthz/readiness endpoints
# (n8n-io/n8n-hosting#233). This module sets neither redis.healthCheck nor
# probes.worker, so every deployment inherits the new default on this bump:
# QUEUE_HEALTH_CHECK_ACTIVE now reaches the worker container, and readiness
# gates on the worker's own DB/Redis connection instead of the process merely
# existing. See CHANGELOG and docs/upgrading-n8n.md.
helm template n8n "$chart_dir" -f "$tmp/values-default.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-worker.yaml >"$tmp/deployment-worker-probes.yaml"
yaml_to_json "$tmp/deployment-worker-probes.yaml" >"$tmp/deployment-worker-probes.json"

if jq -e '[.spec.template.spec.containers[] | select(.name == "n8n-worker") | .env[]? | select(.name == "QUEUE_HEALTH_CHECK_ACTIVE") | .value] == ["true"]' \
  "$tmp/deployment-worker-probes.json" >/dev/null; then
  pass "chart $chart_version enables QUEUE_HEALTH_CHECK_ACTIVE on the worker by default"
else
  fail "chart $chart_version did not set QUEUE_HEALTH_CHECK_ACTIVE=true on the worker by default; redis.healthCheck.enabled's default may have reverted"
fi

if jq -e '.spec.template.spec.containers[] | select(.name == "n8n-worker") | .readinessProbe.httpGet.path == "/healthz/readiness"' \
  "$tmp/deployment-worker-probes.json" >/dev/null; then
  pass "chart $chart_version renders an httpGet readiness probe on /healthz/readiness for the worker"
else
  fail "chart $chart_version did not render the worker's readinessProbe as httpGet /healthz/readiness; the probe may have reverted to the always-passing pgrep exec check"
fi

if jq -e '.spec.template.spec.containers[] | select(.name == "n8n-worker") | .livenessProbe.httpGet.path == "/healthz"' \
  "$tmp/deployment-worker-probes.json" >/dev/null; then
  pass "chart $chart_version renders an httpGet liveness probe on /healthz for the worker"
else
  fail "chart $chart_version did not render the worker's livenessProbe as httpGet /healthz; the probe may have reverted to the always-passing pgrep exec check"
fi

if jq -e '.spec.template.spec.containers[] | select(.name == "n8n-worker") | .startupProbe.httpGet.path == "/healthz"' \
  "$tmp/deployment-worker-probes.json" >/dev/null; then
  pass "chart $chart_version renders a startup probe on /healthz for the worker, holding off liveness during migrations"
else
  fail "chart $chart_version did not render a worker startupProbe; the migration-startup grace window this module now relies on may be gone"
fi

# ── Task runner sidecar: chart 1.16.0 only adds the runner sidecar to main
# pods in standalone mode (n8n.mainTaskRunnersEnabled). This module
# hardcodes queueMode.enabled = true always, so with task runners on, main
# must carry no "task-runner" container and worker must carry one.
render_values "$tmp/values-runners.json" -var=n8n_task_runners_enabled=true -var=k8s_keda_installed=false
jq -e '.taskRunners.enabled == true and .queueMode.enabled == true' "$tmp/values-runners.json" >/dev/null ||
  fail "task-runner scenario did not render taskRunners.enabled/queueMode.enabled as expected; re-check before trusting the sidecar assertion below"

helm template n8n "$chart_dir" -f "$tmp/values-runners.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-main.yaml >"$tmp/deployment-main.yaml"
yaml_to_json "$tmp/deployment-main.yaml" >"$tmp/deployment-main.json"
helm template n8n "$chart_dir" -f "$tmp/values-runners.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-worker.yaml >"$tmp/deployment-worker.yaml"
yaml_to_json "$tmp/deployment-worker.yaml" >"$tmp/deployment-worker.json"

if jq -e '[.spec.template.spec.containers[].name] | index("task-runner") == null' "$tmp/deployment-main.json" >/dev/null; then
  pass "chart $chart_version carries no task-runner sidecar on the main Deployment in this module's always-on queue mode"
else
  fail "chart $chart_version rendered a task-runner sidecar on the main Deployment; n8n_task_runner_image_tag's description and the ImagePullBackOff check messages in n8n.tf and variables.tf say main never gets one in queue mode"
fi

if jq -e '[.spec.template.spec.containers[].name] | index("task-runner") != null' "$tmp/deployment-worker.json" >/dev/null; then
  pass "chart $chart_version still carries the task-runner sidecar on the worker Deployment"
else
  fail "chart $chart_version rendered no task-runner sidecar on the worker Deployment; the worker is where this module's task runner support now has to live"
fi

# ── Worker replicas: chart >= 1.13.0 (n8n-io/n8n-hosting#201) omits
# spec.replicas on the worker Deployment once an autoscaler owns the count
# (KEDA with real triggers, or the CPU HPA while KEDA is off). This module's
# worker always satisfies one of the two, so every real deployment hits this:
# the first `helm upgrade` onto this chart version resets the live replica
# count to Kubernetes' own default of 1 until the autoscaler restores the
# floor. See the CHANGELOG and docs/upgrading-n8n.md entries for this bump.
render_values "$tmp/values-keda.json" -var=k8s_keda_installed=true
helm template n8n "$chart_dir" -f "$tmp/values-keda.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-worker.yaml >"$tmp/deployment-worker-keda.yaml"
yaml_to_json "$tmp/deployment-worker-keda.yaml" >"$tmp/deployment-worker-keda.json"
if jq -e '.spec | has("replicas") | not' "$tmp/deployment-worker-keda.json" >/dev/null; then
  pass "chart $chart_version omits spec.replicas on the worker Deployment with KEDA real triggers (k8s_keda_installed = true)"
else
  fail "chart $chart_version still renders spec.replicas on the worker Deployment with KEDA real triggers; the one-time replica-reset note in the CHANGELOG no longer applies on this path and should be revisited"
fi

render_values "$tmp/values-hpa.json" -var=k8s_keda_installed=false
helm template n8n "$chart_dir" -f "$tmp/values-hpa.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-worker.yaml >"$tmp/deployment-worker-hpa.yaml"
yaml_to_json "$tmp/deployment-worker-hpa.yaml" >"$tmp/deployment-worker-hpa.json"
if jq -e '.spec | has("replicas") | not' "$tmp/deployment-worker-hpa.json" >/dev/null; then
  pass "chart $chart_version also omits spec.replicas on the worker Deployment on the CPU-HPA path (k8s_keda_installed = false)"
else
  fail "chart $chart_version renders spec.replicas on the worker Deployment on the CPU-HPA path; the one-time replica-reset note may not apply as broadly as the CHANGELOG says"
fi

# ── Image tag: before chart 1.12.0, an unset image.tag rendered the floating
# `stable`; from 1.12.0 on it resolves to the chart's own appVersion instead.
# n8n_image_tag defaults to this module's own pin (2.44.5), not null, so this
# scenario explicitly hands the choice back to the chart. A tfvars file,
# not -var: the CLI's -var flag parses "null" as the literal string "null"
# for a string-typed variable, not HCL null, so it never actually unsets the
# key the way a real caller's tfvars assignment would.
echo 'n8n_image_tag = null' >"$tmp/null-tag.auto.tfvars"
render_values "$tmp/values-null-tag.json" -var-file="$tmp/null-tag.auto.tfvars"
rm -f "$tmp/null-tag.auto.tfvars"
jq -e 'has("image") and (.image | has("tag") | not)' "$tmp/values-null-tag.json" >/dev/null ||
  fail "n8n_image_tag = null did not omit image.tag from the values tree; re-check before trusting the appVersion assertion below"
helm template n8n "$chart_dir" -f "$tmp/values-null-tag.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-main.yaml >"$tmp/deployment-main-null-tag.yaml"
yaml_to_json "$tmp/deployment-main-null-tag.yaml" >"$tmp/deployment-main-null-tag.json"
deployed_image=$(jq -r '.spec.template.spec.containers[] | select(.name == "n8n-main") | .image' "$tmp/deployment-main-null-tag.json")
if [[ "$deployed_image" == *":$app_version" ]]; then
  pass "chart $chart_version resolves n8n_image_tag = null to appVersion $app_version, not \`stable\`"
else
  fail "expected the main container's image to end in :$app_version with n8n_image_tag = null; got $deployed_image"
fi

# ── N8N_WEBHOOK_URL: chart 1.16.0 renamed the chart-rendered env var and
# ConfigMap key from WEBHOOK_URL to N8N_WEBHOOK_URL (n8n deprecated
# WEBHOOK_URL as of n8n 2.35.0). This module's reserved-name list and its
# split-ingress extraEnv injection both moved to the new name; this proves
# the chart side of that rename against the real template.
render_values "$tmp/values-webhook.json" \
  -var=n8n_webhook_url=https://hooks.test.example.com \
  -var=create_ingress=true -var=k8s_ingress_cluster_issuer=letsencrypt-prod
helm template n8n "$chart_dir" -f "$tmp/values-webhook.json" --set secretRefs.existingSecret=test-core >"$tmp/all-webhook.yaml"
if grep -q 'name: N8N_WEBHOOK_URL' "$tmp/all-webhook.yaml" && ! grep -q '^\s*- name: WEBHOOK_URL$' "$tmp/all-webhook.yaml"; then
  pass "chart $chart_version renders N8N_WEBHOOK_URL, not the deprecated WEBHOOK_URL"
else
  fail "expected chart $chart_version to render N8N_WEBHOOK_URL only; this module's reserved-name list and split-ingress extraEnv injection assume that rename"
fi

# ── /mcp routing: chart 1.16.0 added /mcp/ to the chart's own webhook
# Ingress, which is why kubernetes_ingress_v1.n8n_mcp was removed from
# n8n.tf. If a future chart version drops it again, this is the canary.
render_values "$tmp/values-ingress.json" -var=create_ingress=true -var=k8s_ingress_cluster_issuer=letsencrypt-prod
helm template n8n "$chart_dir" -f "$tmp/values-ingress.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/ingress-webhook.yaml >"$tmp/ingress-webhook.yaml"
if grep -q '/mcp' "$tmp/ingress-webhook.yaml"; then
  pass "chart $chart_version's own webhook Ingress still routes /mcp"
else
  fail "chart $chart_version's webhook Ingress no longer routes /mcp; n8n.tf needs its supplementary Ingress back for this prefix (see locals.tf n8n_webhook_path_prefixes and its history comment)"
fi

# ── Extra CA bundle (n8n_extra_ca_pem): the chart's extraVolumes/
# extraVolumeMounts/podAnnotations carry the module's ca-bundle Secret volume,
# its read-only mount at /etc/n8n-certs/ca-bundle.crt, and the
# checksum/extra-ca pod annotation onto main and worker (webhook-processor
# shares the worker's container spec helper, so worker stands in for both).
# The task runner sidecar on the worker pod must NOT get the mount or the env
# var: it is a separate container the chart does not extend extraVolumeMounts
# or config.extraEnv to.
cat >"$tmp/ca-pem.auto.tfvars" <<'EOT'
n8n_extra_ca_pem = <<-PEM
-----BEGIN CERTIFICATE-----
MIIBtest1234567890aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-----END CERTIFICATE-----
PEM
EOT
render_values "$tmp/values-ca-pem.json" -var-file="$tmp/ca-pem.auto.tfvars" -var=n8n_task_runners_enabled=true -var=k8s_keda_installed=false
rm -f "$tmp/ca-pem.auto.tfvars"
jq -e '.extraVolumes[0].name == "ca-bundle" and .extraVolumeMounts[0].mountPath == "/etc/n8n-certs/ca-bundle.crt" and .podAnnotations."checksum/extra-ca"' "$tmp/values-ca-pem.json" >/dev/null ||
  fail "n8n_extra_ca_pem did not render the expected extraVolumes/extraVolumeMounts/podAnnotations shape; re-check before trusting the chart-render assertions below"

helm template n8n "$chart_dir" -f "$tmp/values-ca-pem.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-main.yaml >"$tmp/deployment-main-ca.yaml"
yaml_to_json "$tmp/deployment-main-ca.yaml" >"$tmp/deployment-main-ca.json"
helm template n8n "$chart_dir" -f "$tmp/values-ca-pem.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-worker.yaml >"$tmp/deployment-worker-ca.yaml"
yaml_to_json "$tmp/deployment-worker-ca.yaml" >"$tmp/deployment-worker-ca.json"

for role in main worker; do
  f="$tmp/deployment-$role-ca.json"
  container="n8n-$role"
  if jq -e '.spec.template.spec.volumes[] | select(.name == "ca-bundle") | .secret.secretName == "n8n-ca-bundle-secret"' "$f" >/dev/null; then
    pass "chart $chart_version mounts the ca-bundle Secret on the $role pod"
  else
    fail "chart $chart_version does not carry a ca-bundle volume on the $role pod"
  fi

  if jq -e --arg c "$container" '.spec.template.spec.containers[] | select(.name == $c) | .volumeMounts[] | select(.mountPath == "/etc/n8n-certs/ca-bundle.crt" and .readOnly == true)' "$f" >/dev/null; then
    pass "chart $chart_version mounts the bundle read-only on the $role pod's $container container"
  else
    fail "chart $chart_version does not mount the ca-bundle read-only on the $role pod's $container container"
  fi

  if jq -e --arg c "$container" '.spec.template.spec.containers[] | select(.name == $c) | .env[] | select(.name == "NODE_EXTRA_CA_CERTS" and .value == "/etc/n8n-certs/ca-bundle.crt")' "$f" >/dev/null; then
    pass "chart $chart_version sets NODE_EXTRA_CA_CERTS on the $role pod's $container container"
  else
    fail "chart $chart_version does not set NODE_EXTRA_CA_CERTS on the $role pod's $container container"
  fi

  if jq -e '.spec.template.metadata.annotations."checksum/extra-ca" != null' "$f" >/dev/null; then
    pass "chart $chart_version carries the checksum/extra-ca pod annotation on the $role pod"
  else
    fail "chart $chart_version is missing the checksum/extra-ca pod annotation on the $role pod"
  fi
done

if jq -e '[.spec.template.spec.containers[] | select(.name == "task-runner") | .volumeMounts[]? | select(.mountPath == "/etc/n8n-certs/ca-bundle.crt")] | length == 0' "$tmp/deployment-worker-ca.json" >/dev/null; then
  pass "chart $chart_version does not mount the ca-bundle into the task-runner sidecar"
else
  fail "chart $chart_version mounted the ca-bundle into the task-runner sidecar; n8n_extra_ca_pem's description promises it does not reach that container"
fi

if jq -e '[.spec.template.spec.containers[] | select(.name == "task-runner") | .env[]? | select(.name == "NODE_EXTRA_CA_CERTS")] | length == 0' "$tmp/deployment-worker-ca.json" >/dev/null; then
  pass "chart $chart_version does not set NODE_EXTRA_CA_CERTS on the task-runner sidecar"
else
  fail "chart $chart_version set NODE_EXTRA_CA_CERTS on the task-runner sidecar; n8n_extra_ca_pem's description promises it does not reach that container"
fi

# ── Postgres TLS CA: chart 1.16.0 renders database.ssl.ca into
# DB_POSTGRESDB_SSL_CA only while database.ssl.enabled, and this module's own
# config.extraEnv also carries DB_POSTGRESDB_SSL_ENABLED whenever
# db_postgresdb_ssl_enabled is set. Two entries of the same env name is the
# failure that once broke every helm upgrade (locals.tf), so this proves
# against the real chart that exactly one DB_POSTGRESDB_SSL_ENABLED and one
# DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED reach the main Deployment once a CA is
# active, alongside the CA itself.
ca_pem=$(openssl req -x509 -newkey rsa:2048 -keyout /dev/null -nodes \
  -subj "/CN=n8n-pg-ca-test" -days 1 2>/dev/null)
cat >"$tmp/ca.auto.tfvars" <<EOF
db_postgresdb_ssl_reject_unauthorized = true
db_postgresdb_ssl_ca_pem = <<-CAEOT
${ca_pem}
CAEOT
EOF
render_values "$tmp/values-ca.json" -var-file="$tmp/ca.auto.tfvars"
rm -f "$tmp/ca.auto.tfvars"
jq -e '.database.ssl.enabled == true and .database.ssl.rejectUnauthorized == true and (.database.ssl.ca | length) > 0' "$tmp/values-ca.json" >/dev/null ||
  fail "db_postgresdb_ssl_ca_pem did not render database.ssl.enabled/.rejectUnauthorized/.ca as expected; re-check before trusting the duplicate-env assertion below"

helm template n8n "$chart_dir" -f "$tmp/values-ca.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-main.yaml >"$tmp/deployment-main-ca.yaml"
yaml_to_json "$tmp/deployment-main-ca.yaml" >"$tmp/deployment-main-ca.json"

enabled_count=$(jq '[.spec.template.spec.containers[] | select(.name == "n8n-main") | .env[]? | select(.name == "DB_POSTGRESDB_SSL_ENABLED")] | length' "$tmp/deployment-main-ca.json")
reject_count=$(jq '[.spec.template.spec.containers[] | select(.name == "n8n-main") | .env[]? | select(.name == "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED")] | length' "$tmp/deployment-main-ca.json")
ca_count=$(jq '[.spec.template.spec.containers[] | select(.name == "n8n-main") | .env[]? | select(.name == "DB_POSTGRESDB_SSL_CA")] | length' "$tmp/deployment-main-ca.json")

if [[ "$enabled_count" -eq 1 ]]; then
  pass "chart $chart_version renders exactly one DB_POSTGRESDB_SSL_ENABLED on the main Deployment with a CA active"
else
  fail "chart $chart_version rendered $enabled_count DB_POSTGRESDB_SSL_ENABLED entries on the main Deployment with a CA active, expected exactly 1; the collision-avoidance in locals.tf (local.n8n_chart_renders_postgres_ssl_enabled) needs review"
fi

if [[ "$reject_count" -eq 1 ]]; then
  pass "chart $chart_version renders exactly one DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED on the main Deployment with a CA active"
else
  fail "chart $chart_version rendered $reject_count DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED entries on the main Deployment with a CA active, expected exactly 1"
fi

if [[ "$ca_count" -eq 1 ]]; then
  pass "chart $chart_version renders DB_POSTGRESDB_SSL_CA on the main Deployment"
else
  fail "chart $chart_version rendered $ca_count DB_POSTGRESDB_SSL_CA entries on the main Deployment, expected exactly 1"
fi

# ── n8n_node_max_old_space_size_mb: config.extraEnv is a path other inputs
# already exercise, so this proves the chart accepts the specific NODE_OPTIONS
# shape this module emits rather than merely that the path exists.
render_values "$tmp/values-heap.json" -var=n8n_node_max_old_space_size_mb=3072
helm template n8n "$chart_dir" -f "$tmp/values-heap.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-main.yaml >"$tmp/deployment-main-heap.yaml"
yaml_to_json "$tmp/deployment-main-heap.yaml" >"$tmp/deployment-main-heap.json"
if jq -e '[.spec.template.spec.containers[] | select(.name == "n8n-main") | .env[] | select(.name == "NODE_OPTIONS") | .value] == ["--max-old-space-size=3072"]' \
  "$tmp/deployment-main-heap.json" >/dev/null; then
  pass "chart $chart_version renders NODE_OPTIONS=--max-old-space-size=3072 on the n8n container from n8n_node_max_old_space_size_mb"
else
  fail "chart $chart_version did not render NODE_OPTIONS as expected from n8n_node_max_old_space_size_mb"
fi

# ── n8n_credentials_overwrite_secret_ref: proves the module's Secret-backed
# volume, mount and CREDENTIALS_OVERWRITE_DATA_FILE entry all render together
# against the real chart.
render_values "$tmp/values-credentials-overwrite.json" \
  -var='n8n_credentials_overwrite_secret_ref={"name":"n8n-credentials-overwrite"}'
helm template n8n "$chart_dir" -f "$tmp/values-credentials-overwrite.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-main.yaml >"$tmp/deployment-main-credentials-overwrite.yaml"
yaml_to_json "$tmp/deployment-main-credentials-overwrite.yaml" >"$tmp/deployment-main-credentials-overwrite.json"

if jq -e '[.spec.template.spec.volumes[] | select(.name == "credentials-overwrite") | .secret.secretName] == ["n8n-credentials-overwrite"]' \
  "$tmp/deployment-main-credentials-overwrite.json" >/dev/null; then
  pass "chart $chart_version renders the credentials-overwrite Secret volume from n8n_credentials_overwrite_secret_ref"
else
  fail "chart $chart_version did not render the credentials-overwrite volume as expected"
fi

if jq -e '[.spec.template.spec.containers[] | select(.name == "n8n-main") | .volumeMounts[] | select(.name == "credentials-overwrite") | .mountPath] == ["/etc/n8n/credentials-overwrite"]' \
  "$tmp/deployment-main-credentials-overwrite.json" >/dev/null; then
  pass "chart $chart_version mounts the credentials-overwrite volume at /etc/n8n/credentials-overwrite on the n8n container"
else
  fail "chart $chart_version did not mount the credentials-overwrite volume as expected"
fi

if jq -e '[.spec.template.spec.containers[] | select(.name == "n8n-main") | .env[] | select(.name == "CREDENTIALS_OVERWRITE_DATA_FILE") | .value] == ["/etc/n8n/credentials-overwrite/credentials-overwrite.json"]' \
  "$tmp/deployment-main-credentials-overwrite.json" >/dev/null; then
  pass "chart $chart_version renders CREDENTIALS_OVERWRITE_DATA_FILE pointing at the mounted file"
else
  fail "chart $chart_version did not render CREDENTIALS_OVERWRITE_DATA_FILE as expected"
fi

# ── n8n_dns_config: proves the chart's top-level dnsConfig accepts the shape
# this module emits.
render_values "$tmp/values-dns.json" -var='n8n_dns_config={"options":[{"name":"ndots","value":"1"}]}'
helm template n8n "$chart_dir" -f "$tmp/values-dns.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-main.yaml >"$tmp/deployment-main-dns.yaml"
yaml_to_json "$tmp/deployment-main-dns.yaml" >"$tmp/deployment-main-dns.json"
if jq -e '.spec.template.spec.dnsConfig.options == [{"name":"ndots","value":"1"}]' "$tmp/deployment-main-dns.json" >/dev/null; then
  pass "chart $chart_version renders dnsConfig.options from n8n_dns_config on the main pod spec"
else
  fail "chart $chart_version did not render dnsConfig as expected from n8n_dns_config"
fi

# ── Worker concurrency vs N8N_CONCURRENCY_PRODUCTION_LIMIT: productionLimit
# defaults to -1 (unset), which n8n's worker.ts reads as "use my own
# --concurrency flag", so at defaults the worker Deployment carries
# --concurrency=<n8n_worker_concurrency> and no N8N_CONCURRENCY_PRODUCTION_LIMIT
# env var at all. Any other value overrides that same worker's own flag with
# that number, independently on every worker, not as a shared cap; this
# input's default used to be 100, which let whichever worker was already
# running absorb a burst before queue depth ever crossed the threshold that
# would make a KEDA-scaled worker pool add useful capacity (live finding,
# see CHANGELOG). Reuses values-default.json from the PDB scenario above.
helm template n8n "$chart_dir" -f "$tmp/values-default.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-worker.yaml >"$tmp/deployment-worker-concurrency-default.yaml"
yaml_to_json "$tmp/deployment-worker-concurrency-default.yaml" >"$tmp/deployment-worker-concurrency-default.json"

if jq -e '[.spec.template.spec.containers[] | select(.name == "n8n-worker") | .args[]?] | any(. == "--concurrency=10")' \
  "$tmp/deployment-worker-concurrency-default.json" >/dev/null; then
  pass "chart $chart_version renders --concurrency=10 on the worker container from the n8n_worker_concurrency default"
else
  fail "chart $chart_version did not render --concurrency=10 on the worker container at defaults"
fi

if jq -e '[.spec.template.spec.containers[] | select(.name == "n8n-worker") | .env[]? | select(.name == "N8N_CONCURRENCY_PRODUCTION_LIMIT")] | length == 0' \
  "$tmp/deployment-worker-concurrency-default.json" >/dev/null; then
  pass "chart $chart_version renders no N8N_CONCURRENCY_PRODUCTION_LIMIT on the worker at the default n8n_execution_concurrency_limit = -1"
else
  fail "chart $chart_version rendered N8N_CONCURRENCY_PRODUCTION_LIMIT on the worker at the default -1; the worker's own --concurrency flag would no longer be what governs"
fi

render_values "$tmp/values-concurrency-limit.json" -var=n8n_execution_concurrency_limit=50
helm template n8n "$chart_dir" -f "$tmp/values-concurrency-limit.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-worker.yaml >"$tmp/deployment-worker-concurrency-limit.yaml"
yaml_to_json "$tmp/deployment-worker-concurrency-limit.yaml" >"$tmp/deployment-worker-concurrency-limit.json"

if jq -e '[.spec.template.spec.containers[] | select(.name == "n8n-worker") | .env[]? | select(.name == "N8N_CONCURRENCY_PRODUCTION_LIMIT") | .value] == ["50"]' \
  "$tmp/deployment-worker-concurrency-limit.json" >/dev/null; then
  pass "chart $chart_version renders N8N_CONCURRENCY_PRODUCTION_LIMIT=50 on the worker from n8n_execution_concurrency_limit = 50"
else
  fail "chart $chart_version did not render N8N_CONCURRENCY_PRODUCTION_LIMIT=50 on the worker as expected"
fi

# -- Pruning cadence (n8n_pruning_hard_delete_buffer/_interval,
# n8n_pruning_soft_delete_interval): at the defaults none of the three is
# set, so the module omits the keys and the chart's own values.yaml defaults
# (hardDeleteBuffer 1, hardDeleteInterval 15, softDeleteInterval 60) must
# still reach the pod. The two assertions below only check the hard-delete
# buffer and interval env vars; they do not prove the whole rendered plan
# is byte-identical to before these inputs existed. Reuses
# deployment-main-null-tag.json's sibling, values-default.json, from the
# PDB scenario above.
helm template n8n "$chart_dir" -f "$tmp/values-default.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-main.yaml >"$tmp/deployment-main-pruning-default.yaml"
yaml_to_json "$tmp/deployment-main-pruning-default.yaml" >"$tmp/deployment-main-pruning-default.json"

if jq -e '[.spec.template.spec.containers[] | select(.name == "n8n-main") | .env[]? | select(.name == "EXECUTIONS_DATA_HARD_DELETE_BUFFER") | .value] == ["1"]' \
  "$tmp/deployment-main-pruning-default.json" >/dev/null; then
  pass "chart $chart_version renders EXECUTIONS_DATA_HARD_DELETE_BUFFER=1 (its own default) when the module omits hardDeleteBuffer"
else
  fail "chart $chart_version did not render the expected default EXECUTIONS_DATA_HARD_DELETE_BUFFER=1"
fi

if jq -e '[.spec.template.spec.containers[] | select(.name == "n8n-main") | .env[]? | select(.name == "EXECUTIONS_DATA_PRUNE_HARD_DELETE_INTERVAL") | .value] == ["15"]' \
  "$tmp/deployment-main-pruning-default.json" >/dev/null; then
  pass "chart $chart_version renders EXECUTIONS_DATA_PRUNE_HARD_DELETE_INTERVAL=15 (its own default) when the module omits hardDeleteInterval"
else
  fail "chart $chart_version did not render the expected default EXECUTIONS_DATA_PRUNE_HARD_DELETE_INTERVAL=15"
fi

if jq -e '[.spec.template.spec.containers[] | select(.name == "n8n-main") | .env[]? | select(.name == "EXECUTIONS_DATA_PRUNE_SOFT_DELETE_INTERVAL") | .value] == ["60"]' \
  "$tmp/deployment-main-pruning-default.json" >/dev/null; then
  pass "chart $chart_version renders EXECUTIONS_DATA_PRUNE_SOFT_DELETE_INTERVAL=60 (its own default) when the module omits softDeleteInterval"
else
  fail "chart $chart_version did not render the expected default EXECUTIONS_DATA_PRUNE_SOFT_DELETE_INTERVAL=60"
fi

# Setting all three must override the chart's own defaults with the module's
# values, proving the merge-in-when-set path actually reaches the chart.
render_values "$tmp/values-pruning-cadence.json" \
  -var=n8n_pruning_hard_delete_buffer=2 -var=n8n_pruning_hard_delete_interval=30 -var=n8n_pruning_soft_delete_interval=120
helm template n8n "$chart_dir" -f "$tmp/values-pruning-cadence.json" --set secretRefs.existingSecret=test-core \
  --show-only templates/deployment-main.yaml >"$tmp/deployment-main-pruning-cadence.yaml"
yaml_to_json "$tmp/deployment-main-pruning-cadence.yaml" >"$tmp/deployment-main-pruning-cadence.json"

if jq -e '
    ([.spec.template.spec.containers[] | select(.name == "n8n-main") | .env[]? | select(.name == "EXECUTIONS_DATA_HARD_DELETE_BUFFER") | .value] == ["2"]) and
    ([.spec.template.spec.containers[] | select(.name == "n8n-main") | .env[]? | select(.name == "EXECUTIONS_DATA_PRUNE_HARD_DELETE_INTERVAL") | .value] == ["30"]) and
    ([.spec.template.spec.containers[] | select(.name == "n8n-main") | .env[]? | select(.name == "EXECUTIONS_DATA_PRUNE_SOFT_DELETE_INTERVAL") | .value] == ["120"])
  ' "$tmp/deployment-main-pruning-cadence.json" >/dev/null; then
  pass "chart $chart_version renders the three pruning cadence env vars from n8n_pruning_hard_delete_buffer/_interval and n8n_pruning_soft_delete_interval"
else
  fail "chart $chart_version did not render the pruning cadence env vars as expected from the three module inputs"
fi

echo
if [[ "$FAIL" -ne 0 ]]; then
  echo "One or more chart-render checks failed against chart $chart_version. See FAIL lines above." >&2
  exit 1
fi
echo "All chart-render checks passed against chart $chart_version."
