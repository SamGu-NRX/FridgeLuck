#!/usr/bin/env bash
# Negative loader checks: every implementation must REJECT each mutated copy
# of the dataset. Covers the evidence-completeness contract pinned in the
# READMEs: every evidence object (fact-level and component-level) carries a
# known kind and non-blank ref and note.
#
# Usage (from anywhere; paths are resolved relative to this script):
#   bash data/ingredient-facts/conformance/runners/negative_checks.sh
#
# Exits nonzero if any checker accepts any mutation.
set -u

ROOT="$(cd "$(dirname "$0")/../../../../" && pwd)"
DATA="$ROOT/data/ingredient-facts"
TS_RUNNER="$DATA/conformance/runners/typescript/run_conformance.ts"
PY_RUNNER="$DATA/conformance/runners/python/run_conformance.py"
SWIFT_BIN="$ROOT/packages/FLIngredientFacts/.build/debug/flfacts-conformance"

if [ ! -x "$SWIFT_BIN" ]; then
  echo "building flfacts-conformance..." >&2
  swift build --package-path "$ROOT/packages/FLIngredientFacts" >&2 || exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

# mutate <id> <python expression over d (facts dict)> — writes a mutated copy
# of the dataset with conformance/cases.json alongside. Fails the script if
# the mutation cannot be applied: a missing or unchanged copy would make the
# runners exit 2 for the wrong reason (false rejection evidence).
mutate() {
  local id="$1" expr="$2"
  local dir="$TMP/$id"
  mkdir -p "$dir/conformance"
  cp "$DATA/identities.json" "$DATA/facts.json" "$dir/"
  cp "$DATA/conformance/cases.json" "$dir/conformance/"
  DATA_DIR="$dir" MUTATION="$expr" python3 - <<'PYEOF' || { echo "FAIL $id: mutation helper crashed"; exit 1; }
import json, os

class StopMutation(Exception):
    pass

directory = os.environ["DATA_DIR"]
path = os.path.join(directory, "facts.json")
d = json.load(open(path))
try:
    exec(os.environ["MUTATION"])
except StopMutation:
    pass
with open(path, "w") as handle:
    json.dump(d, handle)
PYEOF
}

# check <id> — every checker must exit nonzero on the mutated copy.
check() {
  local id="$1" ok=0 impl out
  for impl in ts py swift; do
    case "$impl" in
      ts)    out="$(bun "$TS_RUNNER" "$TMP/$id" 2>&1)" ;;
      py)    out="$(python3 "$PY_RUNNER" "$TMP/$id" 2>&1)" ;;
      swift) out="$("$SWIFT_BIN" "$TMP/$id" 2>&1)" ;;
    esac
    local status=$?
    if [ "$status" -eq 0 ]; then
      echo "FAIL $id: $impl runner ACCEPTED malformed data (exit 0)"
      ok=1
    fi
  done
  if [ "$ok" -eq 0 ]; then
    echo "PASS $id: all three implementations reject it"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

# Clean control: all three must accept the real dataset.
for impl in ts py swift; do
  case "$impl" in
    ts)    bun "$TS_RUNNER" "$DATA" >/dev/null 2>&1 ;;
    py)    python3 "$PY_RUNNER" "$DATA" >/dev/null 2>&1 ;;
    swift) "$SWIFT_BIN" "$DATA" >/dev/null 2>&1 ;;
  esac
  if [ $? -eq 0 ]; then
    echo "PASS control: $impl runner accepts the clean dataset"
  else
    echo "FAIL control: $impl runner REJECTED the clean dataset"
    FAILURES=$((FAILURES + 1))
  fi
done

# 1. Fact-level evidence missing ref (the repro the join verification found).
mutate stripped_fact_ref "d['facts']['soy-sauce']['allergens']['soy']['evidence'].pop('ref')"
check stripped_fact_ref

# 2. Component-level evidence missing ref: previously unchecked by both runners.
mutate stripped_component_ref """
for entry in d['facts'].values():
    for component in entry.get('components', []):
        if component.get('evidence'):
            component['evidence'].pop('ref')
            raise StopMutation
"""
check stripped_component_ref

# 3. Blank (whitespace) ref on a fact-level evidence object.
mutate blank_fact_ref "d['facts']['soy-sauce']['allergens']['soy']['evidence']['ref'] = '   '"
check blank_fact_ref

# 4. Empty note on a fact-level evidence object.
mutate empty_fact_note "d['facts']['soy-sauce']['allergens']['soy']['evidence']['note'] = ''"
check empty_fact_note

# 5. Unknown evidence kind on a component.
mutate bad_component_kind """
for entry in d['facts'].values():
    for component in entry.get('components', []):
        if component.get('evidence'):
            component['evidence']['kind'] = 'rumor'
            raise StopMutation
"""
check bad_component_kind

# 6. Whole evidence object deleted from a non-unknown fact.
mutate missing_fact_evidence "del d['facts']['soy-sauce']['allergens']['soy']['evidence']"
check missing_fact_evidence

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES negative check(s) FAILED"
  exit 1
fi
echo "all negative checks passed"
