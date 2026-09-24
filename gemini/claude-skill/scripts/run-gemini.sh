#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-ultra}"

case "$MODE" in
  lite)  EFFORT="${AGY_LITE_EFFORT:-low}" ;;
  full)  EFFORT="${AGY_FULL_EFFORT:-medium}" ;;
  ultra) EFFORT="${AGY_ULTRA_EFFORT:-high}" ;;
  *) echo "Usage: run-gemini.sh [lite|full|ultra]" >&2; exit 2 ;;
esac

command -v agy >/dev/null 2>&1 || {
  echo "ERROR: agy not found in PATH" >&2
  exit 127
}

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 not found in PATH" >&2
  exit 127
}

command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq not found in PATH" >&2
  exit 127
}

STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/gemini-skill"
RUN_ROOT="$STATE_ROOT/runs"
mkdir -p "$RUN_ROOT"

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_ID="${STAMP}-$$-$RANDOM"
RUN_DIR="$RUN_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"

PROMPT="$(cat)"

EVENTS="$RUN_DIR/events.ndjson"
STDERR="$RUN_DIR/stderr.log"
STATUS="$RUN_DIR/status.log"
RESULT="$RUN_DIR/result.json"

printf 'START mode=%s effort=%s agent=%s\n' \
  "$MODE" \
  "$EFFORT" \
  "${AGY_GEMINI_AGENT:-gemini-orchestrator}" > "$STATUS"

ARGS=(
  --agent "${AGY_GEMINI_AGENT:-gemini-orchestrator}"
  --effort "$EFFORT"
  --output-format stream-json
)

if [[ -n "${AGY_GEMINI_MODEL:-}" ]]; then
  ARGS+=(--model "$AGY_GEMINI_MODEL")
fi

if [[ "${AGY_UNSAFE:-0}" == "1" ]]; then
  ARGS+=(--dangerously-skip-permissions)
fi

set +e
agy "${ARGS[@]}" -p "$PROMPT" >"$EVENTS" 2>"$STDERR"
EXIT_CODE=$?
set -e

python3 - "$EVENTS" "$STATUS" "$RESULT" "$EXIT_CODE" <<'PY'
import json
import re
import sys
from pathlib import Path

events_path, status_path, result_path, exit_code = sys.argv[1:]
status_path = Path(status_path)
result_path = Path(result_path)

def redact(s):
    if not isinstance(s, str):
        return s
    patterns = [
        (r'(?i)(PRIVATE-TOKEN\s*[:=]\s*)[^\s,"\']+', r'\1[REDACTED]'),
        (r'(?i)(Authorization\s*:\s*Bearer\s+)[^\s,"\']+', r'\1[REDACTED]'),
        (r'(?i)(password|passwd|secret|token|api[_-]?key|secret[_-]?id)\s*([=:])\s*([^\s,"\']+)', r'\1\2[REDACTED]'),
        (r'(?i)(glpat-[A-Za-z0-9_-]+)', '[REDACTED_GITLAB_TOKEN]'),
        (r'(?i)(-----BEGIN [^-]+ PRIVATE KEY-----).*?(-----END [^-]+ PRIVATE KEY-----)', r'\1[REDACTED]\2'),
        (r'(?i)(AKIA[0-9A-Z]{16})', '[REDACTED_AWS_KEY]'),
    ]
    for p, repl in patterns:
        s = re.sub(p, repl, s, flags=re.DOTALL)
    return s

def summarize_tool(ev):
    s = ev.get("step_update", {})
    name = s.get("tool_name") or (s.get("tool_info") or {}).get("name") or "tool"
    info = s.get("tool_info") or {}
    params = info.get("parameters")
    if isinstance(params, dict):
        params_s = json.dumps(params, ensure_ascii=False)
    else:
        params_s = str(params or "")
    params_s = redact(params_s)
    if len(params_s) > 400:
        params_s = params_s[:400] + "..."
    return f"TOOL {name}: {params_s}"

def process():
    lines = []
    final = None
    try:
        for raw in Path(events_path).read_text(errors="replace").splitlines():
            try:
                ev = json.loads(raw)
            except Exception:
                continue

            if ev.get("event") == "init":
                i = ev.get("init") or {}
                lines.append(
                    "INIT "
                    + f"model={i.get('model','-')} "
                    + f"agent={i.get('agent','-')} "
                    + f"cwd={i.get('cwd','-')}"
                )
            elif ev.get("event") == "step_update":
                s = ev.get("step_update") or {}
                if s.get("step_type") == "tool":
                    lines.append(summarize_tool(ev))
                sub = s.get("subagent_info")
                if sub:
                    for a in sub.get("subagents", []) or []:
                        lines.append(
                            "SUBAGENT "
                            + f"type={a.get('type_name','-')} "
                            + f"role={a.get('role','-')} "
                            + f"id={a.get('conversation_id','-')}"
                        )
                if s.get("step_type") == "agent_response" and s.get("text_delta"):
                    t = redact(s["text_delta"]).strip().replace("\n"," ")
                    if t:
                        lines.append("AGENT " + (t[:500] + "..." if len(t) > 500 else t))
                usage = s.get("usage")
                if usage:
                    lines.append(
                        "USAGE "
                        + f"in={usage.get('input_tokens',0)} "
                        + f"out={usage.get('output_tokens',0)} "
                        + f"think={usage.get('thinking_tokens',0)} "
                        + f"total={usage.get('total_tokens',0)}"
                    )
            elif ev.get("event") == "result":
                final = ev.get("result") or {}
                usage = final.get("usage") or {}
                lines.append(
                    "RESULT "
                    + f"status={final.get('status','-')} "
                    + f"turns={final.get('num_turns',0)} "
                    + f"duration={final.get('duration_seconds',0)}s "
                    + f"total_tokens={usage.get('total_tokens',0)} "
                    + f"thinking_tokens={usage.get('thinking_tokens',0)}"
                )
    except FileNotFoundError:
        pass

    status_path.write_text("\n".join(lines[-200:]) + ("\n" if lines else ""), encoding="utf-8")

    if final is None:
        final = {
            "status": "failed" if exit_code != "0" else "needs_claude",
            "risk": "medium",
            "summary": "No terminal AGY result was captured.",
            "changed": [],
            "verified": [],
            "review": "not_done",
            "findings": [],
            "next": "Inspect the run logs."
        }
    result_path.write_text(json.dumps(final, ensure_ascii=False, indent=2), encoding="utf-8")

process()
PY

if [[ "$EXIT_CODE" -ne 0 ]]; then
  echo "Gemini run failed. Run: $RUN_ID" >&2
  echo "Log: $RUN_DIR" >&2
  exit "$EXIT_CODE"
fi

# Claude receives ONLY the compact terminal result.
jq -c '.' "$RESULT"
