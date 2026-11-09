#!/usr/bin/env bash
# bootstrap.sh — sudo-free, idempotent provisioning of a Linux server under $HOME.
#
# Run from a local clone (`bash bootstrap.sh`) or via `curl ... | bash`.
#
# Environment variables:
#   PIXI_HOME                    pixi's home directory (default: ~/.pixi)
#   BOOTSTRAP_NO_SHELL_CONFIG=1  do not write the PATH block into ~/.bashrc,
#                                ~/.zshrc and fish's conf.d
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/makolon/server-bootstrap/main"
NVIM_CONFIG_REPO="https://github.com/makolon/kickstart-modular.nvim.git"
TOTAL_STEPS=7

PIXI_HOME="${PIXI_HOME:-$HOME/.pixi}"
PIXI_BIN="$PIXI_HOME/bin"
LOCAL_BIN="$HOME/.local/bin"
MANIFEST_DIR="$PIXI_HOME/manifests"
MANIFEST_PATH="$MANIFEST_DIR/pixi-global.toml"
FALLBACK_BIN="${XDG_DATA_HOME:-$HOME/.local/share}/server-bootstrap/fallback-bin"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/server-bootstrap"
NVIM_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
FISH_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/server-bootstrap.fish"
BLOCK_BEGIN="# >>> server-bootstrap >>>"
BLOCK_END="# <<< server-bootstrap <<<"
SHELL_CONFIG=1
[[ "${BOOTSTRAP_NO_SHELL_CONFIG:-0}" == 1 ]] && SHELL_CONFIG=0

# Tools installed by previous runs must be reachable even when the caller's
# PATH lacks them (e.g. the non-interactive shell of `ssh host cmd`, where
# ~/.bashrc returns before pixi's PATH line). The fallback toolchain goes LAST
# so a system gcc/make/git always wins over pixi's.
export PATH="$LOCAL_BIN:$PIXI_BIN:$PATH:$FALLBACK_BIN"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Directory of the local clone we are running from, if any. Under
# `curl | bash` or `bash <(curl ...)` there is no script file, and files are
# fetched from GitHub — never picked up from the current directory.
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

WARNINGS=()

step() {
    local n="$1"; shift
    echo ""
    echo "==> [$n/$TOTAL_STEPS] $*"
}

warn() {
    echo "    WARNING: $*" >&2
    WARNINGS+=("$*")
}

# fetch_file NAME DEST — copy NAME from the local clone, or download it.
fetch_file() {
    local name="$1" dest="$2"
    if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$name" ]]; then
        cp "$SCRIPT_DIR/$name" "$dest"
    else
        echo "    Downloading $name from $REPO_RAW ..."
        curl --proto =https --tlsv1.2 -fsSL "$REPO_RAW/$name" -o "$dest"
    fi
    if [[ ! -s "$dest" ]]; then
        echo "ERROR: $name is empty." >&2
        exit 1
    fi
}

# Names of the environments declared in a pixi global manifest.
env_names() {
    sed -nE 's/^[[:space:]]*\[envs\."?([A-Za-z0-9_-]+)"?[].].*/\1/p' "$1" | sort -u
}

# Render a path for a shell startup file, $HOME-relative when possible.
home_rel() {
    # shellcheck disable=SC2016  # $HOME is expanded later, by the shell
    case "$1" in
        "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

posix_block() {
    local pixi_bin local_bin fallback
    pixi_bin="$(home_rel "$PIXI_BIN")"
    local_bin="$(home_rel "$LOCAL_BIN")"
    fallback="$(home_rel "$FALLBACK_BIN")"
    cat <<EOF
$BLOCK_BEGIN
# Managed by server-bootstrap: bootstrap.sh rewrites this block (set
# BOOTSTRAP_NO_SHELL_CONFIG=1 to stop that). ~/.local/bin (Claude Code, Codex)
# and pixi tools come first; pixi's gcc/make/git fallbacks come last so the
# system toolchain always wins.
for _sb_dir in "$pixi_bin" "$local_bin"; do
    case ":\$PATH:" in *":\$_sb_dir:"*) ;; *) PATH="\$_sb_dir:\$PATH" ;; esac
done
case ":\$PATH:" in *":$fallback:"*) ;; *) PATH="\$PATH:$fallback" ;; esac
unset _sb_dir
export PATH
$BLOCK_END
EOF
}

fish_block() {
    local pixi_bin local_bin fallback
    pixi_bin="$(home_rel "$PIXI_BIN")"
    local_bin="$(home_rel "$LOCAL_BIN")"
    fallback="$(home_rel "$FALLBACK_BIN")"
    cat <<EOF
# Managed by server-bootstrap: bootstrap.sh rewrites this file (set
# BOOTSTRAP_NO_SHELL_CONFIG=1 to stop that). Same PATH order as the bash/zsh block.
for _sb_dir in "$pixi_bin" "$local_bin"
    contains -- \$_sb_dir \$PATH; or set -gx PATH \$_sb_dir \$PATH
end
contains -- "$fallback" \$PATH; or set -gx PATH \$PATH "$fallback"
set -e _sb_dir
EOF
}

# write_if_changed FILE — replace FILE's content with stdin (in place, so a
# symlinked dotfile keeps pointing where it did) unless it is already equal.
write_if_changed() {
    local file="$1" new="$TMP_DIR/new-content"
    cat > "$new"
    if cmp -s "$new" "$file"; then
        echo "    $file already up to date."
    else
        cat "$new" > "$file"
        echo "    Updated $file"
    fi
}

# upsert_block FILE — add the managed PATH block to FILE, or replace it.
upsert_block() {
    local file="$1" block="$TMP_DIR/block"
    posix_block > "$block"
    if [[ -f "$file" ]] && grep -qxF "$BLOCK_BEGIN" "$file" && grep -qxF "$BLOCK_END" "$file"; then
        awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" -v f="$block" '
            $0 == b { if (!done) { while ((getline line < f) > 0) print line; done = 1 }
                      skip = 1; next }
            skip && $0 == e { skip = 0; next }
            !skip { print }' "$file" | write_if_changed "$file"
    else
        { if [[ -s "$file" ]]; then cat "$file"; echo; fi; cat "$block"; } | write_if_changed "$file"
    fi
}

# ---------------------------------------------------------------------------
# 1. Install pixi
# ---------------------------------------------------------------------------
step 1 "Ensuring pixi is installed..."

if command -v pixi &>/dev/null; then
    echo "    pixi already installed: $(pixi --version) ($(command -v pixi))"
else
    echo "    Downloading pixi installer..."
    curl --proto =https --tlsv1.2 -fsSL https://pixi.sh/install.sh -o "$TMP_DIR/pixi-install.sh"
    if [[ ! -s "$TMP_DIR/pixi-install.sh" ]]; then
        echo "ERROR: Downloaded pixi installer is empty." >&2
        exit 1
    fi
    installer_env=(PIXI_HOME="$PIXI_HOME")
    # Step 4 manages PATH in the shell startup files; don't let the installer
    # add a second, differently-ordered PATH line.
    [[ "$SHELL_CONFIG" == 1 ]] && installer_env+=(PIXI_NO_PATH_UPDATE=1)
    echo "    Running pixi installer..."
    env "${installer_env[@]}" bash "$TMP_DIR/pixi-install.sh"
    if ! command -v pixi &>/dev/null; then
        echo "ERROR: pixi not found in $PIXI_BIN after running its installer." >&2
        exit 1
    fi
    echo "    pixi installed: $(command -v pixi)"
fi

# ---------------------------------------------------------------------------
# 2. Install the pixi-global.toml manifest
# ---------------------------------------------------------------------------
step 2 "Installing pixi-global.toml manifest..."

mkdir -p "$MANIFEST_DIR"
NEW_MANIFEST="$TMP_DIR/pixi-global.toml"
fetch_file pixi-global.toml "$NEW_MANIFEST"

if [[ -f "$MANIFEST_PATH" ]] && cmp -s "$NEW_MANIFEST" "$MANIFEST_PATH"; then
    echo "    Manifest already up to date: $MANIFEST_PATH"
else
    if [[ -f "$MANIFEST_PATH" ]]; then
        # Never overwrite an earlier backup: it may be the only copy of a
        # manifest with hand-added environments.
        backup_base="$MANIFEST_PATH.bak.$(date +%Y%m%d-%H%M%S)"
        backup="$backup_base"
        n=1
        while [[ -e "$backup" ]]; do
            backup="$backup_base.$n"
            n=$((n + 1))
        done
        cp -p "$MANIFEST_PATH" "$backup"
        echo "    Backed up existing manifest to $backup"

        removed="$(comm -23 <(env_names "$MANIFEST_PATH") <(env_names "$NEW_MANIFEST") | paste -sd ' ' -)"
        if [[ -n "$removed" ]]; then
            warn "pixi environments not in the repo manifest are REMOVED by 'pixi global sync': $removed" \
                 "— add them to pixi-global.toml in the repo to keep them (previous manifest: $backup)."
        fi
    fi
    cp "$NEW_MANIFEST" "$MANIFEST_PATH"
    echo "    Manifest installed at $MANIFEST_PATH"
fi

# ---------------------------------------------------------------------------
# 3. Sync pixi global environments
# ---------------------------------------------------------------------------
step 3 "Running pixi global sync..."

pixi global sync
echo "    pixi global sync complete."

# ---------------------------------------------------------------------------
# 4. PATH: fallback toolchain + shell startup files
# ---------------------------------------------------------------------------
step 4 "Configuring PATH (fallback toolchain, shell startup files)..."

# Plain-named wrappers for pixi's toolchain, at the END of PATH: used only
# where the system has no gcc/cc/make/git (see [envs.toolchain]).
mkdir -p "$FALLBACK_BIN"
for pair in gcc:pixi-gcc cc:pixi-gcc make:pixi-make git:pixi-git; do
    name="${pair%%:*}"
    target="$PIXI_BIN/${pair#*:}"
    if [[ -x "$target" ]]; then
        # shellcheck disable=SC2016  # "$@" belongs to the generated wrapper
        printf '#!/bin/sh\n# Managed by server-bootstrap: fallback %s, used only when no system %s\n# precedes this directory on PATH (see [envs.toolchain] in pixi-global.toml).\nexec "%s" "$@"\n' \
            "$name" "$name" "$target" > "$FALLBACK_BIN/$name"
        chmod 755 "$FALLBACK_BIN/$name"
    else
        rm -f "$FALLBACK_BIN/$name"
    fi
done
for tool in gcc make git; do
    echo "    $tool -> $(command -v "$tool" || echo 'not found')"
done

SHELL_FILES=()
if [[ "$SHELL_CONFIG" == 1 ]]; then
    upsert_block "$HOME/.bashrc"
    SHELL_FILES+=("$HOME/.bashrc")
    ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
    if [[ -f "$ZSHRC" || "${SHELL:-}" == */zsh ]]; then
        upsert_block "$ZSHRC"
        SHELL_FILES+=("$ZSHRC")
    fi
    mkdir -p "$(dirname "$FISH_CONF")"
    fish_block | write_if_changed "$FISH_CONF"
    SHELL_FILES+=("$FISH_CONF")
else
    echo "    BOOTSTRAP_NO_SHELL_CONFIG=1 — shell startup files left untouched."
fi

# ---------------------------------------------------------------------------
# 5. Clone Neovim config
# ---------------------------------------------------------------------------
step 5 "Setting up Neovim configuration..."

NVIM_CONFIG_READY=0
if [[ -e "$NVIM_CONFIG/.git" ]]; then
    echo "    Neovim config already present at $NVIM_CONFIG — skipping."
    NVIM_CONFIG_READY=1
elif [[ -L "$NVIM_CONFIG" || -f "$NVIM_CONFIG" ]] \
     || { [[ -d "$NVIM_CONFIG" ]] && [[ -n "$(ls -A "$NVIM_CONFIG")" ]]; }; then
    warn "$NVIM_CONFIG exists and is not a git checkout, so it was left untouched" \
         "(kickstart-modular.nvim not installed). Move it aside and re-run to use it."
else
    echo "    Cloning kickstart-modular.nvim..."
    git clone "$NVIM_CONFIG_REPO" "$NVIM_CONFIG"
    echo "    Neovim config cloned."
    NVIM_CONFIG_READY=1
fi

# ---------------------------------------------------------------------------
# 6. Bootstrap Neovim plugins
# ---------------------------------------------------------------------------
step 6 "Bootstrapping Neovim plugins (may take a minute)..."

if [[ "$NVIM_CONFIG_READY" != 1 ]]; then
    echo "    Skipped: no kickstart-modular.nvim config was set up."
elif ! command -v nvim &>/dev/null; then
    warn "nvim not found on PATH (expected $PIXI_BIN/nvim); plugin sync skipped."
else
    mkdir -p "$STATE_DIR"
    NVIM_LOG="$STATE_DIR/nvim-plugin-sync.log"
    if nvim --headless "+Lazy! sync" +qa </dev/null >"$NVIM_LOG" 2>&1; then
        echo "    Neovim plugins synced (log: $NVIM_LOG)."
    else
        echo "    Last lines of $NVIM_LOG:"
        tail -n 20 "$NVIM_LOG" | sed 's/^/      /'
        warn "Neovim plugin sync failed (log: $NVIM_LOG). Open nvim to finish plugin setup."
    fi
fi

# ---------------------------------------------------------------------------
# 7. Run post-install
# ---------------------------------------------------------------------------
step 7 "Running post-install tasks..."

POST_INSTALL_OK=1
fetch_file post-install.sh "$TMP_DIR/post-install.sh"
if ! PIXI_HOME="$PIXI_HOME" bash "$TMP_DIR/post-install.sh"; then
    POST_INSTALL_OK=0
    warn "post-install.sh failed (see the messages above)."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
if [[ "$POST_INSTALL_OK" == 1 ]]; then
    echo "  Bootstrap complete!"
else
    echo "  Bootstrap finished with errors"
fi
echo "========================================"
echo ""
echo "Installed environments:"
pixi global list 2>/dev/null || echo "  (run 'pixi global list' to see installed tools)"
echo ""
if [[ ${#SHELL_FILES[@]} -gt 0 ]]; then
    echo "PATH is configured in:"
    for f in "${SHELL_FILES[@]}"; do
        echo "  - $f"
    done
    echo "Open a new shell (or run: source ~/.bashrc) to pick it up."
else
    # shellcheck disable=SC2016  # printed literally for the user to copy
    {
        echo "Add these directories to PATH yourself (shell config was disabled):"
        echo '  bash/zsh: export PATH="$HOME/.local/bin:$HOME/.pixi/bin:$PATH:$HOME/.local/share/server-bootstrap/fallback-bin"'
        echo '  fish:     fish_add_path $HOME/.local/bin $HOME/.pixi/bin; fish_add_path --append $HOME/.local/share/server-bootstrap/fallback-bin'
    }
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo ""
    echo "Warnings:"
    for w in "${WARNINGS[@]}"; do
        echo "  - $w"
    done
fi
echo ""

[[ "$POST_INSTALL_OK" == 1 ]] || exit 1
