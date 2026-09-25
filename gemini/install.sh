#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLAUDE_DIR="$HOME/.claude/skills/gemini"
GEMINI_DIR="$HOME/.gemini/config/agents"
BIN_DIR="$HOME/.local/bin"

BACKUP_ROOT="$HOME/.config/gemini-skill/backups/$(date +%Y%m%d-%H%M%S)"
BACKED=0

backup() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  BACKED=1
  mkdir -p "$BACKUP_ROOT"
  local safe="${target#/}"
  cp -a "$target" "$BACKUP_ROOT/${safe//\//_}"
}

install_file() {
  local src="$1" dst="$2"
  backup "$dst"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}

mkdir -p "$CLAUDE_DIR/references" "$CLAUDE_DIR/scripts/lib" "$GEMINI_DIR" "$BIN_DIR"

install_file "$ROOT/claude-skill/SKILL.md"              "$CLAUDE_DIR/SKILL.md"
install_file "$ROOT/claude-skill/scripts/run-gemini.sh" "$CLAUDE_DIR/scripts/run-gemini.sh"

# Glob rather than list: a reference added to the repo but missing from this
# script leaves SKILL.md pointing at a file that is not on disk.
for f in "$ROOT"/claude-skill/references/*; do
  [[ -f "$f" ]] || continue
  install_file "$f" "$CLAUDE_DIR/references/$(basename "$f")"
done
for f in "$ROOT"/claude-skill/scripts/lib/*.py; do
  install_file "$f" "$CLAUDE_DIR/scripts/lib/$(basename "$f")"
done
chmod +x "$CLAUDE_DIR/scripts/run-gemini.sh"

# Antigravity discovers a global agent at ~/.gemini/config/agents/<name>/agent.md.
# Flat <name>.md files in that directory are NOT loaded — remove any left by an
# earlier version of this installer, or the orchestrator silently never appears.
for dir in "$ROOT"/gemini-agents/*/; do
  name="$(basename "$dir")"
  [[ -f "$dir/agent.md" ]] || continue
  if [[ -f "$GEMINI_DIR/$name.md" ]]; then
    backup "$GEMINI_DIR/$name.md"
    rm -f "$GEMINI_DIR/$name.md"
    echo "  removed stale flat agent file: $name.md"
  fi
  install_file "$dir/agent.md" "$GEMINI_DIR/$name/agent.md"
done

for cmd in gemini-watch gemini-status gemini-runs gemini-tail gemini-result; do
  install_file "$ROOT/bin/$cmd" "$BIN_DIR/$cmd"
  chmod +x "$BIN_DIR/$cmd"
done

echo
echo "Installed /gemini Skill:            $CLAUDE_DIR"
echo "Installed Antigravity agents:       $GEMINI_DIR/<name>/agent.md"
echo "Installed monitoring commands:      $BIN_DIR/{gemini-result,gemini-watch,gemini-tail,gemini-status,gemini-runs}"

if [[ "$BACKED" -eq 1 ]]; then
  echo
  echo "Existing files backed up to: $BACKUP_ROOT"
fi

cat <<'EOF'

Caveman was NOT modified.

Verify:
  agy models
  agy agents          # gemini-orchestrator and the 8 workers should be listed

Use:
  /gemini ultra <task>
  /caveman /gemini ultra <task>

Monitor live, from another terminal:
  gemini-watch

Fully automated permissions, only when intentionally desired:
  export AGY_UNSAFE=1
EOF
