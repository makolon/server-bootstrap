# server-bootstrap

Lightweight, sudo-free provisioning for Linux servers. A single `curl | bash` command installs CLI tools (Neovim, ripgrep, fd, lazygit, etc.) via [pixi](https://pixi.sh), sets up a Neovim config, installs the Claude Code and Codex CLIs, and puts everything on your `PATH` — all user-local under `$HOME`, idempotent, and declarative.

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

In `curl | bash` mode, `pixi-global.toml` and `post-install.sh` are downloaded from GitHub too — files in your current directory are never used.

## Multi-server deployment

From your Mac (macOS's stock `/bin/bash` 3.2 is fine), bootstrap multiple servers at once:

```bash
# Pass hosts as arguments
bash bootstrap-all.sh user@server1 user@server2 gpu-box

# Or create a hosts.txt file (one host per line, see hosts.txt.example)
cp hosts.txt.example hosts.txt
# edit hosts.txt with your servers
bash bootstrap-all.sh
```

Each host gets a single SSH connection that streams `bootstrap.sh`, `post-install.sh` and `pixi-global.toml` from your local clone into a fresh `mktemp -d` directory, runs `bootstrap.sh`, and removes the directory afterwards — remote servers never download this repo's scripts from GitHub (they still need outbound access for the tools themselves, see [Network requirements](#network-requirements)). Hosts are processed one after another; the summary lists each failed host with its exit code (`255` = SSH connection/authentication failure, anything else = `bootstrap.sh` failed), and the script exits non-zero if any host failed.

## What gets installed

### pixi global environments (`pixi-global.toml`)

| Environment | Packages | Exposed binaries |
|-------------|----------|------------------|
| `neovim` | nvim >=0.10 | `nvim` |
| `cli` | ripgrep, fd-find, fzf, lazygit, unzip, tree-sitter-cli, tmux | `rg`, `fd`, `fzf`, `lazygit`, `unzip`, `tree-sitter`, `tmux` |
| `toolchain` | gcc, make, git | `pixi-gcc`, `pixi-make`, `pixi-git` (+ fallback `gcc`, `cc`, `make`, `git`, see below) |
| `fish` | fish | `fish` |
| `node` | nodejs >=20 | `node`, `npm`, `npx` |
| `python` | python 3.12, uv | `python`, `uv` |

> `node` exists for Neovim/Mason (JS-based LSPs and tools), **not** for Claude Code.

### System toolchain first

Neovim plugins need git, make and a C compiler (lazy.nvim, tree-sitter parsers, telescope-fzf-native), so pixi provides them — but only as a **fallback**. conda-forge's gcc compiles against its own sysroot (it does not search `/usr/include`, so headers from system `-dev` packages are invisible, and it is usually newer than `nvcc` supports), and conda-forge's git ignores `/etc/gitconfig` (git-lfs filters, proxies) and the system CA store. So:

- pixi exposes them only as `pixi-gcc`, `pixi-make` and `pixi-git`;
- `bootstrap.sh` writes plain-named wrappers (`gcc`, `cc`, `make`, `git`) to `~/.local/share/server-bootstrap/fallback-bin`, which goes at the **end** of `PATH`.

On a server with a system toolchain, `gcc`/`make`/`git` are the system ones; on a minimal server without them, pixi's are used. To use pixi's explicitly, call `pixi-gcc` etc. (e.g. `CC=pixi-gcc`).

### Additional tools (`post-install.sh`)

- **Claude Code** — installed with Anthropic's official native installer (`https://claude.ai/install.sh`) to `~/.local/bin/claude`.
- **Codex CLI** — installed with OpenAI's official native installer (`https://github.com/openai/codex/releases/latest/download/install.sh`, run with `CODEX_NON_INTERACTIVE=1`) to `~/.local/bin/codex`.

Neither CLI is published on conda-forge, so they can't live in `pixi-global.toml`. Each vendor's native installer ships a self-contained binary (no Node.js at runtime). Each installer is downloaded to a temp file and checked before it runs; if one fails, the other is still installed and the bootstrap reports the failure.

A CLI is skipped if it is already in `~/.local/bin`, or if it was installed some other way (left as is). An old npm-based install from earlier versions of this repo (`~/.pixi/bin/claude` → pixi's node env) does not count: the native one is installed and you are told how to remove the old one.

### Neovim configuration

- [makolon/kickstart-modular.nvim](https://github.com/makolon/kickstart-modular.nvim) cloned to `~/.config/nvim` (if `~/.config/nvim` already exists and is not a git checkout, it is left untouched and a warning is shown)
- Plugins bootstrapped via `Lazy! sync`; output goes to `~/.local/state/server-bootstrap/nvim-plugin-sync.log`

### Shell `PATH`

`bootstrap.sh` keeps a marked block in `~/.bashrc` (and `~/.zshrc` if you use zsh) and a file `~/.config/fish/conf.d/server-bootstrap.fish`, giving this `PATH` order:

```
~/.local/bin : ~/.pixi/bin : <system PATH> : ~/.local/share/server-bootstrap/fallback-bin
```

Re-running rewrites the block in place (never duplicates it). Set `BOOTSTRAP_NO_SHELL_CONFIG=1` to leave your shell files alone; the summary then prints the lines to add yourself.

## Configuration

| Variable | Effect |
|----------|--------|
| `PIXI_HOME` | pixi's home directory (default `~/.pixi`); honored everywhere |
| `BOOTSTRAP_NO_SHELL_CONFIG=1` | Don't write the `PATH` block / fish conf.d (pixi's installer then adds its own `PATH` line, as usual) |

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

Then commit, push, and **re-run the bootstrap** on your servers (`bash bootstrap-all.sh`, or `bootstrap.sh` / `curl | bash` on the server). Running only `pixi global sync` on a server does not pick up repo changes: the server's manifest (`~/.pixi/manifests/pixi-global.toml`) is a copy that the bootstrap refreshes.

> The repo manifest is the source of truth. Environments added on a server with `pixi global install` are **removed** by the next bootstrap (it warns and names them first, and keeps the previous manifest as `pixi-global.toml.bak.<timestamp>`). Add tools you want to keep to `pixi-global.toml` in the repo.

## How to update

```bash
# Apply manifest changes from the repo: re-run the bootstrap
bash bootstrap.sh            # or: bash bootstrap-all.sh <hosts...> from your Mac

# Upgrade all packages to the latest compatible versions
pixi global update
```

## Network requirements

Remote servers need outbound HTTPS to:

| Host | Used for |
|------|----------|
| `pixi.sh`, `github.com` + its release/raw content hosts (`objects.githubusercontent.com`, `release-assets.githubusercontent.com`) | pixi installer and binary |
| `conda.anaconda.org` | conda-forge packages |
| `github.com` | Neovim config and plugins (lazy.nvim), Codex installer (and fallback binary download) |
| `claude.ai`, `downloads.claude.ai` | Claude Code |
| `releases.openai.com` | Codex CLI binary |
| `raw.githubusercontent.com` | this repo's files — only in `curl \| bash` mode |

Plus whatever your Neovim config downloads on its own (e.g. Mason: GitHub releases, npm, PyPI).

## Testing

```bash
bash tests/run.sh                  # all groups
bash tests/run.sh bootstrap-all    # one group: bootstrap-all | bootstrap | post-install
```

The tests are hermetic: `curl`, `git`, `ssh` and `pixi` are replaced by fakes in `tests/fakes/`, and every script runs with a clean environment and a throwaway `HOME`, so nothing is downloaded and your own `$HOME` is never touched. CI (`.github/workflows/ci.yml`) runs shellcheck, the full suite on Linux, and the `bootstrap-all.sh` tests on macOS with `/bin/bash` 3.2.

## Related repos

| Repo | Purpose |
|------|---------|
| [makolon/dotfiles](https://github.com/makolon/dotfiles) | chezmoi + Nix — **macOS** primary machine config |
| [makolon/kickstart-modular.nvim](https://github.com/makolon/kickstart-modular.nvim) | Neovim config (shared by Mac and servers) |
| [makolon/server-bootstrap](https://github.com/makolon/server-bootstrap) | This repo — lightweight Linux server provisioning |

## Troubleshooting

### Tools not on PATH after install

Open a new shell, or `source ~/.bashrc`. Note that `ssh host <command>` runs a non-interactive shell, and the default Ubuntu/Debian `~/.bashrc` returns before reaching the `PATH` block — use full paths there (e.g. `ssh host '~/.local/bin/claude --version'`) or an interactive shell (`ssh -t host 'bash -ic nvim'`).

If you set `BOOTSTRAP_NO_SHELL_CONFIG=1`, add the directories yourself:

```bash
# bash/zsh — ~/.bashrc or ~/.zshrc
export PATH="$HOME/.local/bin:$HOME/.pixi/bin:$PATH:$HOME/.local/share/server-bootstrap/fallback-bin"
```

```fish
# fish — ~/.config/fish/config.fish
fish_add_path $HOME/.local/bin $HOME/.pixi/bin
fish_add_path --append $HOME/.local/share/server-bootstrap/fallback-bin
```

### Neovim plugins fail on first sync

The headless `Lazy! sync` can fail on first run (missing dependencies, network issues). This is non-fatal: check `~/.local/state/server-bootstrap/nvim-plugin-sync.log`, then open `nvim` and plugins will install automatically.

### `~/.config/nvim` is left untouched

If `~/.config/nvim` exists and is not a git checkout, the bootstrap does not overwrite it. Move it aside (`mv ~/.config/nvim ~/.config/nvim.old`) and re-run to get kickstart-modular.nvim.

### Claude Code / Codex require login

After installation, run `claude` (or `codex`) and follow the authentication prompts. You'll need the vendor's API key or to log in via your browser.

### Two copies of `claude` / wrong version runs

`post-install.sh` installs the native `~/.local/bin/claude` even if an old npm-based install from earlier versions of this repo exists, and prints how to remove the old one. To check which binary wins:

```bash
which -a claude          # list every claude on PATH
claude doctor            # reports the active install and known issues

# Remove an old npm global + its symlink, if present
npm uninstall -g @anthropic-ai/claude-code 2>/dev/null
rm -f ~/.pixi/bin/claude
```

The native install (`~/.local/bin/claude`) is the one to keep; it auto-updates itself.

### SSH failures in bootstrap-all.sh

`exit code 255` means SSH itself failed (unreachable host, authentication). The script uses a 10-second connect timeout; edit `SSH_OPTS` in `bootstrap-all.sh` to change it or to add options such as `-o BatchMode=yes`.

### pixi global sync fails with dependency conflicts

If you pin versions too tightly, conda-forge may not have a compatible combination. Try relaxing version constraints in `pixi-global.toml` (e.g., change `"==3.12.3"` to `"3.12.*"`).

## Security

- Every `curl` call in these scripts enforces HTTPS-only (`--proto =https --tlsv1.2`). (The vendor installers do their own downloads.)
- Downloaded scripts — the pixi, Claude Code and Codex installers, and this repo's files in `curl | bash` mode — are saved to a temp file and checked to be non-empty before they run, so a truncated download is never executed.
- In `curl | bash` mode, nothing is read from the current directory.
- `bootstrap-all.sh` sends the files of your local clone over the SSH connection instead of having remote servers download them from GitHub.
- Hosts are validated against a strict allowlist (`[a-zA-Z0-9@._:-]`, no leading `-`) and passed to `ssh` after `--`, so they can't inject shell commands or ssh options.
- An existing `pixi-global.toml` is backed up (timestamped, never overwritten) before it is replaced, and environments that `pixi global sync` will remove are listed.
- Temporary files live in `mktemp -d` directories (mode 0700) that are removed on exit, on the remote host as well.
- For maximum security, prefer cloning the repo and running locally over `curl | bash`.
