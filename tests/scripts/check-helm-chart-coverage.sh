#!/usr/bin/env bash
# check-helm-chart-coverage.sh: catch a stale docs/helm-chart-coverage.md.
#
# The doc's own text explains why it goes stale: it is verified by hand
# against one chart version's values.yaml, and nothing forced a re-check when
# n8n_chart_version's default moved. This script is that force:
#
#   1. The doc's "Measured against chart **X**" line must match
#      n8n_chart_version's default in variables.tf.
#   2. Every top-level key in the pinned chart's values.yaml must appear
#      somewhere in the doc's coverage table or the "Not currently
#      configurable" list.
#
# This is a stale-doc tripwire, not a content auditor: it cannot tell you a
# row's *description* is still accurate, only that the version claim isn't
# stale and that the chart hasn't grown a whole new top-level section nobody
# has looked at yet. Re-verifying a row's content when its key already exists
# in an old version is still a human job: see the doc's own instructions.
#
# Requires: helm. No terraform, no credentials, no cluster.
#
# Usage: tests/scripts/check-helm-chart-coverage.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

command -v helm >/dev/null 2>&1 || { echo "helm not found on PATH" >&2; exit 1; }

VARS_FILE="variables.tf"
DOC_FILE="docs/helm-chart-coverage.md"

# shellcheck disable=SC1091 # path is $SCRIPT_DIR-relative, resolved at runtime, not statically
source "$SCRIPT_DIR/lib/tf-defaults.sh"

pinned_version="$(read_default n8n_chart_version "$VARS_FILE")"
pinned_repository="$(read_default n8n_chart_repository "$VARS_FILE")"

if [[ -z "$pinned_version" || -z "$pinned_repository" ]]; then
  echo "Could not read n8n_chart_version/n8n_chart_repository defaults from $VARS_FILE" >&2
  exit 1
fi

# Matches "Measured against chart **1.16.0**", this doc's own phrasing (not
# the "Verified against chart version \`X\`" backtick form the AWS sibling's
# doc uses).
doc_version="$(sed -n 's/.*Measured against chart \*\*\([^*]*\)\*\*.*/\1/p' "$DOC_FILE" | head -1)"

if [[ -z "$doc_version" ]]; then
  echo "$DOC_FILE: could not find a 'Measured against chart **X**' line" >&2
  exit 1
fi

if [[ "$doc_version" != "$pinned_version" ]]; then
  cat >&2 <<EOF
$DOC_FILE claims chart version $doc_version, but n8n_chart_version's default in
$VARS_FILE is $pinned_version. Diff the two versions' values.yaml
(tests/scripts/chart-values-diff.sh), update any affected coverage rows, and
change the doc's version line in the same PR.
EOF
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
helm show values "${pinned_repository}/n8n" --version "$pinned_version" >"$tmp/values.yaml"

# Top-level keys only: unindented "key:" lines. This chart's values.yaml never
# puts a document-level list item at column 0, so this is a clean extraction
# without a YAML parser dependency. A while-read loop, not `mapfile`: mapfile
# is bash >= 4 only, and stock macOS ships bash 3.2, which is exactly the
# platform this script's BSD-sed handling above is written to support.
chart_keys=()
while IFS= read -r key; do
  chart_keys+=("$key")
done < <(grep -oE '^[A-Za-z][A-Za-z0-9_-]*:' "$tmp/values.yaml" | sed 's/:$//' | sort -u)

if [[ ${#chart_keys[@]} -eq 0 ]]; then
  echo "No top-level keys found in the rendered values.yaml; helm show values may have failed silently" >&2
  exit 1
fi

# Scoped to the coverage table and the "Not currently configurable" list, not
# the whole doc: prose above either section (e.g. this doc's own intro) could
# otherwise mention a key in passing and satisfy the check with no actual
# coverage row or "not configurable" entry backing it.
contract_section="$(sed -n '/^## Coverage by chart section/,$p' "$DOC_FILE")"

# Further scoped to backtick-quoted spans within that section: every genuine
# coverage row and "not configurable" entry backtick-quotes the chart key, so
# a key that only turns up inside prose (e.g. a section whose body happens to
# contain the word "tests", which is also a top-level chart key) no longer
# satisfies the check without a real row or list entry behind it.
backticked_terms="$(grep -oE '`[^`]*`' <<<"$contract_section" || true)"

missing=()
for key in "${chart_keys[@]}"; do
  if ! grep -qE "(^|[^A-Za-z0-9_-])${key}([^A-Za-z0-9_-]|$)" <<<"$backticked_terms"; then
    missing+=("$key")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  cat >&2 <<EOF
$DOC_FILE does not mention ${#missing[@]} top-level key(s) from chart $pinned_version's
values.yaml, in either the coverage table or the "Not currently configurable"
list: ${missing[*]}

Add a coverage row for any the module now sets, or add the rest to "Not
currently configurable".
EOF
  exit 1
fi

echo "OK: $DOC_FILE is verified against chart $pinned_version (${#chart_keys[@]} top-level keys covered)."
