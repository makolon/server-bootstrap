#!/usr/bin/env bash
set -euo pipefail
umask 077

# ---------------------------------------------------------------------------
# post-install.sh — Things outside pixi's reach
#
# Neither Claude Code nor Codex CLI is published on conda-forge, so they can't
# be managed declaratively through pixi-global.toml. We install each with its
# vendor's official native installer, which drops a single self-contained
# binary into ~/.local/bin (claude, codex):
#
#   * No Node.js / npm required at runtime (the binaries do not invoke node).
#   * Avoids the old npm-global + symlink-into-~/.pixi/bin approach, which
#     left two copies of the CLI on disk (the npm one and the native one) and a
#     stale, easily-broken symlink. npm-global under pixi's node prefix is also
#     fragile — `pixi global sync` can wipe it.
#
# Both installers target the same ~/.local/bin, which the bootstrap already
# puts on PATH, so neither one needs to touch your shell profiles here.
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

# --- Codex CLI (official native installer) ---
# OpenAI ships an install.sh that installs a self-contained binary to
# ~/.local/bin/codex (same location and philosophy as the claude installer
# above). CODEX_NON_INTERACTIVE=1 skips its "Start Codex now?" prompt so the
# install runs cleanly headless.
if command -v codex &>/dev/null; then
    echo "    Codex CLI already installed: $(codex --version 2>/dev/null || echo 'unknown version') ($(command -v codex))"
else
    echo "    Installing Codex CLI via the official native installer..."
    curl --proto =https --tlsv1.2 -fsSL \
        https://github.com/openai/codex/releases/latest/download/install.sh \
        | CODEX_NON_INTERACTIVE=1 bash

    if command -v codex &>/dev/null; then
        echo "    Codex CLI installed: $(command -v codex)"
    elif [ -x "$LOCAL_BIN/codex" ]; then
        echo "    Codex CLI installed at $LOCAL_BIN/codex"
    else
        echo "    WARNING: install finished but 'codex' was not found on PATH." >&2
        echo "    Ensure $LOCAL_BIN is on your PATH, then run 'codex --version'." >&2
    fi
fi

# --- Uncomment to install additional tools via uv ---
# if command -v uv &>/dev/null; then
#     uv tool install ruff
# fi

echo "    Post-install tasks complete."
