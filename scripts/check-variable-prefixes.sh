#!/usr/bin/env bash
# check-variable-prefixes.sh, every variable in the ROOT variables.tf must
# belong to one of the naming families the module contract defines (see
# docs/module-contract.md, rule 3.6). Catches prefix sprawl: a PR that invents
# a new family instead of filing its input under an existing one.
#
# Root only, on purpose. The examples and submodules use caller-facing names
# (ui_host, godaddy_domain, kubeconfig_path, peak_cpu_request_millis) and that
# is correct for them, so this vocabulary would be wrong there. That is also
# why this is a script rather than tflint's terraform_naming_convention: one
# .tflint.hcl is shared by every lint target through TFLINT_CONFIG_FILE, so a
# root-only regex there would fail every example.
#
# What this script deliberately does NOT check: whether an input was filed
# under the *right* family for its meaning. Nothing stops a cluster-facing
# input being named n8n_something. That judgment stays with review, the same
# split check-variable-banners.sh draws.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
FILE="variables.tf"

# The families, and what each one governs. Keep in sync with the table in
# docs/module-contract.md.
#
#   n8n_      n8n application and workload configuration
#   k8s_      cluster-facing surface: ingress, attestations
#   db_       Postgres endpoint and protocol, in n8n's own vocabulary
#   redis_    queue endpoint and protocol, same
#   cnpg_     in-cluster Postgres implementation
#   valkey_   in-cluster queue implementation
#   postgres_ Postgres backend selector
#   create_   optional resources the module itself renders
#   metrics_  n8n's own metrics port exposure
FAMILIES="n8n|k8s|db|redis|cnpg|valkey|postgres|create|metrics"

fail=0
while IFS= read -r name; do
  if [[ ! "$name" =~ ^(${FAMILIES})_[a-z0-9_]+$ ]]; then
    echo "$FILE: variable \"$name\" is not in a known naming family" >&2
    fail=1
  fi
done < <(sed -n 's/^variable "\([^"]*\)".*/\1/p' "$FILE")

if [[ "$fail" -ne 0 ]]; then
  echo >&2
  echo "Every root input belongs to one of: ${FAMILIES//|/_, }_" >&2
  echo "See docs/module-contract.md, rule 3.6, for what each family governs." >&2
  echo "If the input genuinely needs a new family, change the contract and this" >&2
  echo "script in the same PR rather than working around the check." >&2
  exit 1
fi

count=$(sed -n 's/^variable "\([^"]*\)".*/\1/p' "$FILE" | wc -l | tr -d ' ')
echo "check-variable-prefixes: OK ($count variables in $FILE)"
