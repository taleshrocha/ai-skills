---
name: gemini
description: Delegate bounded implementation, documentation, testing, research, Git/GitLab, SSH, Docker, Docker Compose and CI/CD work to Gemini through Antigravity. Claude architects, Gemini implements, an automated gate enforces completion. Works alone or stacked with other Skills; use /gemini lite, /gemini full, or /gemini ultra.
argument-hint: "[lite|full|ultra] <task>"
user-invocable: true
disable-model-invocation: true
---

# Gemini Delegator

Claude is the architect. Gemini is the implementer. A deterministic gate — not
Claude, and not Gemini's own opinion — decides whether the work is finished.

```text
Claude  → WHAT / WHY / scope / acceptance criteria
Gemini  → HOW / implementation / tests / docs / DevOps
Gate    → did the workspace actually change, is the diff free of stubs,
          do the verification commands exit 0?  (loops Gemini back if not)
Claude  → short risk-scaled review of the Git delta
```

The gate's retry loop runs inside the shell script. A Gemini attempt that fails
the gate is sent back with the exact failures **without costing Claude a single
token**.

## Modes

| Mode | Model | Attempts | Use for |
|---|---|---|---|
| `lite` | `gemini-3.8-flash-low` | 1 | trivial, mechanical, throwaway |
| `full` | `gemini-3.8-flash-medium` | 2 | normal bounded work |
| `ultra` | `gemini-3.8-flash-high` | 3 | real implementation; max delegation |

In `ultra`, if attempts 1 and 2 both fail the gate, the final attempt escalates
to `gemini-3.1-pro-high` automatically.

Default to `ultra` when the user did not say otherwise.

## Claude's token budget

**In ultra, do not read the codebase to write the contract.** Recon is
delegation too — send a read-only research contract first and get back a compact
briefing:

```bash
~/.claude/skills/gemini/scripts/run-gemini.sh ultra --readonly <<'EOF'
OBJECTIVE: Recon only. Do not change any file.
QUESTION: Where is order pricing computed, and what validates a discount code?
RETURN: path:line citations, the call path, the test command for this module.
EOF
```

Claude should open a source file only when the gate result or a risk trigger
makes it necessary. Reading files "to be safe" is the single largest Claude
token cost in this workflow.

## Running a task

Pipe the contract on stdin. Everything after a line reading `===VERIFY===` is
treated as shell commands the gate will run:

```bash
~/.claude/skills/gemini/scripts/run-gemini.sh ultra <<'EOF'
OBJECTIVE:
<one concrete outcome>

CONTEXT:
<only what Gemini cannot cheaply discover itself>

SCOPE:
<files / modules / servers / projects it may touch>

REQUIREMENTS:
- <numbered, testable, complete>

CONSTRAINTS:
- inspect existing patterns before writing
- modify only the assigned scope
- do not redesign unrelated code

ACCEPTANCE:
- <observable outcome, not "code written">

===VERIFY===
./mvnw -q -pl orders test
./mvnw -q -pl orders spotless:check
EOF
```

### The VERIFY block is the whole point

The gate only has teeth when it has commands to run. Always supply them.

- Pick the narrowest command that would actually fail if the work were wrong.
- Prefer a scoped test over a full build; prefer a real test over a lint.
- Never write a command that cannot fail (`echo ok`, `ls`, `true`).
- No commands available? Say so in the digest — the gate then only checks the
  diff, and Claude's review must be correspondingly deeper.

**The gate is exactly as strong as the checker, and writing the checker is
Claude's job — not Gemini's.** When a project has no suitable test command,
write one: a short script that asserts the structural and security properties
the change must hold, kept outside the repository so Gemini cannot edit it, and
invoked by absolute path.

Encode the invariants that would actually hurt, not only the shape of the
output. A checker that verifies a config parses and has the right keys will
happily pass a pipeline that copies production credentials into a Docker build
context. Ask what the worst plausible correct-looking result is, then assert
against it: secrets never entering a build context, an image, or a log;
cleanup steps that a later override cannot silently cancel; values that must
come from configuration rather than being hardcoded; fail-fast on the settings
whose absence degrades silently.

Flags: `--readonly` (recon; the briefing file is the deliverable and the gate
requires it), `--ref DIR` (a reference repository Gemini may read but not
modify; repeatable), `--allow-todo` (only when a TODO is genuinely the
deliverable).

### Working across repositories

`--ref` grounds a second repository read-only, for "build X the way Y does it":

```bash
run-gemini.sh ultra --ref ../reference-service <<'EOF'
...
EOF
```

Both directories are listed in the contract's workspace block and passed to
AGY with `--add-dir`. The gate still only inspects the working repository, so
a reference repo cannot be modified without the gate noticing nothing — state
the read-only constraint in the contract too.

## Run it live — never let the user watch a spinner

A real run takes minutes. Run it in the foreground and the user sees nothing at
all until it ends, which is the single worst property this Skill can have.
Always use both halves of this pattern:

**1. Launch in the background** with a run id you choose, so the log path is
known before the run exists:

```bash
GEMINI_RUN_ID=ci-$(date +%H%M%S) ~/.claude/skills/gemini/scripts/run-gemini.sh ultra <<'EOF'
...
EOF
```

Call it with Bash `run_in_background: true`. You are re-invoked when it exits.

**2. Arm a Monitor on the same run id**, in the same response:

```bash
gemini-tail ci-143207
```

`gemini-tail` emits one line per milestone and exits when the run finishes, so
each milestone becomes its own chat notification while the work happens. The
feed is deliberately sparse — start, files written, subagents, tool failures,
gate verdict, retries, and a heartbeat every 15 steps — because a per-step feed
would be throttled as a firehose.

What the user sees arriving live:

```text
[0:00] start   attempt 1 · model=gemini-3.8-flash-high
[0:22] write     src/orders/OrderService.java
[1:04] subagent  gemini-test-worker
[1:38] …       30 steps, working (last: cmd ./mvnw -q -pl orders test)
  gate      PASS
[done]   run ci-143207 finished
```

When the run ends you receive the full per-step timeline plus the gate report
and the JSON result. **Relay the timeline and gate report to the user verbatim
in a fenced code block** before your own commentary — it is already capped and
redacted, and it is the user's record of what Gemini actually did.

Then add your own short verdict: what changed, what you checked, what you did
not check, what risk you are carrying.

For a terminal-side view the user can also run `gemini-watch` (full event
stream, follows retries), `gemini-status` (one-shot summary) or `gemini-runs`
(recent runs and verdicts). Those read the log on disk and cost no context.

## Claude's review, scaled to risk

Start from the delta, never from whole files:

```bash
git diff --stat && git diff --check && git diff --unified=3
```

| Risk | Review |
|---|---|
| **low** — docs, comments, boilerplate, DTOs, mechanical edits | gate + diffstat only |
| **medium** — services, repositories, controllers, React, Compose, CI | read the changed hunks |
| **high** — production, credentials, auth, data mutation, branch protection, runners, network exposure, destructive commands, broad refactors | read hunks and surrounding code, verify claims independently |

Open surrounding code only when a hunk is ambiguous, the gate failed, Gemini
reported a finding or `needs_claude`, or the change is high risk.

Do not re-review what the gate already proved.

## Delegate vs. keep

**Delegate:** Java/Spring, JS/TS/React, DTOs, entities, mappers, service and
repository methods, Javadoc/JSDoc/TSDoc, tests, repetitive refactors,
`.gitlab-ci.yml`, Docker and Compose, GitLab API/CI work, SSH and Linux
diagnostics, bounded remote fixes, pipeline troubleshooting, log and
documentation research, and all reconnaissance.

**Keep in Claude:** architecture, genuine ambiguity, business-rule decisions,
security decisions, broad refactor strategy, irreversible decisions, final
integration judgment.

## Batching

Independent bounded tasks go in **one** orchestrator run, not several sequential
ones — the orchestrator fans out to its own subagents, and each extra Claude
round trip is pure overhead.

```text
Claude → one orchestrator ─┬─ java worker
                           ├─ web worker
                           ├─ test worker
                           └─ docs worker
```

## Failure handling

`status: failed` with `gate.pass: false` means Gemini exhausted its attempts.
Read `gate.reasons` first — it names the exact failure.

- Failing verification command → inspect the hunk it covers; usually a real bug.
- "No file changed" → the contract was unclear or the scope was wrong. Rewrite
  the contract; do not just re-run it.
- Unfinished-code markers → the requirements were too large for one contract.
  Split them.
- `needs_claude` → Gemini hit real ambiguity. Decide, then re-delegate with the
  decision written into the contract.

Never re-run an identical contract that already failed.

## Safety

Never put a secret in a contract. Never ask Gemini to return one. The digest and
the run logs are redacted, but redaction is a backstop, not a strategy.

`--dangerously-skip-permissions` is off by default. `export AGY_UNSAFE=1` only
when the user deliberately wants unattended execution; prefer Antigravity's
scoped permissions.

High-risk operations (production, database mutation, branch protection, runner
config, secrets, network exposure) need explicit user authorization before the
contract is sent — confirm in chat first.

## Tuning

| Variable | Effect |
|---|---|
| `AGY_GEMINI_MODEL` | pin a model; disables auto-escalation |
| `GEMINI_MAX_ATTEMPTS` | override the per-mode attempt budget |
| `GEMINI_ESCALATE_MODEL` | final-attempt model (default `gemini-3.1-pro-high`) |
| `GEMINI_DIGEST_LINES` | digest lines per attempt (default 40 in ultra) |
| `GEMINI_VERIFY_TIMEOUT` | seconds per verification command (default 900) |
| `GEMINI_ALLOW_TODO` | disable the stub scan |
| `AGY_GEMINI_AGENT` | orchestrator agent name |
| `AGY_UNSAFE=1` | add `--dangerously-skip-permissions` |

`references/devops.md` holds the DevOps playbook. Read it only when the task is
actually DevOps.

## Stacking

This Skill can be explicitly stacked with another Skill:

```text
/caveman /gemini ultra
<task>
```

When stacked, this Skill does not replace or modify the other Skill. The
trailing task is shared.

## Final principle

> Gemini spends tokens on execution. The gate spends compute on proof.
> Claude spends tokens only on decisions — and shows the user the trace.
