# Operating notes

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
