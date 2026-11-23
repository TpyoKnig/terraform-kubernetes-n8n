#!/usr/bin/env bash
# drift-issue-sync.sh: the offline decision half of
# .github/workflows/version-drift.yml's tracking-issue sync. Given the new
# tests/scripts/check-version-drift.sh report and the tracking issue's
# previous body and state, decide what the workflow does; the workflow
# itself makes the gh calls. Split out so the decision is testable without
# GitHub (DRIFT_SYNC_SELF_TEST=1).
#
# A "finding" is a line starting with DRIFT: or ERROR:. OK: lines, the
# summary line, ordering, and CRLF line endings never count as a change, so
# an unchanged set of findings replaces the body silently while a changed
# set also posts a comment (an issue body edit notifies nobody).
#
# Usage:
#   drift-issue-sync.sh action <report> <previous-body> <open|closed|none>
#     Prints one word:
#       abort   the report's last non-blank line is not check-version-drift.sh's
#               summary line, or the summary's counts disagree with its
#               DRIFT:/ERROR: lines (a crashed or truncated run); leave the
#               issue alone rather than closing it as clean
#       create  findings and no tracking issue yet
#       update  replace the body only: open issue with the same findings, or
#               a closed issue whose findings did not come back changed (a
#               manual close with unchanged findings stays closed)
#       comment open issue, findings changed: replace the body and comment
#       close   open issue, findings resolved: replace the body, close, and
#               comment
#       close-quiet
#               open issue that already had no findings (for example
#               reopened by hand): replace the body and close without a
#               comment, since no finding changed
#       reopen  closed issue, findings changed and some remain: replace the
#               body, reopen, and comment
#       noop    no findings, and no issue or a closed one without findings
#   drift-issue-sync.sh changes <previous-body> <report>
#     Prints a Markdown comment body listing new and resolved findings.
set -uo pipefail

SUMMARY_RE='^check-version-drift\.sh: ([0-9]+) pin\(s\) behind upstream, ([0-9]+) error\(s\)$'
# check-version-drift.sh's own closing line (see its last echo), printed
# after the summary on every real run. report_complete tolerates exactly
# this line, and only this line, following the summary; anything else
# there (a crash, a reformatted script) still aborts.
TRAILER='See docs/versioning.md for the bump policy and what this report cannot see.'

# findings <file>: sorted, unique DRIFT:/ERROR: lines; nothing for a missing file.
findings() {
  [[ -f "$1" ]] || return 0
  tr -d '\r' <"$1" | { grep -E '^(DRIFT|ERROR):' || true; } | LC_ALL=C sort -u
}

# report_complete <file>: the last line matching SUMMARY_RE is the summary,
# every line after it is blank or exactly check-version-drift.sh's own
# closing line, and the summary's counts match the DRIFT:/ERROR: lines
# actually present.
report_complete() {
  local file="$1" content lineno summary_line drift errors after
  [[ -f "$file" ]] || return 1
  content="$(tr -d '\r' <"$file")"
  lineno="$(printf '%s\n' "$content" | grep -nE "$SUMMARY_RE" | tail -n 1 | cut -d: -f1)"
  [[ -n "$lineno" ]] || return 1
  summary_line="$(printf '%s\n' "$content" | sed -n "${lineno}p")"
  [[ "$summary_line" =~ $SUMMARY_RE ]] || return 1
  after="$(printf '%s\n' "$content" | tail -n "+$((lineno + 1))" | \
    sed -e '/^[[:space:]]*$/d' -e "\\%^${TRAILER}\$%d")"
  [[ -z "$after" ]] || return 1
  drift="$(printf '%s\n' "$content" | grep -cE '^DRIFT:')"
  errors="$(printf '%s\n' "$content" | grep -cE '^ERROR:')"
  [[ "${BASH_REMATCH[1]}" == "$drift" && "${BASH_REMATCH[2]}" == "$errors" ]]
}

decide_action() {
  local report="$1" previous="$2" state="$3" new old
  report_complete "$report" || { echo abort; return; }
  new="$(findings "$report")"
  old="$(findings "$previous")"
  case "$state" in
    none) [[ -z "$new" ]] && echo noop || echo create ;;
    closed)
      if [[ -z "$new" && -z "$old" ]]; then
        echo noop
      elif [[ -n "$new" && "$new" != "$old" ]]; then
        echo reopen
      else
        echo update
      fi
      ;;
    open)
      if [[ -z "$new" && -z "$old" ]]; then
        echo close-quiet
      elif [[ -z "$new" ]]; then
        echo close
      elif [[ "$new" == "$old" ]]; then
        echo update
      else
        echo comment
      fi
      ;;
    *)
      echo "unknown issue state: $state" >&2
      return 1
      ;;
  esac
}

# print_block <title> <lines>: a Markdown section with the lines fenced, or nothing.
print_block() {
  [[ -n "$2" ]] || return 0
  printf '%s\n\n```text\n%s\n```\n\n' "$1" "$2"
}

describe_changes() {
  local old new added resolved
  old="$(findings "$1")"
  new="$(findings "$2")"
  added="$(LC_ALL=C comm -13 <(printf '%s\n' "$old" | sed '/^$/d') <(printf '%s\n' "$new" | sed '/^$/d'))"
  resolved="$(LC_ALL=C comm -23 <(printf '%s\n' "$old" | sed '/^$/d') <(printf '%s\n' "$new" | sed '/^$/d'))"
  print_block "New:" "$added"
  print_block "Resolved:" "$resolved"
  if [[ -z "$added" && -z "$resolved" ]]; then
    printf 'No change in findings.\n'
  fi
}

# ── Offline self-test ──────────────────────────────────────────────────────
if [[ "${DRIFT_SYNC_SELF_TEST:-0}" == "1" ]]; then
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  failures=0
  cases=0

  # fixture <name> <body>: write a fixture file.
  fixture() { printf '%s\n' "$2" >"$dir/$1"; }

  expect_action() {
    local name="$1" report="$2" previous="$3" state="$4" expected="$5" actual
    cases=$((cases + 1))
    actual="$(decide_action "$dir/$report" "$dir/$previous" "$state")"
    if [[ "$actual" != "$expected" ]]; then
      echo "FAIL: $name: action $report $previous $state -> '$actual', expected '$expected'" >&2
      failures=$((failures + 1))
    fi
  }

  expect_changes() {
    local name="$1" previous="$2" report="$3" pattern="$4" mode="$5" out
    cases=$((cases + 1))
    out="$(describe_changes "$dir/$previous" "$dir/$report")"
    if [[ "$mode" == "has" ]] && ! grep -qF -- "$pattern" <<<"$out"; then
      echo "FAIL: $name: changes output lacks '$pattern':" >&2
      echo "$out" >&2
      failures=$((failures + 1))
    elif [[ "$mode" == "lacks" ]] && grep -qF -- "$pattern" <<<"$out"; then
      echo "FAIL: $name: changes output contains '$pattern':" >&2
      echo "$out" >&2
      failures=$((failures + 1))
    fi
  }

  fixture drift.md '## Version drift report

DRIFT: cli/terraform: pinned 1.17.0, latest v1.17.2
OK:    provider/kubernetes: "~> 3.3" admits latest 3.5.0
DRIFT: chart/n8n (1.17.0 from oci://ghcr.io/n8n-io/n8n-helm-chart/n8n): pinned 1.17.0, latest 1.20.0

check-version-drift.sh: 2 pin(s) behind upstream, 0 error(s)'
  # Same findings, reordered; different OK line; CRLF endings, as the GitHub
  # API can return an edited body.
  printf '%s\r\n' '## Version drift report' '' \
    'DRIFT: chart/n8n (1.17.0 from oci://ghcr.io/n8n-io/n8n-helm-chart/n8n): pinned 1.17.0, latest 1.20.0' \
    'OK:    provider/kubernetes: "~> 3.3" admits latest 3.6.0' \
    'DRIFT: cli/terraform: pinned 1.17.0, latest v1.17.2' \
    '' 'check-version-drift.sh: 2 pin(s) behind upstream, 0 error(s)' >"$dir/same.md"
  fixture newer.md 'DRIFT: cli/terraform: pinned 1.17.0, latest v1.17.3
DRIFT: chart/n8n (1.17.0 from oci://ghcr.io/n8n-io/n8n-helm-chart/n8n): pinned 1.17.0, latest 1.20.0

check-version-drift.sh: 2 pin(s) behind upstream, 0 error(s)'
  fixture error.md 'DRIFT: cli/terraform: pinned 1.17.0, latest v1.17.2
DRIFT: chart/n8n (1.17.0 from oci://ghcr.io/n8n-io/n8n-helm-chart/n8n): pinned 1.17.0, latest 1.20.0
ERROR: chart/valkey: lookup failed

check-version-drift.sh: 2 pin(s) behind upstream, 1 error(s)'
  fixture clean.md 'OK:    provider/kubernetes: "~> 3.3" admits latest 3.5.0

check-version-drift.sh: 0 pin(s) behind upstream, 0 error(s)'
  # A run that died before the summary: no findings, but not clean.
  fixture truncated.md 'OK:    provider/kubernetes: "~> 3.3" admits latest 3.5.0'
  # The summary disagrees with the lines it summarises: zero parsed findings
  # must not read as clean.
  fixture mismatch.md 'STALE: terraform pinned at 1.17.0, latest v1.17.2
check-version-drift.sh: 1 pin(s) behind upstream, 0 error(s)'
  fixture empty.md ''
  # Output continued after the summary: the run did not end where the
  # script does.
  fixture trailing.md 'DRIFT: cli/terraform: pinned 1.17.0, latest v1.17.2
check-version-drift.sh: 1 pin(s) behind upstream, 0 error(s)
bash: line 9: unexpected EOF'
  # check-version-drift.sh's real output shape: a blank line, then its own
  # closing "See docs/versioning.md ..." line, after the summary (the P0
  # this test guards: report_complete must not treat that trailer as
  # unexpected trailing output and abort on every real run).
  fixture real.md '## Version drift report

DRIFT: cli/terraform: pinned 1.17.0, latest v1.17.2
OK:    provider/kubernetes: "~> 3.3" admits latest 3.5.0
DRIFT: chart/n8n (1.17.0 from oci://ghcr.io/n8n-io/n8n-helm-chart/n8n): pinned 1.17.0, latest 1.20.0

check-version-drift.sh: 2 pin(s) behind upstream, 0 error(s)

See docs/versioning.md for the bump policy and what this report cannot see.'
  # The trailer is tolerated only when it is the last thing in the file;
  # real output does not continue after it, and neither may a fixture that
  # claims to be complete.
  fixture trailer-plus-garbage.md 'DRIFT: cli/terraform: pinned 1.17.0, latest v1.17.2

check-version-drift.sh: 1 pin(s) behind upstream, 0 error(s)

See docs/versioning.md for the bump policy and what this report cannot see.
unexpected trailing output'

  expect_action "first report with drift creates the issue" drift.md missing.md none create
  expect_action "clean with no issue does nothing" clean.md missing.md none noop
  expect_action "same findings only replace the body" same.md drift.md open update
  expect_action "same findings, reverse direction" drift.md same.md open update
  expect_action "a changed latest version comments" newer.md drift.md open comment
  expect_action "a new ERROR comments" error.md drift.md open comment
  expect_action "a resolved finding comments" drift.md error.md open comment
  expect_action "a clean report closes the open issue" clean.md drift.md open close
  expect_action "an open issue that was already clean closes without a comment" clean.md clean.md open close-quiet
  expect_action "an open issue with an empty body closes without a comment" clean.md empty.md open close-quiet
  expect_action "drift after a close reopens" drift.md clean.md closed reopen
  expect_action "clean while closed does nothing" clean.md clean.md closed noop
  expect_action "a manual close with unchanged findings stays closed" same.md drift.md closed update
  expect_action "changed findings while closed reopen" newer.md drift.md closed reopen
  expect_action "findings resolved while closed refresh the body" clean.md drift.md closed update
  expect_action "output after the summary aborts" trailing.md drift.md open abort
  expect_action "an empty previous body counts as no findings" drift.md empty.md open comment
  expect_action "a truncated report never closes the issue" truncated.md drift.md open abort
  expect_action "a truncated report never creates an issue" truncated.md missing.md none abort
  expect_action "summary counts must match the lines" mismatch.md drift.md open abort
  expect_action "a missing report aborts" missing.md drift.md open abort
  expect_action "a real report with the docs trailer after the summary creates the issue" real.md missing.md none create
  expect_action "a real report with the docs trailer and unchanged findings only updates" real.md drift.md open update
  expect_action "output after the trailer still aborts" trailer-plus-garbage.md drift.md open abort

  expect_changes "new version listed as new" drift.md newer.md 'latest v1.17.3' has
  expect_changes "old version listed as resolved" drift.md newer.md 'Resolved:' has
  expect_changes "unchanged finding not listed" drift.md newer.md 'chart/n8n' lacks
  expect_changes "OK lines never listed" drift.md clean.md 'provider/kubernetes' lacks
  expect_changes "everything resolved" drift.md clean.md 'latest v1.17.2' has
  expect_changes "first findings all new" empty.md error.md 'ERROR: chart/valkey' has

  echo "drift-issue-sync.sh self-test: ${cases} case(s), ${failures} failure(s)"
  ((failures == 0))
  exit
fi

case "${1:-}" in
  action)
    [[ $# -eq 4 ]] || { echo "usage: $0 action <report> <previous-body> <open|closed|none>" >&2; exit 64; }
    decide_action "$2" "$3" "$4"
    ;;
  changes)
    [[ $# -eq 3 ]] || { echo "usage: $0 changes <previous-body> <report>" >&2; exit 64; }
    describe_changes "$2" "$3"
    ;;
  *)
    sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p;}' "$0"
    [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] || exit 64
    ;;
esac
