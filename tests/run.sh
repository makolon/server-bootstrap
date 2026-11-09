#!/usr/bin/env bash
# Hermetic tests for bootstrap.sh, post-install.sh and bootstrap-all.sh.
#
# No network, no real ssh, and nothing outside a temp directory is touched:
# curl, git, ssh and pixi are replaced by the fakes in tests/fakes/, and every
# script runs with a clean environment and HOME inside the temp directory.
#
# Usage: bash tests/run.sh [bootstrap-all] [bootstrap] [post-install]
#   (default: all groups)
#   SUT_BASH=/bin/bash  bash used to run the scripts under test (CI uses this
#                       to exercise bootstrap-all.sh with macOS's bash 3.2)
#
# Keep this file bash 3.2 compatible (it runs on macOS in CI).
# shellcheck disable=SC2016  # many single-quoted snippets are run by another shell
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$TESTS_DIR")"
FAKES="$TESTS_DIR/fakes"
SUT_BASH="${SUT_BASH:-$(command -v bash)}"
BASH_BIN="$(command -v bash)"
FISH_BIN="$(command -v fish || true)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/server-bootstrap-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TAB="$(printf '\t')"
BEGIN_MARK="# >>> server-bootstrap >>>"
passed=0
failed=0
current=""
T=""

# --- helpers ---------------------------------------------------------------

sandbox() {          # sandbox NAME — fresh temp dir $T with an empty HOME
    current="$1"
    T="$WORK/$1"
    mkdir -p "$T/home" "$T/tmp"
    : > "$T/log"
    : > "$T/out"
}

check() {            # check DESCRIPTION COMMAND...
    local desc="$1"
    shift
    if "$@"; then
        passed=$((passed + 1))
        echo "  ok   $current: $desc"
    else
        failed=$((failed + 1))
        echo "  FAIL $current: $desc"
        echo "       --- output (last 25 lines) ---"
        tail -n 25 "$T/out" | sed 's/^/       | /'
        echo "       --- fake command log ---"
        sed 's/^/       | /' "$T/log"
    fi
}

not() { ! "$@"; }
has() { grep -qF -- "$1" "$2"; }      # has TEXT FILE
same() { [[ "$1" == "$2" ]]; }

# run_sut [VAR=value ...] COMMAND... — run with a clean env and HOME=$T/home,
# from $RUN_CWD (default $T/home), on $SANDBOX_PATH; output to $T/out.
run_sut() {
    (cd "${RUN_CWD:-$T/home}" && env -i \
        HOME="$T/home" TMPDIR="$T/tmp" SHELL=/bin/bash \
        PATH="${SANDBOX_PATH:-$FAKES/bin:/usr/bin:/bin}" \
        FAKE_LOG="$T/log" FAKE_REPO="$REPO" FAKE_REMOTE_ROOT="$T/remote" \
        "$@") >> "$T/out" 2>&1
}

preinstall_pixi() {
    mkdir -p "$T/home/.pixi/bin"
    cp "$FAKES/pixi" "$T/home/.pixi/bin/pixi"
}

backups() {          # number of manifest backups in the sandbox
    find "$T/home/.pixi/manifests" -name 'pixi-global.toml.bak.*' | wc -l | tr -d ' '
}

# --- bootstrap.sh ----------------------------------------------------------

test_bootstrap() {
    local H FB rc first

    sandbox bootstrap-fresh
    H="$T/home"
    FB="$H/.local/share/server-bootstrap/fallback-bin"
    run_sut "$SUT_BASH" "$REPO/bootstrap.sh"; rc=$?
    check "exits 0" same "$rc" 0
    check "installs pixi without letting it edit PATH" has "PIXI_NO_PATH_UPDATE=1" "$T/log"
    check "installs the repo manifest" cmp -s "$REPO/pixi-global.toml" "$H/.pixi/manifests/pixi-global.toml"
    check "runs pixi global sync" has "pixi global sync" "$T/log"
    check "does not expose gcc/make/git under plain names" \
        test ! -e "$H/.pixi/bin/gcc" -a ! -e "$H/.pixi/bin/make" -a ! -e "$H/.pixi/bin/git"
    check "creates gcc/cc/make/git fallback wrappers" test -x "$FB/gcc" -a -x "$FB/cc" -a -x "$FB/make" -a -x "$FB/git"
    check "fallback gcc execs pixi-gcc" env FAKE_LOG="$T/log" "$FB/gcc" --fake-arg
    check "  ... (logged by the pixi-gcc stub)" has "pixi-gcc --fake-arg" "$T/log"
    check "clones the nvim config" test -d "$H/.config/nvim/.git"
    check "syncs nvim plugins" has "nvim --headless +Lazy! sync +qa" "$T/log"
    check "installs Claude Code" test -x "$H/.local/bin/claude"
    check "installs Codex non-interactively" has "fake codex installer: CODEX_NON_INTERACTIVE=1" "$T/log"
    check "adds exactly one PATH block to .bashrc" same "$(grep -cxF "$BEGIN_MARK" "$H/.bashrc")" 1
    check "writes fish conf.d" test -f "$H/.config/fish/conf.d/server-bootstrap.fish"

    # PATH produced by the .bashrc block
    mkdir -p "$T/sys" "$T/empty"
    printf '#!/bin/sh\n' > "$T/sys/gcc"
    chmod +x "$T/sys/gcc"
    check "PATH order: ~/.local/bin, ~/.pixi/bin, system, fallback" same \
        "$(env -i HOME="$H" PATH=/usr/bin "$BASH_BIN" -c '. "$HOME/.bashrc"; echo "$PATH"')" \
        "$H/.local/bin:$H/.pixi/bin:/usr/bin:$FB"
    check "sourcing the block twice does not duplicate PATH entries" same \
        "$(env -i HOME="$H" PATH=/usr/bin "$BASH_BIN" -c '. "$HOME/.bashrc"; . "$HOME/.bashrc"; echo "$PATH"')" \
        "$H/.local/bin:$H/.pixi/bin:/usr/bin:$FB"
    check "a system gcc wins over the fallback" same \
        "$(env -i HOME="$H" PATH="$T/sys" "$BASH_BIN" -c '. "$HOME/.bashrc"; command -v gcc')" "$T/sys/gcc"
    check "the fallback gcc is used when the system has none" same \
        "$(env -i HOME="$H" PATH="$T/empty" "$BASH_BIN" -c '. "$HOME/.bashrc"; command -v gcc')" "$FB/gcc"
    if [[ -n "$FISH_BIN" ]]; then
        # (a pixi-installed fish adds its own env's bin dir to PATH; ignore it)
        check "fish conf.d gives the same PATH order (twice = idempotent)" same \
            "$(env -i HOME="$H" PATH=/usr/bin "$FISH_BIN" --no-config -c \
                'source ~/.config/fish/conf.d/server-bootstrap.fish; source ~/.config/fish/conf.d/server-bootstrap.fish
                 string join : (string match -v "*/envs/fish/bin" -- $PATH)' 2>&1)" \
            "$H/.local/bin:$H/.pixi/bin:/usr/bin:$FB"
    else
        echo "  skip $current: fish conf.d (fish not installed)"
    fi

    # Re-run with the same HOME: idempotent, and pixi is found in ~/.pixi/bin
    # even though the caller's PATH does not contain it.
    cp "$H/.bashrc" "$T/bashrc.first"
    : > "$T/log"
    run_sut "$SUT_BASH" "$REPO/bootstrap.sh"; rc=$?
    current=bootstrap-rerun
    check "exits 0" same "$rc" 0
    check "does not reinstall pixi" not has "pixi.sh/install.sh" "$T/log"
    check "makes no manifest backup when nothing changed" same "$(backups)" 0
    check "leaves .bashrc unchanged" cmp -s "$T/bashrc.first" "$H/.bashrc"
    check "does not re-clone the nvim config" not has "git clone" "$T/log"
    check "does not reinstall Claude Code / Codex" not has "install.sh" "$T/log"

    sandbox bootstrap-existing-bashrc
    H="$T/home"
    printf '# my settings\nalias ll="ls -l"' > "$H/.bashrc"     # no trailing newline
    run_sut "$SUT_BASH" "$REPO/bootstrap.sh"
    check "keeps existing .bashrc content" has 'alias ll="ls -l"' "$H/.bashrc"
    check "keeps the user's line intact" same "$(sed -n 2p "$H/.bashrc")" 'alias ll="ls -l"'
    # an outdated block is replaced in place, not duplicated
    printf '%s\nPATH=old\n# <<< server-bootstrap <<<\n# after\n' "$BEGIN_MARK" >> "$H/.bashrc"
    run_sut "$SUT_BASH" "$REPO/bootstrap.sh"
    check "replaces an outdated block in place" not grep -qx "PATH=old" "$H/.bashrc"
    check "  ... leaving a single block" same "$(grep -cxF "$BEGIN_MARK" "$H/.bashrc")" 1
    check "  ... and the lines after it" has "# after" "$H/.bashrc"

    sandbox bootstrap-manifest-backup
    H="$T/home"
    preinstall_pixi
    mkdir -p "$H/.pixi/manifests"
    { cat "$REPO/pixi-global.toml"; printf '\n[envs.my-extra]\nchannels = ["conda-forge"]\ndependencies = { jq = "*" }\nexposed = { jq = "jq" }\n'; } \
        > "$H/.pixi/manifests/pixi-global.toml"
    run_sut "$SUT_BASH" "$REPO/bootstrap.sh"
    first="$(find "$H/.pixi/manifests" -name 'pixi-global.toml.bak.*')"
    check "backs up the user's manifest" has "my-extra" "$first"
    check "warns which environments sync will remove" grep -q "REMOVED.*my-extra" "$T/out"
    printf '\n[envs.other-extra]\nchannels = ["conda-forge"]\ndependencies = { yq = "*" }\n' >> "$H/.pixi/manifests/pixi-global.toml"
    run_sut "$SUT_BASH" "$REPO/bootstrap.sh"
    check "a later run adds a new backup instead of overwriting" same "$(backups)" 2
    check "  ... and the first backup is intact" has "my-extra" "$first"

    sandbox bootstrap-curl-pipe
    H="$T/home"
    preinstall_pixi
    mkdir -p "$T/cwd"
    printf 'touch "%s/PLANTED_RAN"\n' "$T" > "$T/cwd/post-install.sh"
    printf 'version = 1\n[envs.planted]\n' > "$T/cwd/pixi-global.toml"
    RUN_CWD="$T/cwd" run_sut "$SUT_BASH" < "$REPO/bootstrap.sh"; rc=$?
    check "exits 0" same "$rc" 0
    check "does not run ./post-install.sh from the current directory" test ! -e "$T/PLANTED_RAN"
    check "does not use ./pixi-global.toml from the current directory" \
        cmp -s "$REPO/pixi-global.toml" "$H/.pixi/manifests/pixi-global.toml"
    check "downloads the manifest" has "curl https://raw.githubusercontent.com/makolon/server-bootstrap/main/pixi-global.toml" "$T/log"
    check "downloads post-install.sh" has "curl https://raw.githubusercontent.com/makolon/server-bootstrap/main/post-install.sh" "$T/log"

    sandbox bootstrap-existing-nvim-config
    H="$T/home"
    mkdir -p "$H/.config/nvim"
    echo "-- my own config" > "$H/.config/nvim/init.lua"
    run_sut "$SUT_BASH" "$REPO/bootstrap.sh"; rc=$?
    check "exits 0" same "$rc" 0
    check "leaves the existing config untouched" same "$(cat "$H/.config/nvim/init.lua")" "-- my own config"
    check "does not clone over it" not has "git clone" "$T/log"
    check "warns about it" has "is not a git checkout" "$T/out"
    check "skips the plugin sync" not has "nvim --headless" "$T/log"
    check "still runs post-install" test -x "$H/.local/bin/claude"

    sandbox bootstrap-nvim-sync-fails
    run_sut FAKE_RC_nvim=1 "$SUT_BASH" "$REPO/bootstrap.sh"; rc=$?
    check "exits 0 (plugin sync failure is not fatal)" same "$rc" 0
    check "warns with the log location" grep -q "plugin sync failed (log: .*nvim-plugin-sync.log)" "$T/out"
    check "keeps the nvim log" test -f "$T/home/.local/state/server-bootstrap/nvim-plugin-sync.log"

    sandbox bootstrap-no-shell-config
    H="$T/home"
    run_sut BOOTSTRAP_NO_SHELL_CONFIG=1 "$SUT_BASH" "$REPO/bootstrap.sh"; rc=$?
    check "exits 0" same "$rc" 0
    check "does not create .bashrc" test ! -e "$H/.bashrc"
    check "does not write fish conf.d" test ! -e "$H/.config/fish/conf.d/server-bootstrap.fish"
    check "lets the pixi installer handle PATH" has "PIXI_NO_PATH_UPDATE=" "$T/log"
    check "  ... (not suppressed)" not has "PIXI_NO_PATH_UPDATE=1" "$T/log"
    check "prints manual PATH instructions" has "Add these directories to PATH yourself" "$T/out"

    sandbox bootstrap-custom-pixi-home
    H="$T/home"
    run_sut PIXI_HOME="$T/custom-pixi" "$SUT_BASH" "$REPO/bootstrap.sh"; rc=$?
    check "exits 0" same "$rc" 0
    check "installs the manifest under PIXI_HOME" test -f "$T/custom-pixi/manifests/pixi-global.toml"
    check "points the fallback wrappers into PIXI_HOME" \
        has "$T/custom-pixi/bin/pixi-gcc" "$H/.local/share/server-bootstrap/fallback-bin/gcc"
    check "puts PIXI_HOME/bin in the PATH block" has "$T/custom-pixi/bin" "$H/.bashrc"

    sandbox bootstrap-post-install-fails
    run_sut FAKE_FAIL_INSTALL=claude "$SUT_BASH" "$REPO/bootstrap.sh"; rc=$?
    check "exits non-zero" not same "$rc" 0
    check "still prints the summary" has "Bootstrap finished with errors" "$T/out"
    check "lists the failure under Warnings" has "post-install.sh failed" "$T/out"
}

# --- post-install.sh -------------------------------------------------------

test_post_install() {
    local H rc legacy

    sandbox post-install-legacy-npm-claude
    H="$T/home"
    legacy="$H/.pixi/envs/node/lib/node_modules/@anthropic-ai/claude-code/cli.js"
    mkdir -p "$(dirname "$legacy")" "$H/.pixi/bin"
    printf '#!/bin/sh\necho "1.0.0 (npm)"\n' > "$legacy"
    chmod +x "$legacy"
    ln -s "$legacy" "$H/.pixi/bin/claude"          # what old versions of this repo created
    run_sut "$SUT_BASH" "$REPO/post-install.sh"; rc=$?
    check "exits 0" same "$rc" 0
    check "installs native Claude Code despite the legacy npm one" test -x "$H/.local/bin/claude"
    check "tells how to remove the legacy install" has "npm uninstall -g @anthropic-ai/claude-code" "$T/out"

    sandbox post-install-foreign-claude
    mkdir -p "$T/opt"
    printf '#!/bin/sh\necho "2.0.0 (other)"\n' > "$T/opt/claude"
    chmod +x "$T/opt/claude"
    SANDBOX_PATH="$T/opt:$FAKES/bin:/usr/bin:/bin" run_sut "$SUT_BASH" "$REPO/post-install.sh"; rc=$?
    check "exits 0" same "$rc" 0
    check "leaves a Claude Code installed by other means alone" not has "claude.ai/install.sh" "$T/log"
    check "  ... and says so" has "leaving it as is" "$T/out"

    sandbox post-install-claude-fails
    H="$T/home"
    run_sut FAKE_FAIL_INSTALL=claude "$SUT_BASH" "$REPO/post-install.sh"; rc=$?
    check "exits non-zero" not same "$rc" 0
    check "still installs Codex" test -x "$H/.local/bin/codex"
    check "names the failed tool" has "post-install failed for: Claude Code" "$T/out"
}

# --- bootstrap-all.sh ------------------------------------------------------

# Copy of the repo whose bootstrap.sh is a stub that records what it received.
make_stub_repo() {
    R="$T/repo"
    mkdir -p "$R"
    cp "$REPO/bootstrap-all.sh" "$REPO/post-install.sh" "$REPO/pixi-global.toml" "$R/"
    cat > "$R/bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")" && pwd)"
echo "$dir" > "$HOME/ran_from"
mkdir -p "$HOME/received"
cp "$dir"/* "$HOME/received/"
if read -r leaked; then echo "$leaked" > "$HOME/stdin_leak"; fi
rc=0
if [ -f "$HOME/stub_rc" ]; then read -r rc < "$HOME/stub_rc"; fi
echo "stub bootstrap.sh on $(basename "$HOME") exiting $rc"
exit "$rc"
EOF
}

run_all() {
    run_sut "$SUT_BASH" "$R/bootstrap-all.sh" "$@"
}

connections() { grep -c "^$1$TAB" "$T/log"; }   # SSH connections made to host $1

test_bootstrap_all() {
    local rc f ran

    sandbox all-success
    make_stub_repo
    run_all host-a; rc=$?
    check "exits 0" same "$rc" 0
    check "runs bootstrap.sh on the host" test -f "$T/remote/host-a/ran_from"
    check "reports OK" has "OK: host-a" "$T/out"
    check "uses a single SSH connection" same "$(connections host-a)" 1
    for f in bootstrap.sh post-install.sh pixi-global.toml; do
        check "transfers $f unchanged" cmp -s "$R/$f" "$T/remote/host-a/received/$f"
    done
    ran="$(cat "$T/remote/host-a/ran_from" 2>/dev/null)"
    check "removes the remote temp dir" test -n "$ran" -a ! -e "$ran"
    check "gives bootstrap.sh an empty stdin" test ! -e "$T/remote/host-a/stdin_leak"

    sandbox all-remote-failure
    make_stub_repo
    mkdir -p "$T/remote/host-b"
    echo 3 > "$T/remote/host-b/stub_rc"
    run_all host-b; rc=$?
    check "exits 1" same "$rc" 1
    check "reports the remote exit code" has "FAILED: host-b (exit code 3 from bootstrap.sh)" "$T/out"
    ran="$(cat "$T/remote/host-b/ran_from" 2>/dev/null)"
    check "still removes the remote temp dir" test -n "$ran" -a ! -e "$ran"

    sandbox all-mixed
    make_stub_repo
    run_all host-a unreachable host-c; rc=$?
    check "exits 1" same "$rc" 1
    check "continues after a failed host" test -f "$T/remote/host-c/ran_from"
    check "reports the connection failure" has "FAILED: unreachable (exit code 255: SSH connection" "$T/out"
    check "summarises 2/3 succeeded" has "Succeeded: 2/3" "$T/out"

    sandbox all-every-host-fails
    make_stub_repo
    run_all unreachable-1 unreachable-2; rc=$?
    check "exits 1" same "$rc" 1
    check "prints the failure summary (no 'unbound variable' on bash 3.2)" has "Failed: 2/2" "$T/out"
    check "  ... and no shell error" not has "unbound variable" "$T/out"

    sandbox all-hosts-file
    make_stub_repo
    printf 'host-a\r\n\thost-b   # trailing comment\n# comment\n\n  host-c' > "$R/hosts.txt"
    run_all; rc=$?
    check "exits 0" same "$rc" 0
    check "reads CRLF lines" same "$(connections host-a)" 1
    check "reads tab-indented lines with comments" same "$(connections host-b)" 1
    check "reads a last line without newline" same "$(connections host-c)" 1
    check "contacts exactly 3 hosts" same "$(wc -l < "$T/log" | tr -d ' ')" 3

    sandbox all-empty-hosts-file
    make_stub_repo
    printf '# nothing here\n\n' > "$R/hosts.txt"
    run_all; rc=$?
    check "exits 1" same "$rc" 1
    check "says no hosts were given" has "No hosts given" "$T/out"
    check "does not claim success" not has "successfully" "$T/out"

    sandbox all-no-hosts
    make_stub_repo
    run_all; rc=$?
    check "exits 1 with usage when there is no hosts.txt" same "$rc" 1
    check "  ... (usage printed)" has "Usage:" "$T/out"

    for bad in '-oProxyCommand=x' '-L8080:localhost:80' 'a;b' 'host b'; do
        sandbox "all-invalid-host"
        make_stub_repo
        run_all host-a "$bad"; rc=$?
        check "rejects host '$bad' before connecting anywhere" test "$rc" -eq 1 -a ! -s "$T/log"
        rm -rf "$T"
    done
}

# --- main ------------------------------------------------------------------

groups="$*"
[[ -n "$groups" ]] || groups="bootstrap-all bootstrap post-install"
echo "Using SUT bash: $SUT_BASH ($("$SUT_BASH" -c 'echo $BASH_VERSION'))"
for g in $groups; do
    echo ""
    echo "== $g"
    case "$g" in
        bootstrap-all) test_bootstrap_all ;;
        bootstrap)     test_bootstrap ;;
        post-install)  test_post_install ;;
        *) echo "unknown test group: $g" >&2; exit 2 ;;
    esac
done

echo ""
echo "$passed passed, $failed failed"
[[ $failed -eq 0 ]]
