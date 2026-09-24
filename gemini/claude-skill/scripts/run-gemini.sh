#!/usr/bin/env bash
# Run a bounded Gemini execution contract through Antigravity, enforce a
# deterministic completion gate, and return a short activity digest plus one
# compact JSON result. The full event stream never reaches Claude.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib"
SCHEMA="$SCRIPT_DIR/../references/result-schema.json"

MODE="ultra"
READONLY=0
ALLOW_TODO="${GEMINI_ALLOW_TODO:-0}"
REF_DIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    lite|full|ultra) MODE="$1" ;;
    --readonly)      READONLY=1 ;;
    --allow-todo)    ALLOW_TODO=1 ;;
    --ref)
      # A reference repository Gemini may read but must not modify.
      [[ -d "${2:-}" ]] || { echo "ERROR: --ref needs a directory: ${2:-}" >&2; exit 2; }
      REF_DIRS+=("$(cd "$2" && pwd)")
      shift ;;
    -h|--help)
      echo "Usage: run-gemini.sh [lite|full|ultra] [--readonly] [--allow-todo]" >&2
      echo "                     [--ref DIR]... < contract" >&2
      exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$MODE" in
  lite)
    MODEL_DEFAULT="gemini-3.8-flash-low";    EFFORT="low";    ATTEMPTS_DEFAULT=1; LINES=20 ;;
  full)
    MODEL_DEFAULT="gemini-3.8-flash-medium"; EFFORT="medium"; ATTEMPTS_DEFAULT=2; LINES=30 ;;
  ultra)
    MODEL_DEFAULT="gemini-3.8-flash-high";   EFFORT="high";   ATTEMPTS_DEFAULT=3; LINES=40 ;;
esac

MODEL="${AGY_GEMINI_MODEL:-$MODEL_DEFAULT}"
ESCALATE_MODEL="${GEMINI_ESCALATE_MODEL:-gemini-3.1-pro-high}"
MAX_ATTEMPTS="${GEMINI_MAX_ATTEMPTS:-$ATTEMPTS_DEFAULT}"
AGENT="${AGY_GEMINI_AGENT:-gemini-orchestrator}"
LINES="${GEMINI_DIGEST_LINES:-$LINES}"

for tool in agy python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found in PATH" >&2; exit 127; }
done

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/gemini-skill"
RUN_ID="${GEMINI_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_DIR="$STATE_ROOT/runs/$RUN_ID"
mkdir -p "$RUN_DIR"

MILESTONES="$RUN_DIR/milestones.log"
: > "$MILESTONES"
echo "$RUN_ID" > "$STATE_ROOT/current"
# gemini-tail watches for this to know the run is over.
rm -f "$RUN_DIR/DONE"
finish() { echo "$1" >> "$MILESTONES"; : > "$RUN_DIR/DONE"; }
trap 'finish "[--:--] aborted"' INT TERM

# ---------------------------------------------------------------- contract
if [[ -t 0 ]]; then
  echo "ERROR: the contract is read from stdin; pipe it in or use a heredoc" >&2
  echo "       run-gemini.sh ultra <<'EOF' ... EOF" >&2
  exit 2
fi

RAW="$RUN_DIR/contract.raw"
cat > "$RAW"

CONTRACT="$RUN_DIR/contract.txt"
VERIFY="$RUN_DIR/verify.txt"
awk -v c="$CONTRACT" -v v="$VERIFY" '
  /^===VERIFY===[[:space:]]*$/ { inv=1; next }
  { print > (inv ? v : c) }
' "$RAW"
touch "$CONTRACT" "$VERIFY"

if [[ ! -s "$CONTRACT" ]]; then
  echo "ERROR: empty contract on stdin" >&2
  exit 2
fi

VERIFY_COUNT="$(grep -cve '^[[:space:]]*$' -e '^[[:space:]]*#' "$VERIFY" || true)"

# Ground the contract in the real workspace. Without this the agent has been
# observed searching the whole filesystem for files sitting in its own cwd.
GROUNDED="$RUN_DIR/grounded.txt"
{
  echo "=== WORKSPACE ==="
  echo "Working directory: $PWD"
  [[ "$REPO" != "$PWD" ]] && echo "Repository root:   $REPO"
  echo "Every relative path in this contract resolves against the working directory."
  echo "The files you need are already there. Do NOT search outside it, and never"
  echo "run a filesystem-wide find. Start with ls and git status."
  echo
  echo "Files at the working directory root:"
  ls -1A "$PWD" 2>/dev/null | head -40 | sed 's/^/  /'
  if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo
    echo "Branch: $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
    UNCOMMITTED="$(git -C "$REPO" status --short 2>/dev/null | head -20)"
    if [[ -n "$UNCOMMITTED" ]]; then
      echo "Uncommitted changes already present (do not revert these):"
      printf '%s\n' "$UNCOMMITTED" | sed 's/^/  /'
    else
      echo "Working tree is clean."
    fi
  fi
  if [[ "${#REF_DIRS[@]}" -gt 0 ]]; then
    echo
    echo "READ-ONLY REFERENCE DIRECTORIES"
    echo "Read these for patterns and conventions. Never write to them."
    for ref in "${REF_DIRS[@]}"; do
      echo "  $ref"
      ls -1A "$ref" 2>/dev/null | head -25 | sed 's/^/      /'
    done
  fi
  echo
  cat "$CONTRACT"
} > "$GROUNDED"
mv "$GROUNDED" "$CONTRACT"

# Gemini must see the same bar the gate will hold it to.
{
  echo
  echo "=== NON-NEGOTIABLE COMPLETION BAR ==="
  echo "An automated gate runs after you stop. It checks the real workspace, not your report."
  echo "You FAIL the gate, and will be sent back to work, if any of these is true:"
  echo "  - no file actually changed"
  echo "  - the new diff contains TODO, FIXME, placeholder, stub, 'not implemented',"
  echo "    NotImplementedError, UnsupportedOperationException or an empty catch block"
  echo "  - any verification command below exits non-zero"
  echo "Do not weaken, skip, delete or rewrite tests to make a command pass."
  echo "Do not report success before you have run every command and seen exit 0."
  if [[ "$VERIFY_COUNT" -gt 0 ]]; then
    echo "VERIFICATION COMMANDS (run each yourself, from the working directory):"
    sed -e '/^[[:space:]]*$/d' -e 's/^/  $ /' "$VERIFY"
  fi
  echo "Return only the compact JSON result. No chain-of-thought, no file dumps, no secrets."
} >> "$CONTRACT"

BRIEFING="$RUN_DIR/briefing.md"
if [[ "$READONLY" == "1" ]]; then
  # Recon produces no diff, so the briefing file is the whole deliverable.
  # Without a fixed path Gemini buries it in its own artifact directory.
  {
    echo
    echo "=== BRIEFING OUTPUT ==="
    echo "Write your complete briefing, in Markdown, to exactly this path:"
    echo "  $BRIEFING"
    echo "That file IS the deliverable. The JSON result is only a pointer to it."
    echo "Do not write it anywhere else. Do not inline it into the JSON."
    echo "An empty or missing file fails the gate."
  } >> "$CONTRACT"
fi

python3 "$LIB/gate.py" snapshot --run-dir "$RUN_DIR" --repo "$REPO"

# ---------------------------------------------------------------- run loop
ATTEMPT=1
GATE_RC=1
PROMPT_FILE="$CONTRACT"

while [[ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]]; do
  EVENTS="$RUN_DIR/events-$ATTEMPT.ndjson"
  STDERR_LOG="$RUN_DIR/stderr-$ATTEMPT.log"
  RESULT="$RUN_DIR/result-$ATTEMPT.json"
  META="$RUN_DIR/meta-$ATTEMPT.json"

  USE_MODEL="$MODEL"
  # Last shot on a multi-attempt run goes to the stronger reasoning model.
  if [[ "$ATTEMPT" -gt 1 && "$ATTEMPT" -eq "$MAX_ATTEMPTS" && -z "${AGY_GEMINI_MODEL:-}" ]]; then
    USE_MODEL="$ESCALATE_MODEL"
  fi

  ARGS=(--agent "$AGENT" --effort "$EFFORT" --model "$USE_MODEL"
        --add-dir "$PWD" --output-format stream-json)
  [[ "$REPO" != "$PWD" ]] && ARGS+=(--add-dir "$REPO")
  for ref in ${REF_DIRS[@]+"${REF_DIRS[@]}"}; do
    ARGS+=(--add-dir "$ref")
  done
  [[ -f "$SCHEMA" ]] && ARGS+=(--json-schema "$SCHEMA")
  [[ "${AGY_UNSAFE:-0}" == "1" ]] && ARGS+=(--dangerously-skip-permissions)

  if [[ "$ATTEMPT" -gt 1 ]]; then
    CONV="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("conversation_id",""))' \
            "$RUN_DIR/meta-1.json" 2>/dev/null || true)"
    if [[ -n "$CONV" ]]; then
      ARGS+=(--conversation "$CONV")
    else
      ARGS+=(--continue)
    fi
  fi

  echo "START attempt=$ATTEMPT model=$USE_MODEL effort=$EFFORT agent=$AGENT cwd=$PWD" \
    >> "$RUN_DIR/status.log"

  STARTED="$(date +%s)"
  agy "${ARGS[@]}" -p "$(cat "$PROMPT_FILE")" >"$EVENTS" 2>"$STDERR_LOG" &
  AGY_PID=$!

  # Print each step as it happens. Without this the caller sees nothing at all
  # until the attempt ends, which on a long run is several silent minutes.
  python3 "$LIB/stream.py" "$EVENTS" --pid "$AGY_PID" \
    --milestones "$MILESTONES" --attempt "$ATTEMPT" ${GEMINI_QUIET:+--quiet}

  wait "$AGY_PID"
  AGY_RC=$?
  WALL=$(( $(date +%s) - STARTED ))

  # The stream already showed every step, so only the tallies are new here.
  python3 "$LIB/digest.py" "$EVENTS" \
    --run-id "$RUN_ID" --mode "$MODE" --attempt "$ATTEMPT" \
    --wall "$WALL" --max-lines "$LINES" --summary-only \
    --out-result "$RESULT" --out-meta "$META"

  if [[ "$AGY_RC" -ne 0 ]]; then
    echo "  gate      FAIL — agy exited $AGY_RC (see: gemini-status $RUN_ID)"
    tail -n 3 "$STDERR_LOG" 2>/dev/null | sed 's/^/  stderr    /'
  fi

  GATE_ARGS=(check --run-dir "$RUN_DIR" --repo "$REPO" --cwd "$PWD"
             --result "$RESULT" --verify-file "$VERIFY")
  [[ "$READONLY" == "1" ]] && GATE_ARGS+=(--readonly --require-file "$BRIEFING")
  [[ "$ALLOW_TODO" == "1" ]] && GATE_ARGS+=(--allow-todo)
  python3 "$LIB/gate.py" "${GATE_ARGS[@]}" | tee -a "$RUN_DIR/gate.log"
  GATE_RC=${PIPESTATUS[0]}
  grep -E '^  (gate|verify|changed|briefing) ' "$RUN_DIR/gate.log" | tail -n 8 >> "$MILESTONES"
  : > "$RUN_DIR/gate.log"

  cp -f "$RESULT" "$RUN_DIR/result.json" 2>/dev/null || true

  if [[ "$GATE_RC" -eq 0 ]]; then
    break
  fi

  # needs_claude is an escalation, not a failure to grind on.
  if python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get("escalate") else 1)' \
      "$RUN_DIR/verdict.json" 2>/dev/null; then
    echo "  gate      escalating to Claude (Gemini returned needs_claude)"
    break
  fi

  if [[ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]]; then
    break
  fi

  PROMPT_FILE="$RUN_DIR/feedback.txt"
  LINES=20
  ATTEMPT=$(( ATTEMPT + 1 ))
  echo "  retry     attempt $ATTEMPT — sending gate failures back to Gemini" \
    | tee -a "$MILESTONES"
done

# ---------------------------------------------------------------- handoff
if [[ "$READONLY" == "1" && -s "$BRIEFING" ]]; then
  echo "── briefing ──"
  head -n "${GEMINI_BRIEFING_LINES:-300}" "$BRIEFING"
  TOTAL="$(wc -l < "$BRIEFING")"
  if [[ "$TOTAL" -gt "${GEMINI_BRIEFING_LINES:-300}" ]]; then
    echo "… briefing truncated at ${GEMINI_BRIEFING_LINES:-300} of $TOTAL lines: $BRIEFING"
  fi
fi

echo "── result ──"
python3 - "$RUN_DIR/result.json" "$RUN_DIR/verdict.json" "$RUN_ID" "$GATE_RC" <<'HANDOFF'
import json, sys

result_path, verdict_path, run_id, gate_rc = sys.argv[1:]

def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return {}

result, verdict = load(result_path), load(verdict_path)

# The gate, not Gemini, decides whether the work is done.
if gate_rc != "0" and not verdict.get("escalate"):
    result["status"] = "failed"

result["gate"] = {
    "pass": verdict.get("pass", False),
    "reasons": verdict.get("reasons", []),
    "verify": verdict.get("verify", []),
}
result["run_id"] = run_id
print(json.dumps(result, ensure_ascii=False))
HANDOFF

echo "── full stream: gemini-watch $RUN_ID  ·  logs: $RUN_DIR ──"
finish "[done]   run $RUN_ID finished"
exit 0
