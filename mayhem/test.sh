#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Upstream's own suite: lesstest replays each lesstest/lt/*.lt session (keystrokes into less, the
# simulated terminal's screen compared against the recorded screen after every keystroke).
# build.sh built less_t (LESSTEST, normal flags), lesstest and lt_screen into mayhem/build-test.
B="$SRC/mayhem/build-test"
for b in "$B/less_t" "$B/lesstest/lesstest" "$B/lesstest/lt_screen"; do
  [ -x "$b" ] || { echo "test.sh: missing $b (build.sh should have built it)" >&2; emit_ctrf lesstest 0 1 0; exit 1; }
done
work=$(mktemp -d "${TMPDIR:-/tmp}/lesstest.XXXXXX")
passed=0 failed=0
for lt in "$SRC"/lesstest/lt/*.lt; do
  name=$(basename "$lt")
  log="$work/${name}.log"
  # Output goes to a file (not a pipe) so a stray child can't hold the pipeline open.
  (cd "$work" && timeout -k 5 120 perl "$SRC/lesstest/runtest" -r "$work/run" -l "$B/less_t" \
      -t "$B/lesstest/lesstest" -s "$B/lesstest/lt_screen" "$lt") >"$log" 2>&1
  # A session passes only if lesstest itself printed "PASS: <session> (<n> steps)" (every screen
  # matched) and reported no failure or error.
  if grep -qE '^PASS: .* \([0-9]+ steps\)$' "$log" && ! grep -qE '^(FAIL|ERR)' "$log"; then
    passed=$((passed+1)); echo "PASS $name"
  else
    failed=$((failed+1)); echo "FAIL $name"; sed 's/^/    /' "$log" | head -20
  fi
done
rm -rf "$work"
emit_ctrf lesstest "$passed" "$failed" 0
