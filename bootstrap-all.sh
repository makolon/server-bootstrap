#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="$SCRIPT_DIR/hosts.txt"

BOOTSTRAP_FILES=(
    "$SCRIPT_DIR/bootstrap.sh"
    "$SCRIPT_DIR/post-install.sh"
    "$SCRIPT_DIR/pixi-global.toml"
)

# ---------------------------------------------------------------------------
# Validate that all required files exist locally
# ---------------------------------------------------------------------------
for f in "${BOOTSTRAP_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Required file not found: $f" >&2
        echo "Run this script from a local clone of the repository." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Validate hostname format (defense against injection via hosts.txt / args)
# ---------------------------------------------------------------------------
validate_host() {
    local host="$1"
    if [[ ! "$host" =~ ^[a-zA-Z0-9@._:-]+$ ]]; then
        echo "ERROR: Invalid hostname format: '$host'" >&2
        echo "Hostnames may only contain: letters, digits, @, ., _, :, -" >&2
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
    while IFS= read -r line; do
        line="${line%%#*}"       # strip comments
        line="${line// /}"       # strip whitespace
        [[ -z "$line" ]] && continue
        hosts+=("$line")
    done < "$HOSTS_FILE"
else
    echo "Usage: $0 [host1 host2 ...]"
    echo ""
    echo "Or create a hosts.txt file (one host per line) in the same directory."
    echo "See hosts.txt.example for the expected format."
    exit 1
fi

# Validate all hostnames before starting
for host in "${hosts[@]}"; do
    validate_host "$host"
done

echo "Bootstrapping ${#hosts[@]} host(s)..."
echo ""

# ---------------------------------------------------------------------------
# Run bootstrap on each host
#   - Files are transferred via scp (not downloaded on the remote from GitHub)
#   - Remote servers only need outbound access to conda-forge, not to GitHub
# ---------------------------------------------------------------------------
succeeded=()
failed=()

for host in "${hosts[@]}"; do
    echo "========================================"
    echo "  Host: $host"
    echo "========================================"

    REMOTE_TMP="\$HOME/.bootstrap-tmp-$$"

    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$host" "mkdir -p $REMOTE_TMP" \
       && scp -q "${BOOTSTRAP_FILES[@]}" "$host:$REMOTE_TMP/" \
       && ssh -o ConnectTimeout=10 "$host" "bash '$REMOTE_TMP/bootstrap.sh'; rm -rf '$REMOTE_TMP'"; then
        echo ""
        echo "  OK: $host"
        succeeded+=("$host")
    else
        echo ""
        echo "  FAILED: $host (exit code $?)"
        failed+=("$host")
        # Clean up remote temp dir on failure
        ssh -o ConnectTimeout=10 "$host" "rm -rf '$REMOTE_TMP'" 2>/dev/null || true
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
for h in "${succeeded[@]}"; do
    echo "    OK: $h"
done

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
