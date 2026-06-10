#!/usr/bin/env bash
set -euo pipefail
umask 077

# ---------------------------------------------------------------------------
# post-install.sh — Things outside pixi's reach
#
# Claude Code is NOT published on conda-forge, so it cannot be managed
# declaratively through pixi-global.toml. We install it with Anthropic's
# official native installer, which drops a single self-contained binary at
# ~/.local/bin/claude:
#
#   * No Node.js / npm required at runtime (the binary does not invoke node).
#   * Keeps itself up to date via background auto-updates, in place.
#   * Avoids the old npm-global + symlink-into-~/.pixi/bin approach, which
#     left two copies of `claude` on disk (the npm one and the native one the
#     auto-updater writes to ~/.local/bin) and a stale, easily-broken symlink.
# ---------------------------------------------------------------------------

echo "    Running post-install tasks..."

LOCAL_BIN="$HOME/.local/bin"
# Make both pixi-installed tools and the native claude install reachable now.
export PATH="$LOCAL_BIN:$HOME/.pixi/bin:$PATH"

# --- Claude Code (official native installer) ---
if command -v claude &>/dev/null; then
    echo "    Claude Code already installed: $(claude --version 2>/dev/null || echo 'unknown version') ($(command -v claude))"
else
    echo "    Installing Claude Code via the official native installer..."
    curl --proto =https --tlsv1.2 -fsSL https://claude.ai/install.sh | bash

    if command -v claude &>/dev/null; then
        echo "    Claude Code installed: $(command -v claude)"
    elif [ -x "$LOCAL_BIN/claude" ]; then
        echo "    Claude Code installed at $LOCAL_BIN/claude"
    else
        echo "    WARNING: install finished but 'claude' was not found on PATH." >&2
        echo "    Ensure $LOCAL_BIN is on your PATH, then run 'claude doctor'." >&2
    fi
fi

# --- Uncomment to install additional tools via uv ---
# if command -v uv &>/dev/null; then
#     uv tool install ruff
# fi

echo "    Post-install tasks complete."
