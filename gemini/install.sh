#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLAUDE_DIR="$HOME/.claude/skills/gemini"
GEMINI_DIR="$HOME/.gemini/config/agents"
BIN_DIR="$HOME/.local/bin"

BACKUP_ROOT="$HOME/.config/gemini-skill/backups/$(date +%Y%m%d-%H%M%S)"
BACKED=0

backup() {
  local dst="$1"
  if [[ -e "$dst" ]]; then
    BACKED=1
    mkdir -p "$BACKUP_ROOT"
    local safe="${dst#/}"
    safe="${safe//\//_}"
    cp -a "$dst" "$BACKUP_ROOT/$safe"
  fi
}

install_file() {
  local src="$1" dst="$2"
  backup "$dst"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}

mkdir -p "$CLAUDE_DIR/references" "$CLAUDE_DIR/scripts" "$GEMINI_DIR" "$BIN_DIR"

install_file "$ROOT/claude-skill/SKILL.md" "$CLAUDE_DIR/SKILL.md"
install_file "$ROOT/claude-skill/references/devops.md" "$CLAUDE_DIR/references/devops.md"
install_file "$ROOT/claude-skill/references/result-schema.json" "$CLAUDE_DIR/references/result-schema.json"
install_file "$ROOT/claude-skill/scripts/run-gemini.sh" "$CLAUDE_DIR/scripts/run-gemini.sh"
chmod +x "$CLAUDE_DIR/scripts/run-gemini.sh"

for f in "$ROOT"/gemini-agents/*.md; do
  install_file "$f" "$GEMINI_DIR/$(basename "$f")"
done

install_file "$ROOT/bin/gemini-watch" "$BIN_DIR/gemini-watch"
install_file "$ROOT/bin/gemini-status" "$BIN_DIR/gemini-status"
install_file "$ROOT/bin/gemini-runs" "$BIN_DIR/gemini-runs"
chmod +x "$BIN_DIR/gemini-watch" "$BIN_DIR/gemini-status" "$BIN_DIR/gemini-runs"

echo "Installed custom /gemini Skill:"
echo "  $CLAUDE_DIR"

echo "Installed Antigravity Gemini agents:"
echo "  $GEMINI_DIR"

echo "Installed monitoring commands:"
echo "  $BIN_DIR/gemini-watch"
echo "  $BIN_DIR/gemini-status"
echo "  $BIN_DIR/gemini-runs"

if [[ "$BACKED" -eq 1 ]]; then
  echo
  echo "Existing Gemini files backed up to:"
  echo "  $BACKUP_ROOT"
fi

echo
echo "Caveman was NOT modified."

echo
echo "Verify:"
echo "  agy models"
echo "  agy agents"

echo
echo "Use:"
echo "  /gemini ultra <task>"
echo "  /caveman /gemini ultra <task>"

echo
echo "Monitor from another terminal:"
echo "  gemini-watch"

echo
echo "For fully automated permissions only when intentionally desired:"
echo "  export AGY_UNSAFE=1"
