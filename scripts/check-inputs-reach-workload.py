# Find inputs that are declared and validated but never reach the workload.
#
# tflint's terraform_unused_declarations cannot see these: a `check` block
# reference counts as a use, so an input consulted only by an assertion looks
# used while doing nothing.
import io, re, os, glob

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
    elif outside == 0:
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
