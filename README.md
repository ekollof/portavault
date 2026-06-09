# portavault

Portable encrypted vault for **OpenBSD**, **FreeBSD**, and **Linux**.

**Design goal: as few dependencies as possible.** `portavault` is a single POSIX `sh` script with **no build step, no language runtime, and no third-party packages** beyond what a normal Unix base system already provides. The only dependency you must install separately is **GnuPG** (`gpg`). Everything else is a standard OS utility (`mount`, `gzip`, `mktemp`, loop/format tools, and the like).

It creates a FAT32 disk image, optionally compresses it with gzip, encrypts it with GPG (AES-256), and on demand decrypts into a private RAM-backed work directory (tmpfs on Linux/FreeBSD, `mfs` on OpenBSD), mounts via the OS-native loopback device, and tears everything down on close. Plaintext exists only in that memory-backed area while the vault is open.

## Dependencies

### Required (install yourself)

| Tool | Purpose |
|------|---------|
| `gpg` | Symmetric encrypt/decrypt (loopback pinentry required) |

### Base system (already on a normal Unix install)

These ship with OpenBSD, FreeBSD, or a typical Linux distribution — not separate packages to add for portavault:

| Tool | Purpose |
|------|---------|
| `/bin/sh`, `mount`, `umount`, `mktemp`, `od`, `dd` | Script runtime and mounts |
| `gzip` / `gunzip` | Compression (optional at create time) |
| `file` | FAT payload detection (gzip also detected via `od`) |
| **Linux:** `mkfs.fat`, `truncate` | FAT32 image creation |
| **Linux:** `curl` or `wget` | URL fetch only (if you open remote vaults) |
| **OpenBSD:** `vnconfig`, `newfs_msdos`, `mount_msdos`, `mount_mfs`, `ftp` | Loop, format, mount, RAM work dir, fetch |
| **FreeBSD:** `mdconfig`, `newfs_msdos`, `mount_msdosfs`, `fetch` | Loop, format, mount, fetch |

**Not used:** Python, Ruby, Node, Docker, `openssl enc`, FUSE modules, or any extra crypto stack beyond GPG.

### Privilege elevation (install yourself on BSD)

`open`, `close`, and `passwd` need root (mount + RAM-backed work directory). Run them via a small elevation helper:

| OS | Typical tool | Notes |
|----|--------------|-------|
| **Linux** | `sudo` | Usually in base; `create` does not need root |
| **OpenBSD** | `doas` | In base; configure `/etc/doas.conf` |
| **FreeBSD** | `sudo` or `doas` | **Not in a minimal base install** — install from ports, e.g. `pkg install sudo` |

`portavault` recognizes `SUDO_USER` / `SUDO_UID` (Linux and FreeBSD `sudo`) and `DOAS_USER` (OpenBSD and FreeBSD `doas`) so mounts and files stay owned by you.

On BSD, `create` also needs root for vnode formatting.

## Install

```sh
install -m 755 portavault /usr/local/bin/portavault
install -m 644 portavault.conf.example ~/.config/portavault.conf
# edit ~/.config/portavault.conf as needed
```

## Quick start

```sh
# Create a 1 GiB encrypted vault (Linux: no sudo needed)
portavault create ~/vault.img.gpg -s 1G

# Open (root via sudo on Linux/FreeBSD, or doas on OpenBSD)
sudo portavault open ~/vault.img.gpg -m ~/vault   # Linux, FreeBSD
# doas portavault open ~/vault.img.gpg -m ~/vault  # OpenBSD

# Use the mount, then close and save
echo "secret" > ~/vault/notes.txt
sudo portavault close   # or: doas portavault close

# Check status (no elevation needed while vault is open)
portavault status
```

## Commands

```
portavault create   <vault> [-s size] [--no-compress]
portavault open     [vault] [-m mountpoint]
portavault close
portavault status
portavault passwd   [vault]
portavault help
```

### `create`

Builds a FAT32 image, optionally gzip-compresses it, and encrypts with GPG.

```sh
portavault create ~/vault.img.gpg -s 512M
portavault create ~/vault.img.gpg -s 1G --no-compress
```

### `open`

Decrypts the vault into tmpfs and mounts the FAT32 image.

- Vault source: local path or URL (`http://`, `https://`, `ftp://`)
- **URL vaults are read-only** — changes are not saved on `close`
- Under `sudo` or `doas`, files are owned by the invoking user (`SUDO_UID` / `DOAS_USER`)

### `close`

Unmounts, re-encrypts local vaults atomically (`vault.new.$$` → `vault`), and wipes tmpfs plaintext.

### `passwd`

Re-encrypts a closed vault with a new passphrase (verifies before replacing).

## Configuration

Config file: `~/.config/portavault.conf` (parsed as `key=value`, not executed as shell).

| Key | Description |
|-----|-------------|
| `vault` | Default vault path or URL |
| `mount_point` | Default mount point for `open` |
| `size` | Default size for `create` (e.g. `1G`, `512M`) |
| `state_file` | Override state file path |
| `tmpfs_size` | Max tmpfs bytes on OpenBSD (default cap `8G`) |

Environment overrides: `PORTAVAULT_CONFIG`, `PORTAVAULT_STATE`, `PORTAVAULT_VAULT`, `PORTAVAULT_MOUNTPOINT`.

See [`portavault.conf.example`](portavault.conf.example).

## Security model

- **At rest:** GPG symmetric AES-256, SHA-512 S2K, high iteration count
- **In use:** decrypted image and GPG plaintext live on tmpfs only
- **On close / signal during `open`:** tmpfs unmounted, loop detached, state cleared
- **Config / state:** parsed as `key=value` (no shell sourcing); config must not be group/world-writable
- **Local save:** `close` validates vault path identity (device/inode) before overwriting

FAT32 has no Unix permissions; restrict access via mountpoint permissions (`chmod 700` on the mount point).

## Testing

```sh
./test-portavault.sh          # integration tests (67 checks)
./test-portavault.sh -v       # verbose
./run-tests.sh                # run tests under sh, dash, oksh, ksh
```

Tests use `sudo` on Linux and FreeBSD, `doas` on OpenBSD (passwordless or interactive).

## Platform notes

| OS | RAM work dir | Loop device | FAT mount |
|----|--------------|-------------|-----------|
| OpenBSD | `mount_mfs` | `vnconfig` (`vnd0`–`vnd7`) | `mount_msdos -m 700` |
| FreeBSD | `tmpfs` | `mdconfig` (auto unit) | `mount_msdosfs -m 700` |
| Linux | `tmpfs` | `mount -o loop` | `mount -t vfat` |

OpenBSD has no working `tmpfs` in the default kernel; `mount_mfs` size is derived from the vault (`size` config) and capped by `tmpfs_size`.

On **FreeBSD and OpenBSD**, images smaller than 256 MiB are formatted as **FAT16** (BSD `newfs_msdos` cannot fit FAT32 below that). Linux uses FAT32 at any supported size.

## License

BSD 3-Clause License. See [LICENSE](LICENSE).