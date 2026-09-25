# Contract template

```text
OBJECTIVE:
<one concrete outcome>

CONTEXT:
<only what Gemini cannot cheaply discover itself>

SCOPE:
<files / modules / servers it may touch, and what it must not>

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
```

Everything after `===VERIFY===` is a shell command the gate runs itself.

## Cross-repository work

`--ref DIR` grounds a second repository read-only, for "build X the way Y does
it". Repeatable. Both directories are listed in the contract's workspace block
and passed to AGY with `--add-dir`. The gate only inspects the working
repository, so state the read-only constraint in the contract as well.

## Choosing verification commands

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
