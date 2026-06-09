#!/bin/sh
#
# Integration tests for portavault.
# POSIX sh only. Run from the repo root or any directory.
#
# Usage:
#   ./test-portavault.sh          # run all tests
#   ./test-portavault.sh -v       # verbose (show command output)
#   ./test-portavault.sh --keep    # keep temp dir on success
#
# Requirements:
#   - portavault script in the same directory as this file
#   - gpg with loopback pinentry enabled
#   - doas on OpenBSD, sudo on Linux/FreeBSD (passwordless or interactive)
#     for open/close/passwd and other mount operations
#

set -u

VERBOSE=0
KEEP=0
TESTS_RUN=0
TESTS_FAILED=0
TESTS_SKIPPED=0

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose) VERBOSE=1; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help)
            sed -n '2,14p' "$0"
            exit 0
            ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PV="$SCRIPT_DIR/portavault"
TD=$(mktemp -d "${TMPDIR:-/tmp}/portavault-test.XXXXXX")

PASS=portavault-test-secret
PASS2=portavault-test-secret-2

PORTAVAULT_STATE="$TD/portavault.state"
PORTAVAULT_CONFIG="$TD/portavault.conf"

# ---- helpers -------------------------------------------------------------

log() { printf '[test] %s\n' "$*" >&2; }

verbose() {
    if [ "$VERBOSE" = "1" ]; then
        printf '%s\n' "$*" >&2
    fi
}

run_cmd() {
    verbose "+ $*"
    "$@"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n' "$*" >&2
}

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  ok: %s\n' "$1" >&2
}

skip() {
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    printf '  skip: %s\n' "$1" >&2
}

assert_success() {
    name=$1
    shift
    if output=$(run_cmd "$@" 2>&1); then
        pass "$name"
    else
        fail "$name"
        verbose "$output"
        output=
    fi
    printf '%s' "$output"
}

assert_failure() {
    name=$1
    shift
    if output=$(run_cmd "$@" 2>&1); then
        fail "$name (expected failure, got success)"
        verbose "$output"
    else
        pass "$name"
        verbose "$output"
    fi
}

assert_contains() {
    name=$1
    haystack=$2
    needle=$3
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$haystack" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name (missing: $needle)"; verbose "$haystack" ;;
    esac
}

assert_not_contains() {
    name=$1
    haystack=$2
    needle=$3
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$haystack" in
        *"$needle"*) fail "$name (unexpected: $needle)"; verbose "$haystack" ;;
        *) pass "$name" ;;
    esac
}

assert_file() {
    name=$1
    path=$2
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -f "$path" ]; then
        pass "$name"
    else
        fail "$name (missing file: $path)"
    fi
}

assert_eq() {
    name=$1
    want=$2
    got=$3
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name (want '$want', got '$got')"
    fi
}

write_config() {
    vault=$1
    mount_point=$2
    size=${3:-64M}
    cat > "$PORTAVAULT_CONFIG" <<EOF
vault=$vault
mount_point=$mount_point
size=$size
EOF
}

PRIV_CMD=
NEED_PRIV=0

# Run a command with test env; elevate via doas (OpenBSD) or sudo when needed.
priv_run() {
    if [ "$NEED_PRIV" = "1" ] && [ "$(id -u)" != "0" ] && [ -n "$PRIV_CMD" ]; then
        case "$PRIV_CMD" in
            sudo)
                sudo -E env \
                    PORTAVAULT_STATE="$PORTAVAULT_STATE" \
                    PORTAVAULT_CONFIG="$PORTAVAULT_CONFIG" \
                    "$@"
                ;;
            doas)
                doas env \
                    PORTAVAULT_STATE="$PORTAVAULT_STATE" \
                    PORTAVAULT_CONFIG="$PORTAVAULT_CONFIG" \
                    "$@"
                ;;
        esac
    else
        env \
            PORTAVAULT_STATE="$PORTAVAULT_STATE" \
            PORTAVAULT_CONFIG="$PORTAVAULT_CONFIG" \
            "$@"
    fi
}

run_pv() {
    priv_run "$PV" "$@"
}

run_pv_user() {
    env \
        PORTAVAULT_STATE="$PORTAVAULT_STATE" \
        PORTAVAULT_CONFIG="$PORTAVAULT_CONFIG" \
        "$PV" "$@"
}

pipe_pv() {
    priv_run "$PV" "$@"
}

priv_tee() {
    target=$1
    if [ "$NEED_PRIV" = "1" ] && [ "$(id -u)" != "0" ] && [ -n "$PRIV_CMD" ]; then
        $PRIV_CMD tee "$target"
    else
        tee "$target"
    fi
}

detect_os() {
    case "$(uname -s)" in
        OpenBSD) OS=openbsd ;;
        FreeBSD) OS=freebsd ;;
        Linux)   OS=linux ;;
        *)       OS=unknown ;;
    esac
}

setup_priv() {
    NEED_PRIV=0
    PRIV_CMD=
    case "$OS" in
        openbsd|freebsd|linux) NEED_PRIV=1 ;;
    esac
    if [ "$NEED_PRIV" = "1" ] && [ "$(id -u)" != "0" ]; then
        case "$OS" in
            openbsd)
                if command -v doas >/dev/null 2>&1; then
                    PRIV_CMD=doas
                else
                    log "doas not found (required on OpenBSD)"
                    exit 1
                fi
                ;;
            *)
                if command -v sudo >/dev/null 2>&1; then
                    PRIV_CMD=sudo
                else
                    log "sudo not found"
                    exit 1
                fi
                ;;
        esac
        case "$PRIV_CMD" in
            doas)
                if ! doas -n true 2>/dev/null; then
                    log "doas required; you may be prompted for a password"
                    doas true || exit 1
                fi
                ;;
            sudo)
                if ! sudo -n true 2>/dev/null; then
                    log "sudo required; you may be prompted for a password"
                    sudo true || exit 1
                fi
                ;;
        esac
    fi
}

cleanup() {
    if [ -d "$TD" ]; then
        run_pv close 2>/dev/null || true
        for mnt in "$TD"/mnt-plain "$TD"/mnt-comp "$TD"/mnt "$TD"/mnt2; do
            umount "$mnt" 2>/dev/null || true
        done
        if [ "$KEEP" = "1" ] && [ "$TESTS_FAILED" -eq 0 ]; then
            log "kept artifacts at $TD"
        else
            rm -rf "$TD" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT INT TERM

file_owner_uid() {
    path=$1
    case "$OS" in
        linux) stat -c '%u' "$path" 2>/dev/null ;;
        *)     stat -f '%u' "$path" 2>/dev/null ;;
    esac
}

reset_state() {
    run_pv close 2>/dev/null || true
    rm -f "$PORTAVAULT_STATE"
}

# ---- tests ---------------------------------------------------------------

test_prerequisites() {
    log "prerequisites"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -x "$PV" ]; then
        fail "portavault executable not found at $PV"
        exit 1
    fi
    pass "portavault found"
    sh -n "$PV" || { fail "portavault syntax check"; exit 1; }
    pass "portavault syntax"
    sh -n "$0" || { fail "test script syntax"; exit 1; }
    pass "test script syntax"
}

test_help() {
    log "help"
    out=$(assert_success "help exits 0" run_pv_user help)
    assert_contains "help mentions create" "$out" "create"
    assert_contains "help mentions open" "$out" "open"
    assert_contains "help mentions read-only URL" "$out" "read-only"
}

test_status_inactive() {
    log "status (no vault)"
    reset_state
    out=$(assert_success "status inactive" run_pv_user status)
    assert_contains "status reports inactive" "$out" "no active vault"
}

test_close_without_vault() {
    log "close without vault"
    reset_state
    assert_failure "close fails when inactive" run_pv close
}

test_config_world_writable() {
    log "config permission check"
    reset_state
    write_config "$TD/v.gpg" "$TD/mnt"
    chmod 666 "$PORTAVAULT_CONFIG"
    assert_failure "reject world-writable config" run_pv_user status
    chmod 644 "$PORTAVAULT_CONFIG"
}

test_create_uncompressed() {
    log "create (uncompressed)"
    reset_state
    write_config "$TD/plain.gpg" "$TD/mnt-plain"
    out=$(printf '%s\n' "$PASS" | pipe_pv create "$TD/plain.gpg" -s 64M --no-compress)
    assert_file "uncompressed vault created" "$TD/plain.gpg"
    assert_not_contains "no gpg homedir warning (create)" "$out" "unsafe ownership"
}

test_create_compressed() {
    log "create (compressed)"
    reset_state
    write_config "$TD/comp.gpg" "$TD/mnt-comp"
    out=$(printf '%s\n' "$PASS" | pipe_pv create "$TD/comp.gpg" -s 64M)
    assert_file "compressed vault created" "$TD/comp.gpg"
    assert_not_contains "no gpg homedir warning (create compressed)" "$out" \
        "unsafe ownership"
}

test_open_from_config() {
    log "open from config"
    reset_state
    write_config "$TD/plain.gpg" "$TD/mnt-plain"
    out=$(printf '%s\n' "$PASS" | pipe_pv open)
    assert_contains "open succeeds" "$out" "vault opened"
    assert_not_contains "no gpg homedir warning (open)" "$out" "unsafe ownership"
}

test_write_and_ownership() {
    log "write and ownership"
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf 'integration test\n' > "$TD/mnt-plain/testfile.txt" 2>/dev/null; then
        :
    else
        printf 'integration test\n' | priv_tee "$TD/mnt-plain/testfile.txt" >/dev/null
    fi
    if [ -f "$TD/mnt-plain/testfile.txt" ]; then
        pass "wrote testfile.txt"
    else
        fail "could not write testfile.txt"
        return
    fi
    uid=$(file_owner_uid "$TD/mnt-plain/testfile.txt")
    assert_eq "mount file owned by invoking user" "$(id -u)" "$uid"
}

test_status_active() {
    log "status (active)"
    out=$(assert_success "status active" run_pv_user status)
    assert_contains "status shows source" "$out" "$TD/plain.gpg"
    assert_contains "status shows mount point" "$out" "$TD/mnt-plain"
}

test_state_permissions() {
    log "state file permissions"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -f "$PORTAVAULT_STATE" ]; then
        fail "state file missing"
        return
    fi
    mode=$(ls -l "$PORTAVAULT_STATE" | cut -c2-10)
    case "$mode" in
        rw-------) pass "state mode 600" ;;
        *) fail "state mode not 600 ($mode)" ;;
    esac
    uid=$(ls -ln "$PORTAVAULT_STATE" | awk '{print $3}')
    assert_eq "state owned by invoking user" "$(id -u)" "$uid"
}

test_double_open_fails() {
    log "double open rejected"
    assert_failure "second open fails" \
        sh -c "printf '%s\n' '$PASS' | $(pv_pipe_cmd) open"
}

# Emit a shell snippet for piping into portavault under doas/sudo when needed.
pv_pipe_cmd() {
    if [ "$NEED_PRIV" = "1" ] && [ "$(id -u)" != "0" ] && [ -n "$PRIV_CMD" ]; then
        case "$PRIV_CMD" in
            sudo)
                printf "sudo -E env PORTAVAULT_STATE=%s PORTAVAULT_CONFIG=%s %s" \
                    "$PORTAVAULT_STATE" "$PORTAVAULT_CONFIG" "$PV"
                ;;
            doas)
                printf "doas env PORTAVAULT_STATE=%s PORTAVAULT_CONFIG=%s %s" \
                    "$PORTAVAULT_STATE" "$PORTAVAULT_CONFIG" "$PV"
                ;;
        esac
    else
        printf "env PORTAVAULT_STATE=%s PORTAVAULT_CONFIG=%s %s" \
            "$PORTAVAULT_STATE" "$PORTAVAULT_CONFIG" "$PV"
    fi
}

test_close_and_persist() {
    log "close and persist"
    out=$(printf '%s\n' "$PASS" | pipe_pv close)
    assert_contains "close saves vault" "$out" "vault saved"
    assert_not_contains "no gpg homedir warning (close)" "$out" "unsafe ownership"
    out=$(assert_success "status inactive after close" run_pv_user status)
    assert_contains "inactive after close" "$out" "no active vault"
}

test_reopen_verify() {
    log "reopen and verify data"
    out=$(printf '%s\n' "$PASS" | pipe_pv open)
    assert_contains "reopen succeeds" "$out" "vault opened"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -q 'integration test' "$TD/mnt-plain/testfile.txt" 2>/dev/null; then
        pass "persisted data readable"
    else
        fail "persisted data missing"
    fi
    printf '%s\n' "$PASS" | pipe_pv close >/dev/null
}

test_compressed_roundtrip() {
    log "compressed vault roundtrip"
    reset_state
    write_config "$TD/comp.gpg" "$TD/mnt-comp"
    printf '%s\n' "$PASS" | pipe_pv open -m "$TD/mnt-comp" 2>&1 \
        | grep -v '^Passphrase' >/dev/null
    TESTS_RUN=$((TESTS_RUN + 1))
    if mount | grep -q "$TD/mnt-comp"; then
        pass "compressed vault mounted"
    else
        fail "compressed vault not mounted"
    fi
    if printf 'compressed\n' > "$TD/mnt-comp/blob.txt" 2>/dev/null; then
        :
    else
        printf 'compressed\n' | priv_tee "$TD/mnt-comp/blob.txt" >/dev/null
    fi
    printf '%s\n' "$PASS" | pipe_pv close >/dev/null
    printf '%s\n' "$PASS" | pipe_pv open -m "$TD/mnt-comp" 2>&1 \
        | grep -v '^Passphrase' >/dev/null
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$(cat "$TD/mnt-comp/blob.txt" 2>/dev/null)" = "compressed" ]; then
        pass "compressed data persisted"
    else
        fail "compressed data not persisted"
    fi
    printf '%s\n' "$PASS" | pipe_pv close >/dev/null
}

test_passwd() {
    log "passwd"
    reset_state
    write_config "$TD/plain.gpg" "$TD/mnt-plain"
    out=$(printf '%s\n%s\n%s\n' "$PASS" "$PASS2" "$PASS2" \
        | pipe_pv passwd "$TD/plain.gpg")
    assert_not_contains "no gpg homedir warning (passwd)" "$out" "unsafe ownership"
    out=$(printf '%s\n' "$PASS" | pipe_pv open 2>&1) || true
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$out" in
        *decrypt\ failed*|*gpg\ decrypt\ failed*)
            pass "old passphrase rejected" ;;
        *) fail "old passphrase should fail"; verbose "$out" ;;
    esac
    if printf '%s\n' "$PASS2" | pipe_pv open >/dev/null 2>&1; then
        pass "vault opens with new passphrase"
    else
        fail "vault open with new passphrase failed"
    fi
    printf '%s\n' "$PASS2" | pipe_pv close >/dev/null 2>&1 || true
    PASS=$PASS2
}

test_passwd_while_open_fails() {
    log "passwd while open"
    write_config "$TD/plain.gpg" "$TD/mnt-plain"
    printf '%s\n' "$PASS" | pipe_pv open >/dev/null
    assert_failure "passwd blocked while open" \
        run_pv passwd "$TD/plain.gpg"
    printf '%s\n' "$PASS" | pipe_pv close >/dev/null
}

test_create_exists_fails() {
    log "create existing file"
    assert_failure "create rejects existing" \
        sh -c "printf '%s\n' '$PASS' | $(pv_pipe_cmd) create '$TD/plain.gpg' -s 64M"
}

test_url_readonly_warning() {
    log "URL read-only warning"
    reset_state
    printf 'mount_point=%s\n' "$TD/mnt-url" > "$PORTAVAULT_CONFIG"
    out=$(printf '%s\n' "$PASS" | pipe_pv open \
        "https://127.0.0.1:9/none.gpg" -m "$TD/mnt-url" 2>&1) || true
    assert_contains "URL warns read-only" "$out" "read-only"
}

test_url_readonly_skip_save() {
    log "URL read-only close skips save"
    reset_state
    write_config "$TD/plain.gpg" "$TD/mnt-plain"
    printf '%s\n' "$PASS" | pipe_pv open >/dev/null
    # Simulate URL vault: flip state to read-only with a URL source.
    {
        grep -v '^ORIG_VAULT=' "$PORTAVAULT_STATE" | grep -v '^ORIG_READONLY='
        printf 'ORIG_VAULT=https://example.com/vault.gpg\n'
        printf 'ORIG_READONLY=1\n'
    } > "$PORTAVAULT_STATE.new"
    mv "$PORTAVAULT_STATE.new" "$PORTAVAULT_STATE"
    chmod 600 "$PORTAVAULT_STATE"
    out=$(printf '%s\n' "$PASS" | pipe_pv close 2>&1)
    assert_contains "close skips URL save" "$out" "skipping save"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -f "https://example.com/vault.gpg" ]; then
        pass "no bogus URL file created"
    else
        fail "bogus URL file created"
    fi
}

test_open_already_active_message() {
    log "open while active"
    write_config "$TD/plain.gpg" "$TD/mnt-plain"
    printf '%s\n' "$PASS" | pipe_pv open >/dev/null
    assert_failure "open while active fails" \
        sh -c "printf '%s\n' '$PASS' | $(pv_pipe_cmd) open"
    printf '%s\n' "$PASS" | pipe_pv close >/dev/null
}

# ---- main ----------------------------------------------------------------

main() {
    detect_os
    setup_priv
    log "portavault test suite (OS=$OS, dir=$TD)"
    log "portavault=$PV"

    test_prerequisites
    test_help
    test_status_inactive
    test_close_without_vault
    test_config_world_writable
    test_create_uncompressed
    test_create_compressed
    test_open_from_config
    test_write_and_ownership
    test_status_active
    test_state_permissions
    test_double_open_fails
    test_close_and_persist
    test_reopen_verify
    test_compressed_roundtrip
    test_passwd
    test_passwd_while_open_fails
    test_create_exists_fails
    test_url_readonly_warning
    test_url_readonly_skip_save
    test_open_already_active_message

    log "results: $TESTS_RUN run, $TESTS_FAILED failed, $TESTS_SKIPPED skipped"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main