#!/usr/bin/env python3
"""Deterministic completion gate for Gemini runs.

Gemini's own "done" is not trusted. A run only counts as finished when the
workspace actually changed, the diff carries no stubbed-out work, and every
verification command the contract declared exits 0. When the gate fails it
writes the retry prompt itself, so the correction loop costs Claude nothing.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import clip, redact  # noqa: E402

STUB_PATTERNS = [
    (r'\bTODO\b', 'TODO marker'),
    (r'\bFIXME\b', 'FIXME marker'),
    (r'\bXXX\b', 'XXX marker'),
    (r'NotImplementedError', 'unimplemented Python branch'),
    (r'UnsupportedOperationException', 'unimplemented Java branch'),
    (r'(?i)\bnot\s+implemented\b', '"not implemented" text'),
    (r'(?i)\bplaceholder\b', 'placeholder text'),
    (r'(?i)\bfor\s+now\b.*\breturn\b', 'temporary early return'),
    (r'(?i)//\s*(stub|dummy|mock it later)', 'stub comment'),
    (r'catch\s*\([^)]*\)\s*\{\s*\}', 'swallowed exception'),
    (r'(?i)\bcoming\s+soon\b', '"coming soon" text'),
]

VERIFY_TIMEOUT = int(os.environ.get("GEMINI_VERIFY_TIMEOUT", "900"))

# A stub marker only means "unfinished implementation" inside code. A TODO in a
# README, a log or a scratch file is ordinary prose, and scanning those produces
# false failures that send Gemini back to work for no reason.
CODE_SUFFIXES = {
    ".java", ".kt", ".kts", ".scala", ".groovy", ".gradle",
    ".py", ".rb", ".php", ".pl",
    ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".vue", ".svelte",
    ".go", ".rs", ".swift", ".cs", ".c", ".h", ".cpp", ".hpp", ".cc", ".m",
    ".sql", ".sh", ".bash", ".zsh",
    ".yml", ".yaml", ".tf", ".tfvars",
}
CODE_NAMES = {"Dockerfile", "Makefile", "Jenkinsfile"}


def is_code(path):
    if not path:
        return False
    name = path.rsplit("/", 1)[-1]
    if name in CODE_NAMES or name.startswith("Dockerfile"):
        return True
    dot = name.rfind(".")
    return dot > 0 and name[dot:].lower() in CODE_SUFFIXES


def git(repo, *args):
    try:
        proc = subprocess.run(["git", "-C", repo, *args],
                              capture_output=True, text=True, timeout=120)
        return proc.stdout if proc.returncode == 0 else ""
    except Exception:
        return ""


def is_repo(repo):
    return bool(git(repo, "rev-parse", "--is-inside-work-tree").strip())


def worktree_state(repo):
    status = git(repo, "status", "--porcelain")
    diff = git(repo, "diff", "HEAD")
    untracked = []
    for line in status.splitlines():
        if line.startswith("?? "):
            untracked.append(line[3:].strip())
    for path in sorted(untracked):
        full = Path(repo) / path
        if full.is_file() and full.stat().st_size < 400_000:
            try:
                diff += f"\n+++ b/{path}\n" + "\n".join(
                    "+" + l for l in full.read_text(errors="replace").splitlines())
            except Exception:
                pass
    return status, diff


def added_lines(diff):
    """Yield (path, added line), attributing each line to its file."""
    path = ""
    for line in diff.splitlines():
        if line.startswith("+++"):
            target = line[3:].strip()
            if target == "/dev/null":
                path = ""
            elif target.startswith(("a/", "b/")):
                path = target[2:]
            else:
                path = target
        elif line.startswith("+"):
            yield path, line[1:]


def scan_stubs(new_diff, baseline_diff):
    """Report stub markers this run introduced into code, ignoring pre-existing ones."""
    before = {line for _, line in added_lines(baseline_diff)}
    hits = []
    seen = set()
    for path, line in added_lines(new_diff):
        stripped = line.strip()
        if not stripped or stripped in before or not is_code(path):
            continue
        for pattern, why in STUB_PATTERNS:
            if re.search(pattern, stripped):
                hit = f"{why} in {path}: {clip(stripped, 110)}"
                if hit not in seen:
                    seen.add(hit)
                    hits.append(hit)
                break
        if len(hits) >= 15:
            break
    return hits


def run_verify(repo, commands):
    results = []
    for command in commands:
        try:
            proc = subprocess.run(["bash", "-lc", command], cwd=repo,
                                  capture_output=True, text=True,
                                  timeout=VERIFY_TIMEOUT)
            code, output = proc.returncode, (proc.stdout + proc.stderr)
        except subprocess.TimeoutExpired:
            code, output = 124, f"timed out after {VERIFY_TIMEOUT}s"
        except Exception as exc:
            code, output = 127, str(exc)
        tail = "\n".join(redact(output).splitlines()[-30:])
        results.append({"command": command, "exit": code, "tail": tail})
    return results


def cmd_snapshot(args):
    out = Path(args.run_dir)
    out.mkdir(parents=True, exist_ok=True)
    if not is_repo(args.repo):
        (out / "baseline.diff").write_text("", encoding="utf-8")
        (out / "baseline.hash").write_text("no-git", encoding="utf-8")
        return
    status, diff = worktree_state(args.repo)
    (out / "baseline.diff").write_text(diff, encoding="utf-8")
    (out / "baseline.hash").write_text(
        hashlib.sha256((status + diff).encode()).hexdigest(), encoding="utf-8")


def build_feedback(reasons, verify_results, stubs, result):
    parts = [
        "Your previous attempt did NOT pass the completion gate. "
        "The work is unfinished. Continue in the same workspace, fix every item "
        "below, and do not stop until all verification commands exit 0.",
        "",
        "GATE FAILURES:",
    ]
    parts += [f"- {r}" for r in reasons]

    failing = [v for v in verify_results if v["exit"] != 0]
    if failing:
        parts += ["", "FAILING VERIFICATION:"]
        for item in failing:
            parts.append(f"$ {item['command']}   (exit {item['exit']})")
            parts.append(item["tail"] or "(no output)")
            parts.append("")

    if stubs:
        parts += ["UNFINISHED CODE YOU INTRODUCED:"]
        parts += [f"- {s}" for s in stubs]
        parts.append("")

    claimed = (result or {}).get("summary")
    if claimed:
        parts += [f"You claimed: {clip(claimed, 400)}", ""]

    parts += [
        "RULES FOR THIS ATTEMPT:",
        "- Fix the root cause. Do not weaken, skip, delete or comment out tests.",
        "- Do not change the verification commands.",
        "- No TODO, FIXME, placeholder, stub or 'not implemented' in new code.",
        "- Re-run every verification command yourself and paste the real exit codes.",
        "- Only report success when all of them exit 0.",
    ]
    return "\n".join(parts)


def cmd_check(args):
    run_dir = Path(args.run_dir)
    reasons = []
    report = []

    try:
        result = json.loads(Path(args.result).read_text())
    except Exception:
        result = {}

    status = result.get("status") or "missing"
    escalate = status == "needs_claude"

    if not result:
        reasons.append("Gemini returned no structured result.")
    elif status == "failed":
        reasons.append(f"Gemini reported status=failed: {clip(result.get('summary', ''), 200)}")

    changed = True
    if is_repo(args.repo):
        new_status, new_diff = worktree_state(args.repo)
        baseline_hash = (run_dir / "baseline.hash").read_text().strip() \
            if (run_dir / "baseline.hash").exists() else ""
        now_hash = hashlib.sha256((new_status + new_diff).encode()).hexdigest()
        changed = now_hash != baseline_hash
        baseline_diff = (run_dir / "baseline.diff").read_text(errors="replace") \
            if (run_dir / "baseline.diff").exists() else ""

        if not args.readonly and not changed and not escalate:
            reasons.append("No file in the workspace changed. Nothing was implemented.")

        stubs = [] if args.allow_todo else scan_stubs(new_diff, baseline_diff)
        if stubs:
            reasons.append(f"{len(stubs)} unfinished-code marker(s) in the new diff.")
        # `git diff --stat` says nothing about new files, so count them separately;
        # otherwise a run that only adds files reports as having changed nothing.
        stat = git(args.repo, "diff", "--stat", "HEAD").strip().splitlines()
        parts = [stat[-1].strip()] if stat else []
        new_files = [l[3:].strip() for l in new_status.splitlines() if l.startswith("?? ")]
        if new_files:
            shown = ", ".join(new_files[:3]) + ("…" if len(new_files) > 3 else "")
            parts.append(f"{len(new_files)} new file(s): {shown}")
        report.append("  changed   " + ("; ".join(parts) if parts else "nothing changed"))
    else:
        stubs = []
        report.append("  changed   (not a git repository — diff gate skipped)")

    commands = []
    if args.verify_file and Path(args.verify_file).exists():
        commands = [l.strip() for l in Path(args.verify_file).read_text().splitlines()
                    if l.strip() and not l.strip().startswith("#")]

    # Verification commands are written relative to where the contract was
    # issued, which is not necessarily the repository root.
    verify_cwd = args.cwd or args.repo
    verify_results = run_verify(verify_cwd, commands) if commands else []
    for item in verify_results:
        mark = "ok  " if item["exit"] == 0 else "FAIL"
        report.append(f"  verify    [{mark}] {clip(item['command'], 90)}")
    if not commands:
        report.append("  verify    (no VERIFY commands declared — gate ran on diff only)")

    failed_cmds = [v["command"] for v in verify_results if v["exit"] != 0]
    if failed_cmds:
        reasons.append(f"{len(failed_cmds)} verification command(s) failed.")

    for stub in stubs[:5]:
        report.append(f"  stub      {clip(stub, 100)}")

    passed = not reasons
    verdict = {
        "pass": passed,
        "escalate": escalate,
        "reasons": reasons,
        "verify": [{"command": v["command"], "exit": v["exit"]} for v in verify_results],
        "stubs": stubs,
        "changed": changed,
    }
    (run_dir / "verdict.json").write_text(
        json.dumps(verdict, ensure_ascii=False, indent=2), encoding="utf-8")

    if not passed:
        (run_dir / "feedback.txt").write_text(
            build_feedback(reasons, verify_results, stubs, result), encoding="utf-8")

    head = "  gate      PASS" if passed else "  gate      FAIL — " + "; ".join(reasons)
    print("\n".join(report + [head]))
    return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    snap = sub.add_parser("snapshot")
    snap.add_argument("--run-dir", required=True)
    snap.add_argument("--repo", required=True)

    check = sub.add_parser("check")
    check.add_argument("--run-dir", required=True)
    check.add_argument("--repo", required=True)
    check.add_argument("--result", required=True)
    check.add_argument("--verify-file", default="")
    check.add_argument("--cwd", default="", help="directory to run verification commands in")
    check.add_argument("--readonly", action="store_true")
    check.add_argument("--allow-todo", action="store_true")

    args = parser.parse_args()
    if args.cmd == "snapshot":
        cmd_snapshot(args)
        return 0
    return cmd_check(args)


if __name__ == "__main__":
    sys.exit(main())
