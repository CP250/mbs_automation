#!/bin/bash

set -e

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
COMMANDS_DIR="$CLAUDE_DIR/commands"
SKILLS_DIR="$CLAUDE_DIR/skills"

echo "Installing mbs_automation..."

# Create directories if needed
mkdir -p "$COMMANDS_DIR"
mkdir -p "$SKILLS_DIR"

# Symlink commands into ~/.claude/commands/ so repo edits are live with no reinstall.
# (Copying + skip-if-exists left stale command files behind and silently dropped edits.)
echo "Installing slash commands..."
for file in "$SKILL_DIR/commands/"*.md; do
  name=$(basename "$file")
  dest="$COMMANDS_DIR/$name"
  ln -sf "$file" "$dest"
  echo "  linked $name"
done

# Link skill into ~/.claude/skills/
SKILL_LINK="$SKILLS_DIR/mbs_automation"
if [ -e "$SKILL_LINK" ]; then
  echo "Skill already linked at $SKILL_LINK"
else
  ln -s "$SKILL_DIR" "$SKILL_LINK"
  echo "Skill linked at $SKILL_LINK"
fi

echo ""
echo "Done. Restart Claude Code to activate the commands."
echo ""
echo "Next steps:"
echo "  1. In Obsidian, ensure the 'Claude Code MCP' plugin is enabled (live workspace link)."
echo "  2. Connect the Obsidian MCP (HTTP, not /ide): claude mcp add --transport http obsidian http://127.0.0.1:27200/mcp --header \"Authorization: Bearer <token-from-plugin>\" -s user  (see SETUP.md). The filesystem path works without this."
echo "  3. Run /obsidian-init to refine the vault's _CLAUDE.md against the live structure."
echo "  4. Run /obsidian-world to load context and confirm the foundation works."
