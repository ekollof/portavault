# AGENTS.md — guide for AI coding agents

This document helps automated agents work safely and effectively on **portavault**.

## Project overview

**Primary design goal: as few dependencies as possible, besides GnuPG.**

**portavault** is a portable encrypted vault tool implemented as one POSIX `sh` script plus supporting files. Users install `gpg`; everything else must already exist on a normal OpenBSD, FreeBSD, or Linux system (`mount`, `gzip`, `mktemp`, OS loop/format tools). Do not add Python, Node, Ruby, FUSE, extra crypto CLIs, or packaged language runtimes.

| File | Role |
|------|------|
| [`portavault`](portavault) | Main program (all logic) |
| [`portavault.conf.example`](portavault.conf.example) | Example config (`key=value` format) |
| [`test-portavault.sh`](test-portavault.sh) | Integration test suite (67 checks) |
| [`run-tests.sh`](run-tests.sh) | Runs tests under multiple shells |

There is no build step, package manager, or library code. Changes are made directly to the shell script.

## Hard constraints (do not violate)

1. **Minimal dependencies** — `gpg` is the only deliberate install. All other commands must be standard base-system utilities on each supported OS. Never introduce a new third-party package, language runtime, or optional module. Before adding any command, ask: “is this already on a default Unix install?”
2. **POSIX `/bin/sh` only** — no bashisms (`[[ ]]`, arrays, `function` keyword, `source`, etc.). Must run on OpenBSD `/bin/sh`, FreeBSD `/bin/sh`, Linux `dash`, and `oksh`.
3. **No new external dependencies** — if a feature needs something beyond gpg + OS builtins, defer it or implement with existing tools only. On Linux, `curl` is allowed for URL fetch (`wget` as existing fallback).
4. **Do not source config or state** — both are parsed as `key=value` lines via `load_config()` / `read_state()`. Never use `. file` on user-controlled paths.
5. **Preserve OS branches** — platform logic uses `case "$OS" in openbsd|freebsd|linux)`. Test all three mentally when editing shared paths.
6. **Minimal diffs** — this is a small tool; avoid drive-by refactors, new markdown files, or scope creep unless asked.

## Architecture (mental model)

```
create:  truncate → format FAT32 → [gzip] → gpg encrypt → vault.gpg
open:    [fetch URL] → tmpfs → gpg decrypt → [gunzip] → loop mount FAT32
close:   umount → [re-gpg local vault] → detach loop → umount tmpfs
passwd:  tmpfs → gpg decrypt → gpg re-encrypt (new passphrase)
```

State file (`~/.config/portavault.state` by default) tracks an active session: mount point, loop device, tmpfs work dir, `ORIG_VAULT`, compression flag, read-only flag, and vault inode/device for save validation.

## Security-sensitive areas

When touching these, reason carefully and run tests:

- **`run_gpg()`** — runs `gpg` as `$SUDO_USER` under Linux sudo so GNUPGHOME ownership matches; pair with **`prepare_gpg_input()`** / **`chown_if_sudo()`** on root-created temp files.
- **`validate_orig_vault()`** — blocks symlink swaps and inode changes before `close` saves.
- **`check_config_perms()`** — rejects group/world-writable config (permission nibble positions 5 and 8 in `rw-rw-rw-` from `ls -l | cut -c2-10`).
- **`ORIG_READONLY`** — URL vaults skip save on `close`; do not re-enable upload without explicit user request.
- **Passphrases** — read via `read_passphrase()`, piped to `gpg --passphrase-fd 0`; clear variable after use.

## Linux + sudo behavior

- `resolve_home()` + `init_paths()` — correct `HOME` when invoked via `sudo`
- `effective_uid()` / `effective_gid()` — FAT mount ownership for invoking user
- `chown_if_sudo()` — state file readable by user after `sudo open`
- `create` does **not** require root on Linux

## Config keys (must match example file)

| Config key | Internal variable |
|------------|-------------------|
| `vault` | `VAULT` |
| `mount_point` | `MOUNT_POINT` |
| `size` | `DEFAULT_SIZE` |
| `state_file` | `PORTAVAULT_STATE` |
| `tmpfs_size` | `TMPFS_SIZE_CAP` |

## Testing workflow (required after changes)

Always verify syntax and run integration tests:

```sh
sh -n portavault
sh -n test-portavault.sh
./test-portavault.sh
./run-tests.sh          # sh, dash, oksh, ksh when available
```

Tests need `sudo` for mount operations on Linux. They use an isolated temp dir and test passphrase `portavault-test-secret`.

**Do not** commit real vault files, state files, or local `portavault.conf` (see [`.gitignore`](.gitignore)).

## Common tasks

### Add a config key

1. Add to `apply_config_kv()` in `portavault`
2. Document in `portavault.conf.example` and `usage()`
3. Add a test in `test-portavault.sh` if behavior is user-visible

### Change crypto settings

Edit `GPG_CIPHER_OPTS` / `GPG_DIGEST_OPTS` near the top of `portavault`. Ensure `check_gpg_loopback()` still passes.

### Add a subcommand

1. Implement `cmd_<name>()`
2. Wire in `main()` `case` dispatch
3. Update `usage()` and [`README.md`](README.md)
4. Add integration tests

## Pitfalls observed in prior work

- Hardcoded `vnd0` / `md0` — use `alloc_loop_attach()` instead
- OpenBSD tmpfs `-s 1g` cap — use `compute_tmpfs_bytes()`
- FAT32 on BSD needs ~256 MiB — `format_fat()` uses FAT16 below that via `MIN_FAT32_BYTES`
- `effective_uid` / `run_gpg` / `chown_if_sudo` — use `SUDO_UID` on all OS, not Linux-only
- Config example variable names must match `apply_config_kv()` mapping
- `set -e` in test scripts breaks on expected failures — test script uses `set -u` only
- Passing vault path on CLI when config already sets `vault` causes "unexpected argument"
- GPG under sudo needs `run_gpg`, not bare `gpg`

## Out of scope (unless user explicitly asks)

- Anything that adds dependencies beyond gpg + OS builtins (SFTP clients, FUSE, `openssl enc`, language runtimes, etc.)
- SFTP/SCP upload, macOS/NetBSD support, non-interactive GPG agent flow
- Multi-vault concurrency (single global state file by design)
- Rewriting in another language or adding a dependency manager

## Version and license

Script version is `VERSION=` near the top of `portavault` (currently `0.2.0`). Bump when making user-visible releases.

Licensed under **BSD 3-Clause** ([`LICENSE`](LICENSE)). Preserve copyright and license notices in source redistributions.