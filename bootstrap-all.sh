#!/usr/bin/env bash
# bootstrap-all.sh — run bootstrap.sh on one or more hosts over SSH.
#
# Each host gets ONE SSH connection running `bash -s`. Its stdin is a short
# script that writes bootstrap.sh, post-install.sh and pixi-global.toml (from
# this local clone) into a fresh `mktemp -d` directory, runs bootstrap.sh, and
# removes the directory on exit. bootstrap.sh's exit status is the remote exit
# status, so failures are reported as failures.
#
# Must stay compatible with macOS's stock /bin/bash 3.2: no associative arrays,
# no mapfile, and no "${array[@]}" expansion of a possibly-empty array.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"
FILES=(bootstrap.sh post-install.sh pixi-global.toml)
EOF_MARK="__SERVER_BOOTSTRAP_EOF__"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

usage() {
    cat <<EOF
Usage: $0 [host ...]

Bootstraps each host over SSH using the files of this local clone.
Without arguments, hosts are read from:
  $HOSTS_FILE
(one per line, '#' starts a comment — see hosts.txt.example).
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Validate the files to transfer
# ---------------------------------------------------------------------------
for f in "${FILES[@]}"; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        echo "ERROR: Required file not found: $SCRIPT_DIR/$f" >&2
        echo "Run this script from a local clone of the repository." >&2
        exit 1
    fi
    if grep -qxF "$EOF_MARK" "$SCRIPT_DIR/$f"; then
        echo "ERROR: $f contains the line '$EOF_MARK', which is reserved." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Validate host format (hosts come from hosts.txt / args and end up on the
# ssh command line: no shell metacharacters, and no leading '-' that ssh
# would parse as an option)
# ---------------------------------------------------------------------------
validate_host() {
    local host="$1"
    if [[ "$host" == -* || ! "$host" =~ ^[a-zA-Z0-9@._:-]+$ ]]; then
        printf 'ERROR: Invalid host: %q\n' "$host" >&2
        echo "Hosts may only contain letters, digits, @ . _ : - and must not start with '-'." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Gather host list: CLI args > hosts.txt
# ---------------------------------------------------------------------------
hosts=()

if [[ $# -gt 0 ]]; then
    hosts=("$@")
elif [[ -f "$HOSTS_FILE" ]]; then
    # `|| [[ -n $line ]]` keeps a last line that has no trailing newline.
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"              # strip comments
        line="${line//[[:space:]]/}"    # strip spaces, tabs and CR (CRLF files)
        if [[ -n "$line" ]]; then
            hosts+=("$line")
        fi
    done < "$HOSTS_FILE"
else
    usage >&2
    exit 1
fi

if [[ ${#hosts[@]} -eq 0 ]]; then
    echo "ERROR: No hosts given ($HOSTS_FILE contains no host entries)." >&2
    exit 1
fi

# Validate all hosts before connecting anywhere
for host in "${hosts[@]}"; do
    validate_host "$host"
done

# ---------------------------------------------------------------------------
# The script fed to `bash -s` on each host
# ---------------------------------------------------------------------------
remote_script() {
    local f
    # shellcheck disable=SC2016  # these lines are expanded on the remote host
    printf '%s\n' \
        'set -e' \
        'd="$(mktemp -d)"' \
        'trap '\''rm -rf "$d"'\'' EXIT'
    for f in "${FILES[@]}"; do
        # shellcheck disable=SC2016
        printf 'cat > "$d/%s" <<'\''%s'\''\n' "$f" "$EOF_MARK"
        cat "$SCRIPT_DIR/$f"
        # make sure the end marker starts on its own line
        if [[ -n "$(tail -c 1 "$SCRIPT_DIR/$f")" ]]; then
            echo
        fi
        printf '%s\n' "$EOF_MARK"
    done
    # stdin of bootstrap.sh must not be this script
    # shellcheck disable=SC2016
    printf '%s\n' 'bash "$d/bootstrap.sh" </dev/null'
}

# ---------------------------------------------------------------------------
# Run bootstrap on each host
#   - Files come from this local clone, so remote servers never download this
#     repo's scripts from GitHub (they still need outbound access for the
#     tools themselves — see "Network requirements" in README.md).
# ---------------------------------------------------------------------------
echo "Bootstrapping ${#hosts[@]} host(s)..."
echo ""

succeeded=()
failed=()

for host in "${hosts[@]}"; do
    echo "========================================"
    echo "  Host: $host"
    echo "========================================"

    rc=0
    # 2>/dev/null: if ssh cannot connect, writing the script fails with a
    # broken pipe; ssh itself reports the real error.
    remote_script 2>/dev/null | ssh "${SSH_OPTS[@]}" -- "$host" 'bash -s' || rc=$?

    echo ""
    if [[ $rc -eq 0 ]]; then
        echo "  OK: $host"
        succeeded+=("$host")
    else
        if [[ $rc -eq 255 ]]; then
            reason="exit code 255: SSH connection or authentication failed"
        else
            reason="exit code $rc from bootstrap.sh"
        fi
        echo "  FAILED: $host ($reason)"
        failed+=("$host ($reason)")
    fi
    echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "========================================"
echo "  Summary"
echo "========================================"
echo ""
echo "  Succeeded: ${#succeeded[@]}/${#hosts[@]}"
if [[ ${#succeeded[@]} -gt 0 ]]; then
    for h in "${succeeded[@]}"; do
        echo "    OK: $h"
    done
fi

if [[ ${#failed[@]} -gt 0 ]]; then
    echo ""
    echo "  Failed: ${#failed[@]}/${#hosts[@]}"
    for h in "${failed[@]}"; do
        echo "    FAILED: $h"
    done
    echo ""
    exit 1
fi

echo ""
echo "All hosts bootstrapped successfully."
