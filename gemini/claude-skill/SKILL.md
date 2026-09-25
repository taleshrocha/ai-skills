---
name: gemini
description: Delegate bounded implementation, documentation, testing, research, Git/GitLab, SSH, Docker, Docker Compose and CI/CD work to Gemini through Antigravity. Claude architects, Gemini implements, an automated gate enforces completion. Works alone or stacked with other Skills; use /gemini lite, /gemini full, or /gemini ultra.
argument-hint: "[lite|full|ultra] <task>"
user-invocable: true
disable-model-invocation: true
---

# Gemini Delegator

Gemini implements. A gate proves it. Claude decides and reviews.

## Delegation is not free — spend it where it pays

Every delegated task costs Claude the contract it writes, the verification it
designs, and the review at the end. Measured, that floor is a few thousand
tokens. Below it, delegating **loses**.

Delegate when at least one is true:

- the work is long, repetitive, or spans many files
- a real verification command already exists (test, typecheck, build, lint)
- answering it would otherwise mean reading a lot of the codebase

Do it directly when the change is small, obvious, confined to one or two files,
or when writing the contract would take as long as making the edit. Saying "this
is faster done directly" is the correct use of this Skill, not a failure of it.

## Modes

| Mode | Model | Attempts |
|---|---|---|
| `lite` | `gemini-3.8-flash-low` | 1 |
| `full` | `gemini-3.8-flash-medium` | 2 |
| `ultra` | `gemini-3.8-flash-high` | 3, final attempt escalates to `gemini-3.1-pro-high` |

## Running a task

Launch with Bash `run_in_background: true`, with a run id you choose:

```bash
GEMINI_RUN_ID=job-$(date +%H%M%S) ~/.claude/skills/gemini/scripts/run-gemini.sh ultra <<'EOF'
OBJECTIVE: <one concrete outcome>
SCOPE: <files it may touch, and what it must not>
REQUIREMENTS:
- <numbered, testable, complete>
ACCEPTANCE: <observable outcome>

===VERIFY===
<command that genuinely fails if the work is wrong>
EOF
```

Everything after `===VERIFY===` is run by the gate. The gate only has teeth when
those commands exist, and a command that cannot fail (`true`, `echo ok`) is
worse than none. Where no suitable command exists, write a checker script,
outside the repository, invoked by absolute path — **never let Gemini author
its own pass criteria**.

Full template, verification guidance and `--ref` cross-repo use:
`references/contract.md`.

Flags: `--readonly` (recon), `--ref DIR` (read-only reference repo, repeatable),
`--allow-todo`.

## Then be quiet, and read only the verdict

Every wake-up re-infers the whole conversation. It is the most expensive event
here — more than a minute of Gemini working.

- **Never arm a Monitor on a run.** One notification per event means one full
  Claude turn per event. It turns this Skill into a token amplifier.
- **Never narrate progress**, and never reprint the step timeline. The user
  already sees it streaming in the background task output.
- On completion **do not read the task output file.** Run `gemini-result <id>`:
  gate verdict, files touched, status, findings. Roughly fifteen lines instead
  of hundreds.

Read the full output only when the gate failed and `gemini-result` does not say
why.

The user watches live from their own terminal with `gemini-tail` (sparse) or
`gemini-watch` (every step). Neither involves Claude.

## Recon without reading the codebase

For anything needing broad knowledge of unfamiliar code, delegate the reading:

```bash
~/.claude/skills/gemini/scripts/run-gemini.sh ultra --readonly <<'EOF'
OBJECTIVE: Recon only. Change nothing.
QUESTION: <what you need to know>
RETURN: path:line citations and the test command for this module.
EOF
```

The briefing is written to disk and **deliberately not printed** — briefings run
to thousands of tokens. The run echoes only its `## KEY FACTS` block. Pull
individual sections with `grep`/`sed` if you need more; load the whole file only
when you genuinely must.

Claude opening source files "to be safe" is the largest avoidable cost in this
workflow.

## Review, scaled to risk

Start from `git diff --stat`, never whole files. Docs and boilerplate: trust the
gate. Services, controllers, React, CI: read the changed hunks. Production,
credentials, auth, data mutation, network exposure, broad refactors: read hunks
plus surrounding code and verify claims independently.

Do not re-review what the gate already proved. Details and failure handling:
`references/operations.md`.

## Safety

Never put a secret in a contract or ask for one back; redaction is a backstop,
not a strategy. `--dangerously-skip-permissions` is off unless `AGY_UNSAFE=1`.
High-risk operations — production, database mutation, branch protection, runner
config, secrets, network exposure — need explicit user authorization first.

## Stacking

```text
/caveman /gemini ultra
<task>
```

This Skill does not modify the other one. With caveman: compress your own chat
prose, never the contract — dropped articles and fragments are exactly where
scope and negation live, and Gemini implements the ambiguity. Relay gate output
verbatim.

## References

`references/contract.md` (template, verification, cross-repo) ·
`references/operations.md` (review levels, failure handling, env vars) ·
`references/devops.md` (SSH, Docker, GitLab playbook)
