#!/usr/bin/env bash
set -euo pipefail

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
# ~/.local/bin is put on PATH persistently by bootstrap.sh (managed block in
# ~/.bashrc / ~/.zshrc / fish conf.d). Because it is already on PATH in this
# process, the installers skip editing shell profiles themselves.
#
# Each installer is downloaded to a temp file, checked, then run; a failure of
# one does not prevent the other, but makes this script exit non-zero.
# ---------------------------------------------------------------------------

echo "    Running post-install tasks..."

PIXI_HOME="${PIXI_HOME:-$HOME/.pixi}"
LOCAL_BIN="$HOME/.local/bin"
export PATH="$LOCAL_BIN:$PIXI_HOME/bin:$PATH"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# True if $1 resolves to an npm global inside pixi's node env — the install
# method used by older versions of this repo (symlinked into ~/.pixi/bin).
is_legacy_npm_install() {
    local resolved
    resolved="$(readlink -f "$1" 2>/dev/null || echo "$1")"
    [[ "$resolved" == "$PIXI_HOME/envs/node/"* ]]
}

# install_native_cli NAME LABEL INSTALLER_URL NPM_PACKAGE [VAR=value ...]
#   Installs NAME into ~/.local/bin with its vendor's installer, unless a native
#   install is already there or NAME was installed some other way (left alone).
#   A legacy npm install from this repo does not count: it is replaced.
install_native_cli() {
    local name="$1" label="$2" url="$3" npm_pkg="$4"
    shift 4
    local native="$LOCAL_BIN/$name" existing="" installer="$TMP_DIR/$name-install.sh"

    if [[ -x "$native" ]]; then
        echo "    $label already installed: $("$native" --version 2>/dev/null || echo 'unknown version') ($native)"
        return 0
    fi
    existing="$(command -v "$name" 2>/dev/null || true)"
    if [[ -n "$existing" ]] && ! is_legacy_npm_install "$existing"; then
        echo "    $label found at $existing (installed outside this script) — leaving it as is."
        return 0
    fi

    echo "    Installing $label via the official native installer..."
    if ! curl --proto =https --tlsv1.2 -fsSL "$url" -o "$installer"; then
        echo "    ERROR: could not download the $label installer from $url" >&2
        return 1
    fi
    if [[ ! -s "$installer" ]]; then
        echo "    ERROR: the downloaded $label installer is empty." >&2
        return 1
    fi
    if ! env "$@" bash "$installer" </dev/null; then
        echo "    ERROR: the $label installer failed." >&2
        return 1
    fi
    if [[ ! -x "$native" ]]; then
        echo "    ERROR: the $label installer finished, but $native does not exist." >&2
        return 1
    fi
    echo "    $label installed at $native"

    if [[ -n "$existing" ]]; then
        echo "    WARNING: an old npm-based $label is still installed ($existing)." >&2
        echo "             Remove it with: npm uninstall -g $npm_pkg && rm -f $existing" >&2
    fi
}

failures=()

install_native_cli claude "Claude Code" \
    https://claude.ai/install.sh \
    @anthropic-ai/claude-code \
    || failures+=("Claude Code")

# CODEX_NON_INTERACTIVE=1 skips the installer's "Start Codex now?" prompt.
install_native_cli codex "Codex CLI" \
    https://github.com/openai/codex/releases/latest/download/install.sh \
    @openai/codex \
    CODEX_NON_INTERACTIVE=1 \
    || failures+=("Codex CLI")

# --- Uncomment to install additional tools via uv ---
# if command -v uv &>/dev/null; then
#     uv tool install ruff
# fi

if [[ ${#failures[@]} -gt 0 ]]; then
    echo "    ERROR: post-install failed for: ${failures[*]}" >&2
    exit 1
fi
echo "    Post-install tasks complete."
