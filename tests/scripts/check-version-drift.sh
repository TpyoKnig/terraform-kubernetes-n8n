#!/usr/bin/env bash
# check-version-drift.sh: report every pin that has fallen behind upstream.
#
# Each pin is classified DRIFT / OK / ERROR, the same report shape the AWS
# and Google siblings use (n8n-io/terraform-google-n8n#36, ported into
# n8n-io/terraform-aws-n8n#191):
#   DRIFT: the pin is behind upstream, or (for a Terraform provider) its
#          constraint no longer admits the latest release.
#   OK:    the pin matches upstream, admits the latest release, or is a
#          deliberately floating tag that tracks upstream on its own (see
#          "cnpg/postgres image" below).
#   ERROR: the upstream lookup failed, or this script cannot evaluate the
#          pin's form (e.g. a provider constraint using an operator
#          tests/scripts/lib/constraints.sh does not understand, or a latest
#          release that is not a plain X.Y.Z version). Printed to both
#          stdout and stderr: stdout so it lands in the report this script's
#          only consumer syncs to a tracking issue, stderr so it is also
#          visible immediately in CI logs.
# A one-line summary count closes the report: "N pin(s) behind upstream, M
# error(s)".
#
# This module has no cloud account and no cluster of its own (see
# AGENTS.md: the caller owns the cluster), so there is no EKS/GKE/AKS
# version list, no managed database engine, and no controller chart this
# module installs (KEDA, cert-manager, ingress-nginx, the CloudNativePG
# operator are all caller-owned; see docs/shared-responsibility.md). What
# this module actually pins, reachable from public, unauthenticated APIs:
#   - Terraform providers (registry.terraform.io), constraint-aware: any
#     comma-separated combination of ~>, >=, >, <=, <, != and = (or a bare
#     version) is evaluated against the latest release via
#     tests/scripts/lib/constraints.sh.
#   - The CI toolchain this repo pins (terraform, tflint, terraform-docs via
#     GitHub releases; checkov via PyPI, since .github/workflows pins it as
#     a pip version rather than a GitHub release tag).
#   - The n8n Helm chart, against its own oci://ghcr.io/n8n-io/n8n-helm-chart
#     registry's anonymous tag list (a short-lived unauthenticated token
#     plus the Docker Distribution tags/list API; filtered to plain X.Y.Z
#     release tags, since the registry also carries prereleases such as
#     "1.17.0-preview.workerpools.1" and non-version tags).
#   - The n8n application version (n8n_image_tag), against n8n-io/n8n's own
#     GitHub releases, filtered to the "n8n@X.Y.Z" tag family: that repo is
#     a monorepo whose release tags also carry per-package prefixes
#     ("@n8n/n8n-nodes-base@...") and "latest"/"beta"/"stable" marker tags
#     that move onto whichever numbered tag published most recently, so
#     only the "n8n@" family is the core application's own version history.
#   - The Valkey chart (valkey-io/valkey-helm's own index.yaml).
#
# Deliberately NOT checked, and why:
#   - cnpg_postgres_image_tag. The default, "18-minimal-trixie", is a
#     floating major tag by design (see the variable's own description):
#     ghcr.io/cloudnative-pg/postgresql republishes it against the newest
#     18.x minor on every CloudNativePG image build, so it already tracks
#     upstream without a bump here. Reported as OK with the floating
#     minor noted, never as DRIFT, the same way terraform-aws-n8n's
#     docs/versioning.md treats its own un-pinned EKS add-on versions as
#     "nothing to bump" rather than as drift.
#   - n8n_chart_repository / n8n_image_repository / valkey_chart_repository
#     and friends. These are the location a version is pulled from, not a
#     version; nothing to compare against upstream.
#   - Kubernetes API/cluster version. The caller's cluster, out of this
#     module's and this script's reach entirely (no kubeconfig is read
#     here, deliberately: see "no terraform, no AWS credentials, no
#     cluster" on the AWS sibling's equivalent script, which this module
#     has no cloud account to substitute for either).
#
# Why this still exits 0 even when a lookup fails (unlike exiting non-zero
# on any failure): .github/workflows/version-drift.yml pipes this straight
# into `tee -a report.md "$GITHUB_STEP_SUMMARY"` under `shell: bash`, which
# adds `-o pipefail`. A later, unguarded sync step has no `if: always()`, so
# a non-zero exit here would make GitHub Actions skip it entirely and leave
# the one tracking issue this report lands in silently stale. Every ERROR
# line is already visible in the synced report text via stdout, so a
# report, not a gate, is the right contract. The script still exits 1 if a
# required tool (curl, jq, python3) is missing, since then it produced no
# report at all.
#
# Usage: tests/scripts/check-version-drift.sh
# Requires: curl, jq, python3 (for tests/scripts/lib/constraints.sh). No
# terraform, no cloud credentials, no cluster.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

for tool in curl jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool missing: $tool" >&2; exit 1; }
done

# shellcheck disable=SC1091 # path is $SCRIPT_DIR-relative, resolved at runtime, not statically
source "$SCRIPT_DIR/lib/tf-defaults.sh"
# shellcheck disable=SC1091 # path is $SCRIPT_DIR-relative, resolved at runtime, not statically
source "$SCRIPT_DIR/lib/constraints.sh"

WORKFLOW=".github/workflows/terraform-tests.yml"

drift_count=0
error_count=0

report_drift() { echo "DRIFT: $1"; drift_count=$((drift_count + 1)); }
report_ok()    { echo "OK:    $1"; }
report_error() {
  echo "ERROR: $1"
  echo "check-version-drift.sh: ERROR: $1" >&2
  error_count=$((error_count + 1))
}

# $1: pin label. $2: pinned version. $3: latest version, or empty if the
# upstream lookup failed. Tolerates a "v" prefix on either side.
compare_pin() {
  local label="$1" pinned="$2" latest="$3"
  if [[ -z "$latest" ]]; then
    report_error "$label: could not determine latest upstream version (pinned ${pinned:-unknown})"
    return
  fi
  if [[ -z "$pinned" || "$pinned" == "null" ]]; then
    report_error "$label: could not read the pinned version"
    return
  fi
  local p="${pinned#v}" l="${latest#v}"
  if [[ "$p" == "$l" ]]; then
    report_ok "$label: pinned $pinned matches latest $latest"
  else
    report_drift "$label: pinned $pinned, latest $latest"
  fi
}

# $1: provider source (e.g. "hashicorp/kubernetes"). $2: pin label.
# $3: constraint. Looks up the provider's latest release and evaluates the
# constraint against it via constraint_accepts.
compare_provider_constraint() {
  local source="$1" label="$2" constraint="$3"
  local latest
  latest="$(curl -sf --max-time 15 "https://registry.terraform.io/v1/providers/$source" | jq -r '.version // empty')" || latest=""
  if [[ -z "$latest" ]]; then
    report_error "$label: could not reach registry.terraform.io for $source"
    return
  fi
  constraint_accepts "$constraint" "$latest"
  case $? in
    0) report_ok "$label: \"$constraint\" admits latest $latest" ;;
    1) report_drift "$label: \"$constraint\" does not admit latest $latest" ;;
    *) report_error "$label: constraint \"$constraint\" or latest release \"$latest\" is not a plain X.Y.Z form this script understands" ;;
  esac
}

echo "## Version drift report"
echo

# ── Terraform providers ────────────────────────────────────────────────────────
# All five root providers (versions.tf) are declared identically across all
# nine versions.tf files in the repo (root, 7 examples, 2 submodules) per
# AGENTS.md, so one lookup per provider covers every file. The two
# example-only providers (cloudflare, godaddy-dns) are checked separately
# below, since they live in a subset of examples with their own constraints.
while IFS='|' read -r source label; do
  constraint="$(awk -v s="\"$source\"" '
    $0 ~ "source[ \t]*=[ \t]*" s { found = 1 }
    found && /version[ \t]*=/ {
      if (match($0, /"[^"]*"/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  ' versions.tf)"
  if [[ -z "$constraint" ]]; then
    report_error "provider/$label: could not read its version constraint from versions.tf"
    continue
  fi
  compare_provider_constraint "$source" "provider/$label" "$constraint"
done <<'EOF'
hashicorp/kubernetes|kubernetes
hashicorp/helm|helm
hashicorp/random|random
hashicorp/time|time
gavinbunney/kubectl|kubectl
EOF

# Example-only providers: cloudflare (homelab-cloudflare,
# homelab-cloudflare-split-ingress) and godaddy-dns (homelab-godaddy). Both
# examples pin the same constraint for cloudflare, so one read is enough:
# this reads only examples/homelab-cloudflare/versions.tf's constraint and
# assumes the split-ingress copy matches, rather than reading and comparing
# both files.
cf_constraint="$(awk '
  $0 ~ "source[ \t]*=[ \t]*\"cloudflare/cloudflare\"" { found = 1 }
  found && /version[ \t]*=/ {
    if (match($0, /"[^"]*"/)) {
      print substr($0, RSTART + 1, RLENGTH - 2)
      exit
    }
  }
' examples/homelab-cloudflare/versions.tf)"
if [[ -n "$cf_constraint" ]]; then
  compare_provider_constraint "cloudflare/cloudflare" "provider/cloudflare (examples/homelab-cloudflare, examples/homelab-cloudflare-split-ingress)" "$cf_constraint"
else
  report_error "provider/cloudflare: could not read its version constraint from examples/homelab-cloudflare/versions.tf"
fi

# Matched with an optional leading host/namespace segment: versions.tf pins
# this one as "registry.terraform.io/veksh/godaddy-dns" (OpenTofu has no
# built-in default registry, so the example spells it out explicitly), not
# the bare "veksh/godaddy-dns" the other two example providers use.
gd_constraint="$(awk '
  $0 ~ "source[ \t]*=[ \t]*\"([^\"]*/)?veksh/godaddy-dns\"" { found = 1 }
  found && /version[ \t]*=/ {
    if (match($0, /"[^"]*"/)) {
      print substr($0, RSTART + 1, RLENGTH - 2)
      exit
    }
  }
' examples/homelab-godaddy/versions.tf)"
if [[ -n "$gd_constraint" ]]; then
  compare_provider_constraint "veksh/godaddy-dns" "provider/godaddy-dns (examples/homelab-godaddy)" "$gd_constraint"
else
  report_error "provider/godaddy-dns: could not read its version constraint from examples/homelab-godaddy/versions.tf"
fi

echo

# ── CI toolchain this repo's CI pins ────────────────────────────────────────────
# terraform/tflint/terraform-docs are each pinned via a top-level env var
# terraform-tests.yml also reads (or, for terraform-docs, a job-level env
# var); checkov is pinned the same way but published to PyPI, not GitHub
# releases, so it gets its own lookup below. A `tool|repo|env` list read line
# by line, not `declare -A`: associative arrays are bash >= 4 only, and
# stock macOS ships bash 3.2.
while IFS='|' read -r tool repo env_name; do
  pinned="$(sed -n "s/^[[:space:]]*${env_name}:[[:space:]]*\"\\{0,1\\}\\(v\\{0,1\\}[0-9][^\"[:space:]]*\\)\"\\{0,1\\}.*/\\1/p" "$WORKFLOW" | head -1)"
  latest="$(curl -sf --max-time 15 "https://api.github.com/repos/$repo/releases/latest" | jq -r '.tag_name // empty')" || latest=""
  compare_pin "cli/$tool" "$pinned" "$latest"
done <<'EOF'
terraform|hashicorp/terraform|TF_VERSION
tflint|terraform-linters/tflint|TFLINT_VERSION
EOF

pinned_tfdocs="$(sed -n 's/^[[:space:]]*TERRAFORM_DOCS_VERSION:[[:space:]]*\(v[0-9][^[:space:]]*\)/\1/p' "$WORKFLOW" | head -1)"
latest_tfdocs="$(curl -sf --max-time 15 "https://api.github.com/repos/terraform-docs/terraform-docs/releases/latest" | jq -r '.tag_name // empty')" || latest_tfdocs=""
compare_pin "cli/terraform-docs" "$pinned_tfdocs" "$latest_tfdocs"

pinned_checkov="$(sed -n 's/^[[:space:]]*CHECKOV_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORKFLOW" | head -1)"
latest_checkov="$(curl -sf --max-time 15 "https://pypi.org/pypi/checkov/json" | jq -r '.info.version // empty')" || latest_checkov=""
compare_pin "cli/checkov" "$pinned_checkov" "$latest_checkov"

echo

# ── Helm charts ──────────────────────────────────────────────────────────────
# n8n chart: oci://ghcr.io/n8n-io/n8n-helm-chart/n8n, via a short-lived
# unauthenticated token and the Docker Distribution tags/list API. ghcr.io
# does expose a public, unauthenticated tag index. Only plain X.Y.Z tags
# count: the registry also carries prereleases
# ("1.17.0-preview.workerpools.1") and non-version tags ("artifacthub.io",
# "sha256-..." digests).
n8n_chart_version="$(read_default n8n_chart_version variables.tf)"
n8n_token="$(curl -sf --max-time 15 "https://ghcr.io/token?scope=repository:n8n-io/n8n-helm-chart/n8n:pull&service=ghcr.io" | jq -r '.token // empty' 2>/dev/null)" || n8n_token=""
if [[ -z "$n8n_token" ]]; then
  report_error "chart/n8n: could not obtain a ghcr.io anonymous pull token"
else
  n8n_tags_json="$(curl -sf --max-time 20 -H "Authorization: Bearer $n8n_token" "https://ghcr.io/v2/n8n-io/n8n-helm-chart/n8n/tags/list")" || n8n_tags_json=""
  if [[ -z "$n8n_tags_json" ]]; then
    report_error "chart/n8n: could not list tags from ghcr.io"
  else
    latest_n8n_chart="$(echo "$n8n_tags_json" | jq -r '.tags[]?' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    compare_pin "chart/n8n ($n8n_chart_version from oci://ghcr.io/n8n-io/n8n-helm-chart/n8n)" "$n8n_chart_version" "$latest_n8n_chart"
  fi
fi

# Valkey chart: valkey-io/valkey-helm's own repository index.yaml (Helm
# repository protocol, not OCI). That repository also serves
# valkey-operator and valkey-resources from the same index, so this cannot
# be a blind "every version: line" scan. Parsed with a small state-machine
# line scan rather than a full YAML parser (not guaranteed installed): each
# chart entry's keys are emitted in alphabetical order by Helm's indexer, so
# "name:" always precedes "version:" within the same entry, and the text is
# fed over stdin rather than interpolated into the script, since the real
# document legitimately contains quotes and other characters that would
# break a triple-quoted embed.
valkey_chart_version="$(read_default valkey_chart_version variables.tf)"
valkey_index="$(curl -sfL --max-time 15 "https://valkey-io.github.io/valkey-helm/index.yaml")" || valkey_index=""
if [[ -z "$valkey_index" ]]; then
  report_error "chart/valkey: could not fetch valkey-io.github.io/valkey-helm/index.yaml"
else
  latest_valkey_chart="$(printf '%s' "$valkey_index" | python3 -c "
import re, sys

current = None
versions = []
name_re = re.compile(r'^\s*name:\s*(\S+)\s*\$')
version_re = re.compile(r'^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*\$')
for line in sys.stdin:
    m = name_re.match(line)
    if m:
        current = m.group(1)
        continue
    m = version_re.match(line)
    if m and current == 'valkey':
        versions.append(tuple(int(x) for x in m.group(1).split('.')))
if versions:
    versions.sort()
    print('.'.join(str(x) for x in versions[-1]))
")"
  compare_pin "chart/valkey ($valkey_chart_version from valkey-io/valkey-helm)" "$valkey_chart_version" "$latest_valkey_chart"
fi

echo

# ── n8n application version ────────────────────────────────────────────────────
# n8n_image_tag pins the application, independent of the chart's own
# appVersion (see docs/helm-chart-coverage.md). n8n-io/n8n is a monorepo:
# its release tags also carry per-package prefixes and moving marker tags
# ("latest", "beta", "stable"), so only the "n8n@X.Y.Z" family is the core
# application's own version history. n8n_image_tag == null (delegate to the
# chart's own appVersion) is a valid, supported configuration, reported as
# an explanatory OK rather than compared against upstream, since there is
# no pin to be behind.
n8n_image_tag="$(read_default n8n_image_tag variables.tf)"
if [[ -z "$n8n_image_tag" || "$n8n_image_tag" == "null" ]]; then
  report_ok "n8n/image_tag: default is null, delegates to the chart's own appVersion (see docs/helm-chart-coverage.md)"
else
  n8n_releases_json="$(curl -sf --max-time 20 "https://api.github.com/repos/n8n-io/n8n/releases?per_page=100")" || n8n_releases_json=""
  if [[ -z "$n8n_releases_json" ]]; then
    report_error "n8n/image_tag: could not list releases from n8n-io/n8n"
  else
    latest_n8n_app="$(echo "$n8n_releases_json" | jq -r '.[] | select(.prerelease == false and .draft == false) | .tag_name' | grep -E '^n8n@[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^n8n@//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    compare_pin "n8n/image_tag" "$n8n_image_tag" "$latest_n8n_app"
  fi
fi

echo

# ── CloudNativePG Postgres image ────────────────────────────────────────────────
# cnpg_postgres_image_tag's default, "18-minimal-trixie", is a floating
# major tag by design (see the variable's own description): ghcr.io
# republishes it against the newest 18.x minor on every image build, so it
# tracks upstream on its own. Reported as OK, with the current minor it
# resolves to today noted for visibility, not as a pin to compare against a
# single "latest" value. A caller who pinned an exact minor
# (e.g. "18.4-minimal-trixie") is outside what this check covers: that is
# this module's documented upgrade path (see cnpg_postgres_image_tag's own
# description on moving between majors), not something the default tracks.
cnpg_tag="$(read_default cnpg_postgres_image_tag variables.tf)"
if [[ "$cnpg_tag" =~ ^[0-9]+-minimal-trixie$ ]]; then
  cnpg_token="$(curl -sf --max-time 15 "https://ghcr.io/token?scope=repository:cloudnative-pg/postgresql:pull&service=ghcr.io" | jq -r '.token // empty' 2>/dev/null)" || cnpg_token=""
  if [[ -z "$cnpg_token" ]]; then
    report_error "image/cnpg-postgres: could not obtain a ghcr.io anonymous pull token"
  else
    major="${cnpg_tag%%-*}"
    # The tag list is large enough (11000+ tags across every Postgres major
    # CloudNativePG has ever published) that it needs the Docker
    # Distribution API's Link-header pagination, which curl/jq/sed cannot
    # follow cleanly without separating response headers from the body.
    # python3's urllib already is this script's dependency (constraints.sh),
    # so paginate there instead of fighting `curl -i` plus `sed`.
    latest_minor="$(python3 - "$cnpg_token" "$major" <<'PYEOF'
import sys, re, json, urllib.request

token, major = sys.argv[1], sys.argv[2]
pattern = re.compile(rf'^{re.escape(major)}\.([0-9]+)-minimal-trixie$')
url = "https://ghcr.io/v2/cloudnative-pg/postgresql/tags/list?n=1000"
best = None
for _ in range(20):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.load(resp)
            link = resp.headers.get("Link")
    except Exception:
        break
    for tag in data.get("tags", []):
        m = pattern.match(tag)
        if m:
            minor = int(m.group(1))
            if best is None or minor > best:
                best = minor
    if not link:
        break
    m = re.search(r"<([^>]+)>", link)
    if not m:
        break
    url = "https://ghcr.io" + m.group(1)
if best is not None:
    print(best)
PYEOF
)"
    if [[ -n "$latest_minor" ]]; then
      report_ok "image/cnpg-postgres: floating tag \"$cnpg_tag\" currently resolves to ${major}.${latest_minor}-minimal-trixie (tracks upstream automatically; not a pin to bump)"
    else
      report_error "image/cnpg-postgres: could not determine which minor \"$cnpg_tag\" currently resolves to on ghcr.io"
    fi
  fi
else
  report_error "image/cnpg-postgres: cnpg_postgres_image_tag is \"$cnpg_tag\", not this script's expected floating-major form (\"<major>-minimal-trixie\"); compare it against ghcr.io/cloudnative-pg/postgresql tags by hand"
fi

echo
echo "check-version-drift.sh: ${drift_count} pin(s) behind upstream, ${error_count} error(s)"
echo
echo "See docs/versioning.md for the bump policy and what this report cannot see."
exit 0
