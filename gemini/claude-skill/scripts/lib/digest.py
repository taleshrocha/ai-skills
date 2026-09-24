#!/usr/bin/env python3
"""Turn an AGY stream-json event log into a short activity digest.

The digest is the only narrative Claude ever sees, so it is deliberately
lossy: one line per meaningful action, repeated reads collapsed, every
payload clipped. The untouched stream stays on disk for `gemini-watch`.

This module also extracts the agent's structured result out of AGY's envelope.
The envelope carries the whole echoed JSON schema and the full response text;
forwarding that to Claude would cost more than the digest itself.
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import clip, redact, short_path  # noqa: E402

VERB = {
    "view_file": "read", "read_file": "read", "Read": "read", "open_file": "read",
    "grep_search": "grep", "codebase_search": "grep", "search_in_file": "grep",
    "run_command": "cmd", "Bash": "cmd", "terminal": "cmd", "run_terminal_cmd": "cmd",
    "write_to_file": "write", "Write": "write", "create_file": "write",
    "replace_file_content": "edit", "multi_replace_file_content": "edit", "Edit": "edit",
    "invoke_subagent": "subagent", "manage_subagents": "subagent", "browser_subagent": "subagent",
    "manage_task": "task", "send_message": "msg",
    "list_dir": "ls", "find_by_name": "ls", "Glob": "ls",
    "browser_navigate": "web", "read_url_content": "web", "search_web": "web",
}

PATH_KEYS = ("file_path", "path", "AbsolutePath", "TargetFile", "abs_path",
             "filename", "file", "Path", "target_file")
CMD_KEYS = ("CommandLine", "command", "Command", "cmd", "commands")
QUERY_KEYS = ("Pattern", "query", "Query", "pattern", "SearchTerm", "search_term")
AGENT_KEYS = ("agent", "agent_name", "subagent", "type_name", "TypeName", "name")
TASK_KEYS = ("TaskId", "task_id", "Task")

COLLAPSIBLE = {"read", "grep", "ls", "task"}
SCHEMA_KEYS = ("status", "risk", "summary", "changed", "verified", "review", "findings", "next")
LIST_KEYS = ("changed", "verified", "findings")


def label_for(verb, params):
    if not isinstance(params, dict):
        return clip(redact(str(params or "")), 90)
    if verb == "cmd":
        for key in CMD_KEYS:
            if params.get(key):
                return clip(redact(str(params[key])), 110)
    if verb == "task":
        action = params.get("Action") or params.get("action") or "task"
        target = ""
        for key in TASK_KEYS:
            if params.get(key):
                target = str(params[key]).rsplit("/", 1)[-1]
                break
        return clip(f"{action} {target}".strip(), 60)
    if verb == "subagent":
        for key in AGENT_KEYS:
            if params.get(key):
                return clip(redact(str(params[key])), 60)
    for key in PATH_KEYS:
        if params.get(key):
            return clip(short_path(redact(str(params[key]))), 80)
    for key in QUERY_KEYS:
        if params.get(key):
            return clip(redact(str(params[key])), 70)
    return clip(redact(json.dumps(params, ensure_ascii=False)), 80)


def walk(events_path):
    """Yield parsed events, tolerating partial lines from a live stream."""
    try:
        raw_text = Path(events_path).read_text(errors="replace")
    except FileNotFoundError:
        return
    for line in raw_text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except Exception:
            continue


def is_prose(text):
    """Keep human-readable narration; drop fragments of the JSON report."""
    if len(text) < 15:
        return False
    if any(marker in text for marker in ('":', '" :', '{"', '[ "', '["')):
        return False
    return text.count('"') < 4


def collect(events_path):
    """Fold the event stream into one row per step.

    AGY emits each step twice — once ACTIVE, once DONE — so rows are keyed by
    step_index and the later event wins. The DONE event is the useful one: it
    carries the tool's output and any error.
    """
    steps = {}
    order = []
    meta = {}
    final = None

    for event in walk(events_path):
        kind = event.get("event") or event.get("type")

        if event.get("conversation_id") and "conversation_id" not in meta:
            meta["conversation_id"] = event["conversation_id"]

        if kind == "init":
            info = event.get("init") or {}
            meta["model"] = info.get("model", "-")
            meta["agent"] = info.get("agent", "-")
            meta["cwd"] = info.get("cwd", "-")
            continue

        if kind == "result":
            final = event.get("result") or {}
            continue

        if kind != "step_update":
            continue

        step = event.get("step_update") or {}
        index = str(step.get("step_index", len(order)))
        if index not in steps:
            order.append(index)
        steps[index] = step

        usage = step.get("usage")
        if isinstance(usage, dict) and usage.get("total_tokens"):
            meta["tokens"] = max(meta.get("tokens", 0), usage["total_tokens"])

    rows = []
    notes = 0
    for index in order:
        step = steps[index]
        step_type = step.get("step_type")
        info = step.get("tool_info") or {}

        if step_type == "tool":
            name = step.get("tool_name") or info.get("name") or "tool"
            verb = VERB.get(name, name)
            params = info.get("parameters", step.get("parameters"))
            error = info.get("error") or step.get("error")
            flag = ""
            if error:
                text = error if isinstance(error, str) else json.dumps(error, ensure_ascii=False)
                flag = "FAIL " + clip(redact(text), 90)
            rows.append([verb, label_for(verb, params), flag, 1])

        elif step_type == "agent_response":
            text = clip(redact(step.get("text_delta") or step.get("text") or ""), 160)
            if is_prose(text) and notes < 10:
                notes += 1
                rows.append(["note", text, "", 1])

        for agent in (step.get("subagent_info") or {}).get("subagents", []) or []:
            rows.append(["subagent", clip(agent.get("type_name") or agent.get("role") or "-", 60),
                         clip(agent.get("role") or "", 50), 1])

    return rows, meta, final


def collapse(rows):
    """Merge repeated actions into one counted line."""
    merged = []
    for verb, label, flag, count in rows:
        if merged and not flag and not merged[-1][2] and merged[-1][0] == verb:
            same_label = merged[-1][1] == label
            if same_label or verb in COLLAPSIBLE:
                merged[-1][3] += count
                if not same_label and merged[-1][3] == 2:
                    merged[-1][1] += ", " + label
                continue
        merged.append([verb, label, flag, count])
    return merged


def extract_payload(text):
    """Pull the structured result out of the agent's free-text response."""
    if not isinstance(text, str):
        return None
    best = None
    for start, char in enumerate(text):
        if char != "{":
            continue
        depth = 0
        for pos in range(start, len(text)):
            if text[pos] == "{":
                depth += 1
            elif text[pos] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        candidate = json.loads(text[start:pos + 1])
                    except Exception:
                        candidate = None
                    if isinstance(candidate, dict) and "status" in candidate \
                            and "summary" in candidate:
                        best = candidate
                    break
    return best


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [clip(v if isinstance(v, str) else json.dumps(v, ensure_ascii=False), 300)
                for v in value][:50]
    return [clip(str(value), 300)]


def compact_result(final, meta):
    """Strip AGY's envelope down to the eight fields the contract asked for."""
    final = final or {}
    payload = extract_payload(final.get("response", "")) or {}
    result = {}

    for key in SCHEMA_KEYS:
        if key in LIST_KEYS:
            result[key] = as_list(payload.get(key))
        elif key in payload:
            value = payload[key]
            result[key] = clip(value if isinstance(value, str)
                               else json.dumps(value, ensure_ascii=False), 1200)
        else:
            result[key] = ""

    status = str(result.get("status") or "").lower()
    if status not in ("success", "failed", "needs_claude"):
        # No parseable report. The envelope only says the CLI call itself
        # succeeded, which says nothing about whether the work is done.
        status = "failed"
        result["findings"] = (result["findings"] +
                              ["No structured result parsed from Gemini's response."])[:12]
        result["review"] = "not_done"
    result["status"] = status

    if not result.get("risk"):
        result["risk"] = "medium"
    if result.get("review") not in ("clean", "findings", "not_done"):
        result["review"] = "not_done"
    if result.get("next") in ("", "[]", "{}", "null", None):
        result["next"] = "none"

    usage = final.get("usage") or {}
    result["gemini_tokens"] = usage.get("total_tokens", meta.get("tokens", 0))
    return result


def render(rows, meta, final, attempt, wall, max_lines, run_id, mode):
    out = [f"── gemini run {run_id} · attempt {attempt} · {mode} · "
           f"model={meta.get('model') or '-'} ──"]

    rows = collapse(rows)
    if len(rows) > max_lines:
        head = max_lines // 3
        dropped = len(rows) - max_lines
        # Keep the tail: the end of a run carries verification and fixes.
        rows = (rows[:head]
                + [["…", f"{dropped} steps omitted — full stream: gemini-watch {run_id}", "", 1]]
                + rows[-(max_lines - head):])

    for verb, label, flag, count in rows:
        suffix = f"  (x{count})" if count > 1 else ""
        line = f"  {verb:<9} {label}{suffix}"
        if flag:
            line += f"  <{flag}>"
        out.append(line)

    usage = (final or {}).get("usage") or {}
    tokens = usage.get("total_tokens", meta.get("tokens", 0))
    if final:
        out.append(f"── gemini stopped: turns={final.get('num_turns', 0)} wall={wall}s "
                   f"gemini_tokens={tokens} ──")
    else:
        out.append(f"── gemini ended with no terminal result (wall={wall}s) ──")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("events")
    parser.add_argument("--run-id", default="-")
    parser.add_argument("--mode", default="ultra")
    parser.add_argument("--attempt", default="1")
    parser.add_argument("--wall", default="0")
    parser.add_argument("--max-lines", type=int, default=40)
    parser.add_argument("--out-result", default="")
    parser.add_argument("--out-meta", default="")
    args = parser.parse_args()

    rows, meta, final = collect(args.events)

    if args.out_result:
        Path(args.out_result).write_text(
            json.dumps(compact_result(final, meta), ensure_ascii=False, indent=2),
            encoding="utf-8")
    if args.out_meta:
        Path(args.out_meta).write_text(
            json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")

    print(render(rows, meta, final, args.attempt, args.wall,
                 args.max_lines, args.run_id, args.mode))


if __name__ == "__main__":
    main()
