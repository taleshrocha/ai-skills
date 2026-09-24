#!/usr/bin/env python3
"""Stream a Gemini run's activity while it is still running.

Two outputs, for two audiences:

* stdout — one compact line per step, as it happens. This is what a
  backgrounded run accumulates, so the work is visible instead of the terminal
  sitting silent for minutes.
* a milestone file — a deliberately sparse subset (files written, subagents,
  failures, periodic heartbeats) suitable for one-notification-per-line
  monitoring. A per-step feed would be far too noisy for that.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import LineTailer, clip, redact  # noqa: E402
from digest import VERB, label_for  # noqa: E402

# Steps worth interrupting a human for.
MILESTONE_VERBS = {"write", "edit", "subagent"}
HEARTBEAT_EVERY = 15


def alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except (OSError, ProcessLookupError):
        return False
    return True


class Streamer:
    def __init__(self, milestones, attempt, quiet):
        self.started = time.time()
        self.seen = set()
        self.steps = 0
        self.milestones = Path(milestones) if milestones else None
        self.attempt = attempt
        self.quiet = quiet
        self.last = ""

    def elapsed(self):
        secs = int(time.time() - self.started)
        return f"{secs // 60:d}:{secs % 60:02d}"

    def emit(self, line):
        if not self.quiet:
            print(line, flush=True)

    def milestone(self, line):
        if not self.milestones:
            return
        with self.milestones.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")

    def handle(self, event):
        kind = event.get("event") or event.get("type")

        if kind == "init":
            info = event.get("init") or {}
            line = (f"[{self.elapsed()}] start   attempt {self.attempt} · "
                    f"model={info.get('model', '-')}")
            self.emit(line)
            self.milestone(line)
            return

        if kind == "result":
            result = event.get("result") or {}
            usage = result.get("usage") or {}
            line = (f"[{self.elapsed()}] stopped attempt {self.attempt} · "
                    f"{self.steps} steps · {usage.get('total_tokens', 0)} gemini tokens")
            self.emit(line)
            self.milestone(line)
            return

        if kind != "step_update":
            return

        step = event.get("step_update") or {}
        index = step.get("step_index")
        # AGY emits each step twice (ACTIVE then DONE); only the first is news.
        key = (index, step.get("step_type"))
        if key in self.seen:
            return
        self.seen.add(key)

        if step.get("step_type") != "tool":
            return

        self.steps += 1
        info = step.get("tool_info") or {}
        name = step.get("tool_name") or info.get("name") or "tool"
        verb = VERB.get(name, name)
        label = label_for(verb, info.get("parameters", step.get("parameters")))
        error = info.get("error") or step.get("error")

        line = f"[{self.elapsed()}] {verb:<9} {label}"
        if error:
            text = error if isinstance(error, str) else json.dumps(error, ensure_ascii=False)
            line += f"  <FAIL {clip(redact(text), 80)}>"
        self.emit(line)
        self.last = f"{verb} {label}"

        if verb in MILESTONE_VERBS or error:
            self.milestone(line)
        elif self.steps % HEARTBEAT_EVERY == 0:
            self.milestone(f"[{self.elapsed()}] …       {self.steps} steps, working "
                           f"(last: {clip(self.last, 70)})")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("events")
    parser.add_argument("--pid", type=int, default=0, help="stop once this process exits")
    parser.add_argument("--milestones", default="")
    parser.add_argument("--attempt", default="1")
    parser.add_argument("--quiet", action="store_true", help="milestones only, no stdout")
    args = parser.parse_args()

    streamer = Streamer(args.milestones, args.attempt, args.quiet)
    tailer = LineTailer(args.events)

    while True:
        running = alive(args.pid)
        for line in tailer.lines():
            try:
                streamer.handle(json.loads(line))
            except Exception:
                continue
        if not running:
            # The pass above already ran against the final file contents.
            return 0
        time.sleep(0.4)


if __name__ == "__main__":
    sys.exit(main())
