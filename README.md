# server-bootstrap

Lightweight, sudo-free provisioning for Linux servers. A single `curl | bash` command installs CLI tools (Neovim, ripgrep, fd, lazygit, etc.) via [pixi](https://pixi.sh), sets up a Neovim config, and installs the Claude Code and Codex CLIs — all user-local under `$HOME`, idempotent, and declarative.

## Quick start

**Recommended** — clone and run locally (most secure):

```bash
git clone https://github.com/makolon/server-bootstrap.git
cd server-bootstrap
bash bootstrap.sh
```

Alternatively, bootstrap a single server via curl (review the script first):

```bash
# Review before running
curl --proto =https --tlsv1.2 -fsSL https://raw.githubusercontent.com/makolon/server-bootstrap/main/bootstrap.sh | less
# Then run
curl --proto =https --tlsv1.2 -fsSL https://raw.githubusercontent.com/makolon/server-bootstrap/main/bootstrap.sh | bash
```

## Multi-server deployment

From your Mac, bootstrap multiple servers at once. Files are transferred via `scp` from your local clone — remote servers do not download scripts from GitHub.

```bash
# Pass hosts as arguments
bash bootstrap-all.sh user@server1 user@server2 gpu-box

# Or create a hosts.txt file (one host per line, see hosts.txt.example)
cp hosts.txt.example hosts.txt
# edit hosts.txt with your servers
bash bootstrap-all.sh
```

## What gets installed

### pixi global environments (`pixi-global.toml`)

| Environment | Packages | Exposed binaries |
|-------------|----------|------------------|
| `neovim` | neovim >=0.10 | `nvim` |
| `cli` | ripgrep, fd-find, fzf, lazygit, git, gcc, make, unzip, tree-sitter-cli, tmux | `rg`, `fd`, `fzf`, `lazygit`, `git`, `gcc`, `make`, `unzip`, `tree-sitter`, `tmux` |
| `fish` | fish | `fish` |
| `node` | nodejs >=20 | `node`, `npm`, `npx` |
| `python` | python 3.12, uv | `python`, `uv` |

> `node` exists for Neovim/Mason (JS-based LSPs and tools), **not** for Claude Code.

### Additional tools (`post-install.sh`)

- **Claude Code** — installed with Anthropic's official native installer
  (`curl -fsSL https://claude.ai/install.sh | bash`) to `~/.local/bin/claude`.

- **Codex CLI** — installed with OpenAI's official native installer
  (`curl -fsSL https://github.com/openai/codex/releases/latest/download/install.sh | CODEX_NON_INTERACTIVE=1 bash`)
  to `~/.local/bin/codex`.

  Neither CLI is published on conda-forge, so they can't live in
  `pixi-global.toml`. Each vendor's native installer ships a self-contained
  binary (no Node.js at runtime) — avoiding the old npm-global + symlink
  approach, which left two copies of the CLI on disk and an easily-broken
  symlink. Both land in `~/.local/bin`, so make sure it is on your `PATH`.

### Neovim configuration

- [makolon/kickstart-modular.nvim](https://github.com/makolon/kickstart-modular.nvim) cloned to `~/.config/nvim`
- Plugins bootstrapped via `Lazy sync` on first run

## How to extend

Add a new tool by editing `pixi-global.toml`:

```toml
# Add to an existing environment
[envs.cli]
dependencies = { ripgrep = "*", fd-find = "*", bat = "*" }  # added bat
exposed = { rg = "rg", fd = "fd", bat = "bat" }             # expose it

# Or create a new environment
[envs.rust]
channels = ["conda-forge"]
dependencies = { rust = "*" }
exposed = { rustc = "rustc", cargo = "cargo" }
```

Then commit, push, and re-run on your servers:

```bash
pixi global sync
```

## How to update

```bash
# Re-sync after pulling a new manifest
pixi global sync

# Upgrade all packages to latest compatible versions
pixi global update
```

## Related repos

| Repo | Purpose |
|------|---------|
| [makolon/dotfiles](https://github.com/makolon/dotfiles) | chezmoi + Nix — **macOS** primary machine config |
| [makolon/kickstart-modular.nvim](https://github.com/makolon/kickstart-modular.nvim) | Neovim config (shared by Mac and servers) |
| [makolon/server-bootstrap](https://github.com/makolon/server-bootstrap) | This repo — lightweight Linux server provisioning |

## Troubleshooting

### pixi not in PATH after install

The pixi installer adds itself to `~/.bashrc`, but if you're in a non-login shell or using a different shell, you need to add it manually:

```bash
# bash/zsh — add to ~/.bashrc or ~/.zshrc
export PATH="$HOME/.pixi/bin:$HOME/.local/bin:$PATH"

# fish — add to ~/.config/fish/config.fish
set -gx PATH $HOME/.pixi/bin $HOME/.local/bin $PATH
```

`~/.pixi/bin` holds the pixi-managed tools; `~/.local/bin` holds the Claude
Code native binary. Then restart your shell or `source` the file.

### Neovim plugins fail on first sync

The headless `Lazy sync` can fail on first run (missing dependencies, network issues). This is non-fatal. Open `nvim` manually and plugins will install automatically.

### Claude Code / Codex require login

After installation, run `claude` (or `codex`) and follow the authentication
prompts. You'll need the vendor's API key or to log in via your browser.

### Two copies of `claude` / wrong version runs

If `claude` resolves to an unexpected path or version, you probably have a
leftover install from the old npm-based approach. Check which binary wins and
remove the stale one:

```bash
which -a claude          # list every claude on PATH
claude doctor            # reports the active install and known issues

# Remove an old npm global + its symlink, if present
npm uninstall -g @anthropic-ai/claude-code 2>/dev/null
rm -f ~/.pixi/bin/claude
```

The native install (`~/.local/bin/claude`) is the one to keep; it auto-updates
itself.

### SSH connection timeout in bootstrap-all.sh

The script uses a 10-second SSH connect timeout. If your servers are slow to respond, edit the `ConnectTimeout` value in `bootstrap-all.sh`.

### pixi global sync fails with dependency conflicts

If you pin versions too tightly, conda-forge may not have a compatible combination. Try relaxing version constraints in `pixi-global.toml` (e.g., change `"==3.12.3"` to `"3.12.*"`).

## Security

- All `curl` calls enforce HTTPS-only (`--proto =https --tlsv1.2`) to prevent protocol downgrade attacks.
- `bootstrap-all.sh` transfers scripts via `scp` from your local clone rather than having remote servers download from GitHub, reducing the attack surface.
- Downloaded files are validated for non-empty content before execution.
- Existing `pixi-global.toml` is backed up before overwriting.
- Temporary files are created with restrictive permissions (`umask 077`) and cleaned up via `trap` on exit.
- Hostnames are validated against a strict allowlist (`[a-zA-Z0-9@._:-]`) to prevent injection.
- For maximum security, prefer cloning the repo and running locally over `curl | bash`.
