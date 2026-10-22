# Find inputs that are declared and validated but never reach the workload.
#
# tflint's terraform_unused_declarations cannot see these: a `check` block
# reference counts as a use, so an input consulted only by an assertion looks
# used while doing nothing.
#
# Two passes, because the first one alone can report every input live while a
# rendered name is still wrong:
#
#   1. Reference pass. Does `var.<name>` appear outside a check block?
#   2. Name pass. For every description claiming "Maps to <SOME_ENV_VAR>", is a
#      variable of that name actually emitted anywhere in the root?
#
# Pass 1 cannot see a misrendered name: an input can be read, converted and
# rendered into config.extraEnv under the wrong key while n8n reads a
# different one, and the input is live by every measure pass 1 has while
# reaching nothing. Pass 2 is the mechanical diff that catches that: the
# description is right and the rendering is wrong, and comparing them costs
# nothing.
#
# What pass 2 still cannot see: a name that is emitted correctly but into a
# values key the chart ignores on a given path. That needs the chart's own
# templates, which is what tests/defaults.tftest.hcl and `helm template` cover.
import io, re, os, glob, sys

ROOT = [f for f in glob.glob("*.tf") if f != "variables.tf"]

def check_ranges(text):
    """Character spans of every top-level `check "..." { ... }` block."""
    spans = []
    for m in re.finditer(r'^check\s+"[^"]*"\s*\{', text, re.M):
        i = m.end() - 1
        depth = 0
        for j in range(i, len(text)):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    spans.append((m.start(), j))
                    break
    return spans

names = re.findall(r'^variable "([^"]+)"', io.open("variables.tf", encoding="utf-8").read(), re.M)

# Acknowledgement inputs exist only to be read by a check block: their whole
# job is to record that a warned-about trade was deliberate, and rendering
# them anywhere would be a bug, not a fix. Naming them here is the deliberate
# opt-out; anything else that is check-only is still a finding. This set
# covers inputs that only gate a check block, nothing more.
ACK_ONLY = {
    "cnpg_backup_acknowledged",
    "postgres_connection_budget_check_enabled",
}

live, dead, unref = [], [], []
for v in names:
    total = 0
    outside = 0
    for f in ROOT:
        t = io.open(f, encoding="utf-8").read()
        spans = check_ranges(t)
        for m in re.finditer(r'\bvar\.' + re.escape(v) + r'\b', t):
            total += 1
            if not any(a <= m.start() <= b for a, b in spans):
                outside += 1
    if total == 0:
        unref.append(v)
    elif outside == 0 and v not in ACK_ONLY:
        dead.append((v, total))
    else:
        live.append(v)

print(f"inputs: {len(names)}  live: {len(live)}  check-only (DEAD): {len(dead)}  unreferenced: {len(unref)}")
print()
if dead:
    print("DECLARED AND VALIDATED BUT NEVER WIRED:")
    for v, n in dead:
        print(f"   {v}   ({n} references, all inside check blocks)")
if unref:
    print("\nNOT REFERENCED AT ALL IN THE ROOT:")
    for v in unref:
        print("  ", v)

# Pass 2: every "Maps to <ENV_VAR>" claim must name a variable the root emits.
#
# Claims are read per variable block so a failure can name the input, not just
# the environment variable. The threshold of four characters keeps prose words
# out; every real n8n variable is far longer.
CLAIM = re.compile(r"Maps to (?:the )?([A-Z][A-Z0-9_]{3,})")
EMITTED = re.compile(r'name\s*=\s*"([A-Z][A-Z0-9_]{3,})"')

variables_text = io.open("variables.tf", encoding="utf-8").read()
blocks = re.split(r'^(?=variable ")', variables_text, flags=re.M)

claims = []  # (input name, claimed env var)
for block in blocks:
    m = re.match(r'variable "([^"]+)"', block)
    if not m:
        continue
    for env in CLAIM.findall(block):
        claims.append((m.group(1), env))

emitted = set()
for f in ROOT:
    emitted |= set(EMITTED.findall(io.open(f, encoding="utf-8").read()))

unrendered = [(v, env) for v, env in claims if env not in emitted]

print(f"env-var claims: {len(claims)}  emitted names: {len(emitted)}  mismatched: {len(unrendered)}")
if unrendered:
    print("\nDESCRIPTION NAMES AN ENV VAR THE ROOT NEVER EMITS:")
    for v, env in unrendered:
        print(f"   {v}   claims {env}")
    print("\n   Either the rendered name is misspelled, in which case n8n ignores")
    print("   the setting and the input does nothing, or the description names")
    print("   the wrong variable. Both are worth failing over.")

if dead or unrendered:
    sys.exit(1)
