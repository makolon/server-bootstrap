#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO_RAW="https://raw.githubusercontent.com/makolon/server-bootstrap/main"
TOTAL_STEPS=7

TMPDIR_BOOTSTRAP="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BOOTSTRAP"' EXIT

step() {
    local n="$1"; shift
    echo ""
    echo "==> [$n/$TOTAL_STEPS] $*"
}

# ---------------------------------------------------------------------------
# 1. Install pixi
# ---------------------------------------------------------------------------
step 1 "Ensuring pixi is installed..."

if command -v pixi &>/dev/null; then
    echo "    pixi already installed: $(pixi --version)"
else
    echo "    Downloading pixi installer..."
    PIXI_INSTALLER="$TMPDIR_BOOTSTRAP/pixi-install.sh"
    curl --proto =https --tlsv1.2 -fsSL https://pixi.sh/install.sh -o "$PIXI_INSTALLER"
    echo "    Running pixi installer..."
    bash "$PIXI_INSTALLER"
    echo "    pixi installed."
fi

# ---------------------------------------------------------------------------
# 2. Ensure pixi is on PATH for this session
# ---------------------------------------------------------------------------
step 2 "Ensuring pixi is on PATH for this session..."

if ! command -v pixi &>/dev/null; then
    export PATH="$HOME/.pixi/bin:$PATH"
    if ! command -v pixi &>/dev/null; then
        echo "ERROR: pixi not found even after adding ~/.pixi/bin to PATH." >&2
        exit 1
    fi
fi
echo "    pixi location: $(command -v pixi)"

# ---------------------------------------------------------------------------
# 3. Download pixi-global.toml
# ---------------------------------------------------------------------------
step 3 "Installing pixi-global.toml manifest..."

MANIFEST_DIR="$HOME/.pixi/manifests"
MANIFEST_PATH="$MANIFEST_DIR/pixi-global.toml"
mkdir -p "$MANIFEST_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/pixi-global.toml" ]]; then
    echo "    Copying pixi-global.toml from local clone..."
    if [[ -f "$MANIFEST_PATH" ]]; then
        cp "$MANIFEST_PATH" "$MANIFEST_PATH.bak"
        echo "    Backed up existing manifest to $MANIFEST_PATH.bak"
    fi
    cp "$SCRIPT_DIR/pixi-global.toml" "$MANIFEST_PATH"
else
    echo "    Downloading pixi-global.toml from $REPO_RAW ..."
    TOML_TMP="$TMPDIR_BOOTSTRAP/pixi-global.toml"
    curl --proto =https --tlsv1.2 -fsSL "$REPO_RAW/pixi-global.toml" -o "$TOML_TMP"
    if [[ ! -s "$TOML_TMP" ]]; then
        echo "ERROR: Downloaded pixi-global.toml is empty." >&2
        exit 1
    fi
    if [[ -f "$MANIFEST_PATH" ]]; then
        cp "$MANIFEST_PATH" "$MANIFEST_PATH.bak"
        echo "    Backed up existing manifest to $MANIFEST_PATH.bak"
    fi
    cp "$TOML_TMP" "$MANIFEST_PATH"
fi

echo "    Manifest installed at $MANIFEST_PATH"

# ---------------------------------------------------------------------------
# 4. Sync pixi global environments
# ---------------------------------------------------------------------------
step 4 "Running pixi global sync..."

pixi global sync
echo "    pixi global sync complete."

# ---------------------------------------------------------------------------
# 5. Clone Neovim config
# ---------------------------------------------------------------------------
step 5 "Setting up Neovim configuration..."

NVIM_CONFIG="$HOME/.config/nvim"

if [[ -d "$NVIM_CONFIG/.git" ]]; then
    echo "    Neovim config already present at $NVIM_CONFIG — skipping."
else
    echo "    Cloning kickstart-modular.nvim..."
    git clone https://github.com/makolon/kickstart-modular.nvim.git "$NVIM_CONFIG"
    echo "    Neovim config cloned."
fi

# ---------------------------------------------------------------------------
# 6. Bootstrap Neovim plugins
# ---------------------------------------------------------------------------
step 6 "Bootstrapping Neovim plugins (may take a minute)..."

if nvim --headless "+Lazy! sync" +qa 2>/dev/null; then
    echo "    Neovim plugins synced."
else
    echo "    WARNING: Neovim plugin sync returned non-zero — this is common on first run."
    echo "    Open nvim manually to finish plugin setup."
fi

# ---------------------------------------------------------------------------
# 7. Run post-install
# ---------------------------------------------------------------------------
step 7 "Running post-install tasks..."

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/post-install.sh" ]]; then
    bash "$SCRIPT_DIR/post-install.sh"
else
    POST_INSTALL="$TMPDIR_BOOTSTRAP/post-install.sh"
    curl --proto =https --tlsv1.2 -fsSL "$REPO_RAW/post-install.sh" -o "$POST_INSTALL"
    if [[ ! -s "$POST_INSTALL" ]]; then
        echo "ERROR: Downloaded post-install.sh is empty." >&2
        exit 1
    fi
    bash "$POST_INSTALL"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "  Bootstrap complete!"
echo "========================================"
echo ""
echo "Installed environments:"
pixi global list 2>/dev/null || echo "  (run 'pixi global list' to see installed tools)"
echo ""
echo "IMPORTANT: Make sure these directories are on your PATH if not already done:"
echo "  - \$HOME/.pixi/bin    (pixi-managed tools: nvim, rg, fd, fish, node, ...)"
echo "  - \$HOME/.local/bin   (Claude Code & Codex native installs)"
echo ""
echo '  export PATH="$HOME/.pixi/bin:$HOME/.local/bin:$PATH"'
echo ""
echo "Add this line to your ~/.bashrc, ~/.zshrc, or ~/.config/fish/config.fish"
echo "(for fish: set -gx PATH \$HOME/.pixi/bin \$HOME/.local/bin \$PATH)"
echo ""
