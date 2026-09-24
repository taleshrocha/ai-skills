# Gemini Delegator

Claude architects. Gemini implements. A deterministic gate — not Claude, and not
Gemini's own opinion — decides whether the work is actually finished.

```text
Claude  → WHAT / WHY / scope / acceptance criteria
Gemini  → HOW / implementation / tests / docs / DevOps
Gate    → did the workspace change, is the diff free of stubs,
          do the verification commands exit 0?   ← loops Gemini back if not
Claude  → short risk-scaled review of the Git delta
```

The retry loop lives in the shell script. When Gemini stops early, the gate
sends it back with the exact failures **without spending a single Claude token**.

## Install

```bash
./install.sh
```

Installs the Skill to `~/.claude/skills/gemini`, the agents to
`~/.gemini/config/agents/<name>/agent.md`, and `gemini-watch`, `gemini-status`
and `gemini-runs` to `~/.local/bin`. Existing files are backed up first.
Caveman is not touched.

Verify with `agy agents` — `gemini-orchestrator` must be listed.

> Antigravity only discovers a global agent at `<name>/agent.md`. Flat
> `<name>.md` files in the agents directory are silently ignored; the installer
> removes any left by an older version.

## Use

```text
/gemini ultra <task>
/caveman /gemini ultra <task>
```

| Mode | Model | Attempts |
|---|---|---|
| `lite` | `gemini-3.8-flash-low` | 1 |
| `full` | `gemini-3.8-flash-medium` | 2 |
| `ultra` | `gemini-3.8-flash-high` | 3, last one escalating to `gemini-3.1-pro-high` |

Gemini 3.8 Flash leads the public coding lane and is built for long-horizon
agent loops, at a fraction of 3.1 Pro's price — so Flash carries the work and
Pro is held in reserve for the attempt that already failed twice.

## Calling the runner directly

```bash
~/.claude/skills/gemini/scripts/run-gemini.sh ultra <<'EOF'
OBJECTIVE:
  Implement pagination on the orders endpoint.

SCOPE:
  src/main/java/com/acme/orders/**

REQUIREMENTS:
  - page and size query parameters, defaults 0 and 20
  - size capped at 100
  - response carries total element count

===VERIFY===
./mvnw -q -pl orders test
EOF
```

Everything after `===VERIFY===` is a shell command the gate will run itself.
Flags: `--readonly` for reconnaissance, `--allow-todo` when a TODO is the
actual deliverable.

### The VERIFY block is the whole mechanism

The gate only has teeth when it has commands to run. Pick the narrowest command
that would genuinely fail if the work were wrong. A command that cannot fail
(`echo ok`, `true`) disables the gate while looking like it is enabled.

## Transparency

A run streams a timestamped line per step as it works, so nothing sits silent:

```text
[0:00] start   attempt 1 · model=gemini-3.8-flash-high
[0:22] write     src/orders/OrderService.java
[1:04] subagent  gemini-test-worker
  gate      PASS
```

Run it in the background and the harness shows that stream live. Watch it from
your own terminal with `gemini-tail` (sparse milestones, exits when the run
ends) or `gemini-watch` (full stream, follows retries). `gemini-status` and
`gemini-runs` summarise finished runs.

**Do not wire these into an agent notification loop.** Every notification
delivered to Claude is a full turn over the whole conversation — a run emitting
thirty milestones would cost thirty inference passes, far more than the Gemini
work itself. Live visibility belongs in the terminal and the task output panel,
where it costs nothing. Claude is woken once, at the end.

Everything is credential-redacted and line-capped. The untruncated event stream
stays on disk and never enters Claude's context.

## What the gate checks

| Check | Fails when |
|---|---|
| workspace changed | Gemini reported success without touching a file |
| stub scan | the new diff adds `TODO`, `FIXME`, `XXX`, `placeholder`, `not implemented`, `NotImplementedError`, `UnsupportedOperationException`, a stub comment or an empty `catch` |
| verification | any declared command exits non-zero |

Pre-existing markers in the working tree are ignored — only what this run
introduced counts. On failure the gate writes the retry prompt itself, with the
failing command's real output pasted in.

`needs_claude` is an escalation, not a failure: the loop stops immediately and
hands the decision back.

## Keeping Claude's spend down

- Claude does not read the codebase to write a contract. Reconnaissance is
  delegated too, with `--readonly`.
- Independent tasks go in one orchestrator run; it fans out to its own
  subagents rather than costing extra Claude round trips.
- Claude's review starts from `git diff --stat`, scaled to risk, and never
  re-checks what the gate already proved.
- AGY's result envelope (full response text plus the echoed JSON schema) is
  stripped down to the eight contracted fields before Claude sees it.

## Workers

`gemini-orchestrator` delegates to `gemini-java-worker`, `gemini-web-worker`,
`gemini-test-worker`, `gemini-docs-worker`, `gemini-devops-worker`,
`gemini-gitlab-worker`, `gemini-research-worker` and `gemini-review-worker`.

Workers run at `model: inherit`, so `--model` on the orchestrator sets the tier
for the whole tree.

## Configuration

| Variable | Effect |
|---|---|
| `AGY_GEMINI_MODEL` | pin a model; disables auto-escalation |
| `GEMINI_MAX_ATTEMPTS` | override the per-mode attempt budget |
| `GEMINI_ESCALATE_MODEL` | final-attempt model (default `gemini-3.1-pro-high`) |
| `GEMINI_DIGEST_LINES` | digest lines per attempt |
| `GEMINI_VERIFY_TIMEOUT` | seconds per verification command (default 900) |
| `GEMINI_ALLOW_TODO` | disable the stub scan |
| `AGY_GEMINI_AGENT` | orchestrator agent name |
| `AGY_UNSAFE=1` | add `--dangerously-skip-permissions` |

## Safety

Never put a secret in a contract. Digests and run logs are redacted, but
redaction is a backstop, not a strategy. `--dangerously-skip-permissions` is
off by default; prefer Antigravity's scoped permissions. High-risk operations —
production, database mutation, branch protection, runner config, secrets,
network exposure — need explicit authorization before the contract is sent.

## Layout

```text
claude-skill/
  SKILL.md                     loaded into Claude's context
  references/devops.md         DevOps playbook, read on demand
  references/result-schema.json enforced via agy --json-schema
  scripts/run-gemini.sh        contract → attempts → gate → digest
  scripts/lib/stream.py        live per-step + milestone streaming
  scripts/lib/digest.py        event stream → digest + compact result
  scripts/lib/gate.py          completion gate + retry-prompt author
  scripts/lib/common.py        redaction and clipping
gemini-agents/<name>/agent.md  orchestrator + 8 workers
bin/                           gemini-tail, gemini-watch, gemini-status, gemini-runs
```
