#!/usr/bin/env bash
set -euo pipefail
umask 077

# ---------------------------------------------------------------------------
# post-install.sh — Things outside pixi's reach
#
# This script installs global tools that can't be managed declaratively
# through pixi-global.toml (e.g., npm globals, uv tools).
# ---------------------------------------------------------------------------

echo "    Running post-install tasks..."

# Ensure pixi-installed node/npm is on PATH
export PATH="$HOME/.pixi/bin:$PATH"

# --- Claude Code (npm global) ---
if command -v claude &>/dev/null; then
    echo "    Claude Code already installed: $(claude --version 2>/dev/null || echo 'unknown version')"
else
    echo "    Installing Claude Code via npm..."
    if command -v npm &>/dev/null; then
        npm install -g @anthropic-ai/claude-code
        echo "    Claude Code installed."
    else
        echo "    WARNING: npm not found — skipping Claude Code install."
        echo "    Run 'pixi global sync' first, then re-run this script."
    fi
fi

# --- Uncomment to install additional tools via uv ---
# if command -v uv &>/dev/null; then
#     uv tool install ruff
# fi

echo "    Post-install tasks complete."
