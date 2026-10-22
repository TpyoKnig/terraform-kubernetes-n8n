#!/usr/bin/env bash
# check-example-parity.sh: the six homelab variants are documented as
# examples/homelab plus one deliberate difference each (one DNS provider,
# one topology change, one connection pooler, one AI Assistant toggle), so
# the module input surface each one passes through should stay in step with
# the baseline except where that difference requires it to diverge. In
# practice this has silently drifted elsewhere before (see
# terraform-aws-n8n#136, which this check is ported from): a variable added
# to one example never reaching the others, and a README section vanishing
# from some of them without anyone deciding it should. Two checks:
#
#   1. Variable parity. Diffs the set of variable NAMES each example's
#      variables.tf declares against examples/homelab's and fails on any
#      name present on one side only that is not listed in ALLOWED_DIFFS
#      below. Entries are "example:pattern"; a pattern may be a bash glob
#      (cloudflare_*). Every entry must still match a real variable, so a
#      rename cannot leave a stale exemption behind.
#
#   2. Shared-storage documentation. Every example that declares
#      shared_storage_class (all seven do today) must carry its own
#      "## Shared storage across the pods" README section, either the full
#      prose (examples/homelab, examples/homelab-split-ingress,
#      examples/homelab-cloudflare-split-ingress) or a one-paragraph pointer
#      into examples/homelab's copy (examples/homelab-cloudflare,
#      examples/homelab-godaddy, examples/homelab-pgbouncer): the
#      auto-generated terraform-docs Inputs table alone does not explain
#      what the two settings do together.
#
# What this script deliberately does NOT check: a shared variable's type,
# default, description or validation (defaults legitimately differ between
# examples, e.g. homelab-cloudflare-split-ingress's proxy_hops default of 2
# against homelab-split-ingress's 1), main.tf wiring, tftest.hcl coverage,
# or the content of the shared-storage section beyond its presence. It
# catches the surface going out of sync, the same scope the sibling's
# equivalent check has.
#
# Run in CI via .github/workflows/terraform-tests.yml's example-parity job,
# matching the AWS sibling's check-example-parity.sh, which that repo also
# gates CI on. Also runnable by hand or via `task example-parity`.
#
# Usage: scripts/check-example-parity.sh
# Requires: bash, grep, sed, sort, dirname. No terraform, no network.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BASELINE=homelab

# Built from examples/homelab-*/ rather than hardcoded, so a new example
# directory is picked up by both checks below automatically instead of
# silently skipping it until someone remembers to add it here. $BASELINE
# itself does not match this pattern (no trailing "-..."), so it is never
# double-counted.
shopt -s nullglob
EXAMPLES=()
for dir in examples/homelab-*/; do
  EXAMPLES+=("$(basename "$dir")")
done

# "example:pattern" pairs allowed to differ from examples/homelab, either
# way (a variable the baseline has and the example doesn't, or vice versa).
ALLOWED_DIFFS=(
  # DNS-provider variants expose their own provider's inputs; neither
  # touches the other provider's variable family.
  "homelab-cloudflare:cloudflare_*"
  # The tunnel adds the Cloudflare edge in front of ingress-nginx, so this
  # example counts one more proxy hop than the baseline.
  "homelab-cloudflare:proxy_hops"
  "homelab-godaddy:godaddy_*"
  "homelab-godaddy:ingress_ip"
  # split-ingress owns two Ingresses itself (create_ingress = false in the
  # module call) and so takes editor_host/webhook_host instead of the
  # module's single ui_host, plus the Ingress-shaping inputs that implies.
  # It also drops postgres_lan_ip/metrics_lan_ip: see its README's
  # "Differences from ../homelab" table.
  "homelab-split-ingress:ui_host"
  "homelab-split-ingress:editor_host"
  "homelab-split-ingress:webhook_host"
  "homelab-split-ingress:ingress_class_name"
  "homelab-split-ingress:ingress_extra_annotations"
  "homelab-split-ingress:editor_ingress_extra_annotations"
  "homelab-split-ingress:webhook_ingress_extra_annotations"
  "homelab-split-ingress:timezone"
  "homelab-split-ingress:proxy_hops"
  "homelab-split-ingress:postgres_lan_ip"
  "homelab-split-ingress:metrics_lan_ip"
  # homelab-split-ingress carries no hardcoded OTel block to begin with, so
  # it never gained otel_endpoint when the baseline's block became
  # conditional on it.
  "homelab-split-ingress:otel_endpoint"
  # homelab-cloudflare-split-ingress is split-ingress plus a Cloudflare
  # Tunnel in front, so it carries the same split-ingress diffs plus its
  # own cloudflare_* inputs.
  "homelab-cloudflare-split-ingress:ui_host"
  "homelab-cloudflare-split-ingress:editor_host"
  "homelab-cloudflare-split-ingress:webhook_host"
  "homelab-cloudflare-split-ingress:ingress_class_name"
  "homelab-cloudflare-split-ingress:ingress_extra_annotations"
  "homelab-cloudflare-split-ingress:editor_ingress_extra_annotations"
  "homelab-cloudflare-split-ingress:webhook_ingress_extra_annotations"
  "homelab-cloudflare-split-ingress:timezone"
  "homelab-cloudflare-split-ingress:proxy_hops"
  "homelab-cloudflare-split-ingress:postgres_lan_ip"
  "homelab-cloudflare-split-ingress:metrics_lan_ip"
  "homelab-cloudflare-split-ingress:otel_endpoint"
  "homelab-cloudflare-split-ingress:cloudflare_*"
  # homelab-ai-assistant wires n8n's AI Assistant and Agents module to an
  # in-cluster sandbox; everything else is examples/homelab unchanged.
  "homelab-ai-assistant:ai_model"
  "homelab-ai-assistant:sandbox_namespace"
  "homelab-ai-assistant:sandbox_release_name"
  "homelab-ai-assistant:searxng_url"
  # homelab-ai-assistant also carries no hardcoded OTel block.
  "homelab-ai-assistant:otel_endpoint"
)

declare_vars() {
  # `|| true` keeps a variables.tf with no declarations from tripping
  # `set -e` inside the caller's command substitution with an unexplained
  # exit.
  { grep -oE '^variable "[^"]+"' "examples/$1/variables.tf" || true; } | sed -E 's/^variable "(.+)"$/\1/' | sort -u
}

is_allowed() {
  local example="$1" var="$2" entry pattern
  for entry in "${ALLOWED_DIFFS[@]}"; do
    [[ "${entry%%:*}" == "$example" ]] || continue
    pattern="${entry#*:}"
    # shellcheck disable=SC2053  # pattern is meant to glob
    [[ "$var" == $pattern ]] && return 0
  done
  return 1
}

fail=0
baseline_vars="$(declare_vars "$BASELINE")"

for example in "${EXAMPLES[@]}"; do
  example_vars="$(declare_vars "$example")"

  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    grep -qxF "$var" <<<"$example_vars" && continue
    is_allowed "$example" "$var" && continue
    echo "check-example-parity: examples/$BASELINE declares \"$var\" but examples/$example does not (undeclared drift; add it to $example or to ALLOWED_DIFFS with a reason)" >&2
    fail=1
  done <<<"$baseline_vars"

  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    grep -qxF "$var" <<<"$baseline_vars" && continue
    is_allowed "$example" "$var" && continue
    echo "check-example-parity: examples/$example declares \"$var\" but examples/$BASELINE does not (undeclared drift; add it to $BASELINE or to ALLOWED_DIFFS with a reason)" >&2
    fail=1
  done <<<"$example_vars"

  # Every ALLOWED_DIFFS entry for this example must still name a variable
  # present on exactly one side, which is the divergence the exemption
  # claims to permit. Matching on both sides no longer describes a
  # divergence at all (a rename could make the pattern match on both without
  # tripping this), and matching on neither means the variable is gone from
  # both. Either way the exemption has outlived what it was written for.
  for entry in "${ALLOWED_DIFFS[@]}"; do
    [[ "${entry%%:*}" == "$example" ]] || continue
    pattern="${entry#*:}"
    in_baseline=0
    in_example=0
    while IFS= read -r var; do
      # shellcheck disable=SC2053
      [[ -n "$var" && "$var" == $pattern ]] && { in_baseline=1; break; }
    done <<<"$baseline_vars"
    while IFS= read -r var; do
      # shellcheck disable=SC2053
      [[ -n "$var" && "$var" == $pattern ]] && { in_example=1; break; }
    done <<<"$example_vars"
    if [[ "$in_baseline" -eq "$in_example" ]]; then
      echo "check-example-parity: ALLOWED_DIFFS names \"$pattern\" for examples/$example, but it now matches on both sides (no longer a divergence) or on neither (removed); remove the stale exemption" >&2
      fail=1
    fi
  done
done

# Shared-storage documentation: every example declaring shared_storage_class
# must carry a "## Shared storage across the pods" README section. All seven
# examples declare the variable today (it is in the baseline set and every
# ALLOWED_DIFFS list above leaves it untouched), so this runs over all of
# them, baseline included, since examples/homelab's own copy is what the
# pointer-style sections link into.
for example in "$BASELINE" "${EXAMPLES[@]}"; do
  vars="$(declare_vars "$example")"
  grep -qxF "shared_storage_class" <<<"$vars" || continue
  if ! grep -qx '## Shared storage across the pods' "examples/$example/README.md"; then
    echo "check-example-parity: examples/$example declares shared_storage_class but its README has no \"## Shared storage across the pods\" section (see examples/$BASELINE/README.md, or examples/homelab-cloudflare/README.md for the pointer-style version)" >&2
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "check-example-parity: FAILED" >&2
  exit 1
fi

echo "check-example-parity: OK ($BASELINE vs ${EXAMPLES[*]})"
