#!/bin/sh
#
# Run test-portavault.sh under every POSIX shell available locally.
#
# Usage:
#   ./run-tests.sh
#   ./run-tests.sh -v
#

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TEST="$SCRIPT_DIR/test-portavault.sh"

VERBOSE=0
[ "${1:-}" = "-v" ] || [ "${1:-}" = "--verbose" ] && VERBOSE=1

failed=0
ran=0

run_with() {
    shell=$1
    if ! command -v "$shell" >/dev/null 2>&1; then
        printf '[run-tests] skip: %s not found\n' "$shell" >&2
        return 0
    fi
    if ! "$shell" -n "$TEST" 2>/dev/null; then
        printf '[run-tests] skip: %s cannot parse test script\n' "$shell" >&2
        return 0
    fi
    ran=$((ran + 1))
    printf '\n[run-tests] === %s ===\n' "$shell" >&2
    if [ "$VERBOSE" = "1" ]; then
        "$shell" "$TEST" -v || failed=$((failed + 1))
    else
        "$shell" "$TEST" || failed=$((failed + 1))
    fi
}

for shell in sh dash oksh ksh; do
    run_with "$shell"
done

printf '\n[run-tests] shells run: %s\n' "$ran" >&2
if [ "$failed" -gt 0 ]; then
    printf '[run-tests] %s shell(s) failed\n' "$failed" >&2
    exit 1
fi
printf '[run-tests] all shells passed\n' >&2
exit 0