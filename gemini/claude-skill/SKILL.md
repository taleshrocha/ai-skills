---
name: gemini
description: Delegate bounded implementation, documentation, testing, research, Git/GitLab, SSH, Docker, Docker Compose and CI/CD work to Gemini through Antigravity. Works alone or stacked with other Skills; use /gemini lite, /gemini full, or /gemini ultra.
argument-hint: "[lite|full|ultra] <task>"
user-invocable: true
disable-model-invocation: true
---

# Gemini Delegator

Gemini is the execution layer for Claude.

## Mission

Spend Gemini tokens on bounded execution so Claude spends fewer tokens on routine
work, while keeping Claude responsible for difficult judgment and final quality.

```text
Claude → WHAT / WHY / architecture / acceptance criteria
Gemini → bounded HOW / implementation / tests / docs / DevOps
Claude → small Git-based final gate
```

## Modes

```text
LITE  = least Gemini use
FULL  = balanced
ULTRA = maximum useful Gemini delegation
```

Ultra is the Claude-token economy mode.

## Stacking

This Skill can be explicitly stacked with another Skill:

```text
/caveman /gemini ultra
<task>
```

When stacked, this Skill does not replace or modify the other Skill.

The trailing task is shared.

## Ultra behavior

For meaningful tasks:

1. Claude determines the architecture and boundaries.
2. Gemini receives a bounded execution contract.
3. Gemini orchestrates its own specialized subagents when useful.
4. Gemini implements, tests, self-reviews, and fixes routine issues.
5. Gemini returns one compact result.
6. Claude reviews the Git delta and only expands review when risk/evidence requires it.

Do not make Claude perform a full review of every Gemini change.

## Delegate aggressively in Ultra

Good candidates:
- Java/Spring implementation
- JavaScript/TypeScript/React implementation
- DTOs/entities/mappers
- repository/service/controller methods with clear requirements
- Javadoc/JSDoc/TSDoc
- tests
- repetitive refactors
- .gitlab-ci.yml
- Docker/Docker Compose
- GitLab API/CI work
- SSH/Linux diagnostics
- bounded remote fixes
- pipeline troubleshooting
- logs and documentation research

Keep in Claude:
- architecture
- ambiguity
- major business-rule decisions
- security decisions
- broad refactor strategy
- irreversible/consequential decisions
- final integration judgment

## Batching

If several bounded tasks are independent, ask one Gemini orchestrator run to
handle them and use Gemini subagents internally.

Prefer:

```text
Claude → one Gemini orchestrator
             ├─ Java
             ├─ frontend
             ├─ tests
             └─ docs
```

over multiple sequential Claude→Gemini calls.

## Gemini prompt contract

Give Gemini:

```text
OBJECTIVE:
<one concrete outcome>

CONTEXT:
<only necessary context>

SCOPE:
<files/modules/servers/projects>

REQUIREMENTS:
- ...

CONSTRAINTS:
- inspect existing patterns
- modify only assigned scope
- do not redesign unrelated code

ACCEPTANCE:
- ...

VERIFY:
- ...

RETURN:
- status
- changed targets
- verification
- risks / unknowns
```

Do not ask Gemini for chain-of-thought.

## Gemini-side verification

Gemini should:
- inspect its own diff
- run deterministic checks
- use its review worker when useful
- fix routine findings before returning

Claude should not duplicate that entire review.

## Claude-side Git review

When Gemini changes the current workspace:

```bash
git status --short
git diff --stat
git diff --check
git diff --unified=3
```

Review changed hunks first.

Only inspect surrounding code when:
- a hunk is ambiguous
- tests fail
- Gemini reports uncertainty
- the change is medium/high risk
- security/auth/data/production behavior is involved

Do not automatically open whole modified files.

## Review levels

LOW:
- docs/comments
- boilerplate
- simple DTO/mapper
- isolated mechanical changes

→ rely on deterministic checks + compact Git delta.

MEDIUM:
- normal service/repository/controller
- React changes
- Docker Compose
- CI changes

→ inspect changed hunks and affected symbols.

HIGH:
- production
- SSH writes on critical servers
- database mutation
- branch protection
- runner changes
- credentials/secrets
- authentication/authorization
- firewall/network exposure
- destructive commands
- broad refactors

→ deeper Claude verification.

## DevOps

Gemini is a first-class DevOps worker.

Supported:
- SSH
- Linux/systemd/journalctl
- Git
- GitLab REST API/glab
- CI/CD variables and environment scopes
- protected branches
- runners
- environments
- pipelines/jobs
- CI Lint
- Docker
- Docker Compose
- deployment scripts
- remote logs

Normal remote workflow:

```text
inspect → change → verify
```

For consequential changes:

```text
TARGET
ACTION
CURRENT STATE
EXPECTED STATE
ROLLBACK
POST-CHECK
```

## Credential safety

Use existing credential mechanisms.

Never print or return:
- GitLab tokens
- SSH private keys
- passwords
- API secrets
- masked CI variable values

Do not put secrets into prompts.

The local run logs are sanitized by the helper tools, but do not treat the
sanitizer as a substitute for safe commands.

## Human-readable monitoring WITHOUT Claude token cost

Do NOT pipe Gemini `stream-json` into Claude's stdout for monitoring.

Instead, the helper script stores the stream locally:

```text
~/.local/state/gemini-skill/runs/<run-id>/
  events.ndjson
  stderr.log
  status.log
  result.json
```

Then, from your own terminal:

```bash
gemini-watch
```

or:

```bash
gemini-watch <run-id>
```

This lets you see:
- orchestrator start
- tools
- commands
- subagents
- subagent completion
- errors
- final status
- Gemini token usage

Those events stay outside Claude's conversation.

For a one-shot status:

```bash
gemini-status
```

For all recent runs:

```bash
gemini-runs
```

## Agy execution

The helper invokes:

```bash
agy \
  --agent "${AGY_GEMINI_AGENT:-gemini-orchestrator}" \
  --effort "$EFFORT" \
  -p "$PROMPT" \
  --output-format stream-json
```

If a model is configured:

```bash
--model "$AGY_GEMINI_MODEL"
```

The full event stream is written to disk and only the final compact structured
result is returned to Claude.

## Permissions

Do not use `--dangerously-skip-permissions` by default.

If the user deliberately wants fully automated execution, set:

```bash
export AGY_UNSAFE=1
```

The helper then adds the flag.

For a safer setup, configure Antigravity's scoped permissions instead.

## Exact prompt invocation rule

Always pass the whole prompt as the value of `-p`:

```bash
agy -p "$(cat prompt.txt)"
```

Never put another option immediately after `-p` without a prompt value.

Correct:

```bash
agy --effort high -p "$(cat prompt.txt)"
```

Incorrect:

```bash
agy -p --effort high "$(cat prompt.txt)"
```

## Failures

If Gemini fails:
- inspect the local run log
- retry only when the cause is clear
- do not blindly repeat
- return `needs_claude` for architectural/security ambiguity

## Direct use

```text
/gemini lite <task>
/gemini full <task>
/gemini ultra <task>
```

Combined with Caveman:

```text
/caveman /gemini ultra
<task>
```

## Final principle

> Let Gemini spend tokens on execution. Let Claude spend tokens on decisions.
> Keep Gemini's live activity outside Claude's context, and keep Claude's review
> focused on Git deltas.
