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

live, dead, unref, ack_rendered = [], [], [], []
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
    elif v in ACK_ONLY and outside > 0:
        # The whole point of ACK_ONLY is that the input is read nowhere but a
        # check block; a reference outside one means either the comment's
        # claim is wrong or the input started rendering something nobody
        # noticed. Either way it is a finding, not a pass.
        ack_rendered.append((v, outside))
    elif outside == 0 and v not in ACK_ONLY:
        dead.append((v, total))
    else:
        live.append(v)

print(f"inputs: {len(names)}  live: {len(live)}  check-only (DEAD): {len(dead)}  unreferenced: {len(unref)}  ack-only-but-rendered: {len(ack_rendered)}")
print()
if dead:
    print("DECLARED AND VALIDATED BUT NEVER WIRED:")
    for v, n in dead:
        print(f"   {v}   ({n} references, all inside check blocks)")
if unref:
    print("\nNOT REFERENCED AT ALL IN THE ROOT:")
    for v in unref:
        print("  ", v)
if ack_rendered:
    print("\nACK_ONLY BUT REFERENCED OUTSIDE A CHECK BLOCK:")
    for v, n in ack_rendered:
        print(f"   {v}   ({n} references outside a check block)")
    print("   ACK_ONLY means the input exists only to be read by a check; a")
    print("   reference outside one means either it now renders something and")
    print("   should come off this list, or something is reading it by mistake.")

# Pass 2: every "Maps to <ENV_VAR>" claim must name a variable the root emits.
#
# Claims are read per variable block so a failure can name the input, not just
# the environment variable. The threshold of four characters keeps prose words
# out; every real n8n variable is far longer. Backtick-quoting the name right
# after "Maps to" is accepted even though no current description does it, so
# adding one later does not silently fall out of pass 2.
#
# Known blind spot, deliberately not chased: a description that names its
# chart value first and the env var afterward, in parentheses, because the
# chart value's own dotted path reads better leading the sentence (e.g.
# n8n_queue_worker_lock_duration: "Maps to the chart's redis.worker.lockDuration
# value (QUEUE_WORKER_LOCK_DURATION on the pods)"). Those inputs render into a
# nested chart value key, not a literal config.extraEnv name=value entry; the
# env var in the parenthetical is the chart's own template translating that
# key, not something this module's code ever writes as `name = "..."`, so
# EMITTED below has nothing to find for them even when the claim is read
# correctly. Checking those needs the chart's own templates
# (tests/scripts/check-n8n-chart.sh, `helm template`), not a grep over this
# repo's root .tf files.
CLAIM = re.compile(r"Maps to (?:the )?`?([A-Z][A-Z0-9_]{3,})`?")
EMITTED = re.compile(r'name\s*=\s*"([A-Z][A-Z0-9_]{3,})"')

variables_text = io.open("variables.tf", encoding="utf-8").read()
blocks = re.split(r'^(?=variable ")', variables_text, flags=re.M)

claims = []  # (input name, claimed env var)
for block in blocks:
    m = re.match(r'variable "([^"]+)"', block)
    if not m:
        continue
    seen = set()
    for env in CLAIM.findall(block):
        if env not in seen:
            seen.add(env)
            claims.append((m.group(1), env))

root_text = {f: io.open(f, encoding="utf-8").read() for f in ROOT}
emitted = set()
for t in root_text.values():
    emitted |= set(EMITTED.findall(t))

# Not just "is this env var emitted anywhere in the root": an input whose
# claimed env var happens to be emitted by a wholly different input's own
# rendering would otherwise pass despite rendering nothing (or the wrong
# name) itself. Scoped to within NEARBY characters of one of the claiming
# variable's own var.<name> references, generous enough to span the
# local/resource attribute that actually renders it.
NEARBY = 400


def rendered_by_its_own_variable(var_name, env_name):
    pattern = re.compile(r'\bvar\.' + re.escape(var_name) + r'\b')
    name_pattern = re.compile(r'name\s*=\s*"' + re.escape(env_name) + r'"')
    for t in root_text.values():
        for m in pattern.finditer(t):
            start, end = max(0, m.start() - NEARBY), min(len(t), m.end() + NEARBY)
            if name_pattern.search(t[start:end]):
                return True
    return False


unrendered = [
    (v, env) for v, env in claims
    if env not in emitted or not rendered_by_its_own_variable(v, env)
]

print(f"env-var claims: {len(claims)}  emitted names: {len(emitted)}  mismatched: {len(unrendered)}")
if unrendered:
    print("\nDESCRIPTION NAMES AN ENV VAR THE ROOT NEVER EMITS FROM THAT INPUT:")
    for v, env in unrendered:
        print(f"   {v}   claims {env}")
    print("\n   Either the rendered name is misspelled, in which case n8n ignores")
    print("   the setting and the input does nothing, or the description names")
    print("   the wrong variable, or that variable renders only from a different")
    print("   input's own code path. All three are worth failing over.")

if dead or unrendered or ack_rendered:
    sys.exit(1)
