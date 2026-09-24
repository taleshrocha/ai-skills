# Gemini Skill v12 — standalone

This package modifies **only the custom `/gemini` Skill and Gemini/Antigravity agents**.

It does NOT install, replace, edit, or configure `/caveman`.

## Goal

Use Gemini as a real external execution layer while keeping Gemini's live
progress OUT of Claude's context.

```text
Claude
  ↓
/gemini
  ↓
agy stream-json
  ↓
local run log
  ↓
Gemini orchestrator
  ├─ Java
  ├─ JS/TS
  ├─ tests
  ├─ docs
  └─ DevOps
  ↓
self-review + verification
  ↓
compact result → Claude
```

## Install

```bash
unzip gemini-skill-v12-only.zip
cd gemini-skill-v12
./install.sh
```

The installer:
- installs `~/.claude/skills/gemini`
- installs global Antigravity agents under `~/.gemini/config/agents`
- installs `gemini-watch`, `gemini-status`, and `gemini-runs` into `~/.local/bin`
- backs up existing Gemini files before replacing them
- never touches `~/.claude/skills/caveman`

## Use

Direct:

```text
/gemini ultra <task>
```

Stacked:

```text
/caveman /gemini ultra
<task>
```

Modes:
- `lite`: little Gemini
- `full`: balanced
- `ultra`: maximum useful Gemini delegation and best Claude-token economy

## Human-readable monitoring with no extra Claude context

When `/gemini` runs, its `stream-json` output is saved here:

```text
~/.local/state/gemini-skill/runs/<run-id>/
```

The Claude process receives only the final compact result.

From another terminal:

```bash
gemini-watch
```

or:

```bash
gemini-runs
gemini-status
gemini-watch <run-id>
```

You can see:
- tools
- commands
- subagents
- agent messages
- token usage
- final status

Because this is read directly from the local log, the progress stream is not
fed back into Claude and therefore does not consume additional Claude context.

## Credentials and permissions

Use normal existing credential sources.

Do not put tokens or private keys in prompts.

Default execution does not add `--dangerously-skip-permissions`.

For deliberate full automation:

```bash
export AGY_UNSAFE=1
```

Prefer Antigravity's scoped permissions when possible.

## Agy requirements

The wrapper uses current headless features:
- `-p`
- `--agent`
- `--effort`
- `--model`
- `--output-format stream-json`
- `--json-schema` for the final structured response

The stream format emits incremental tool/subagent/usage events, while the final
result contains the terminal response and usage metadata.

## Why this is more economical

Previous design:

```text
Gemini stream
→ Claude stdout
→ Claude consumes every progress event
```

This version:

```text
Gemini stream
→ local file
→ gemini-watch (your terminal)

final result
→ Claude
```

That is the intended architecture for token economy.
