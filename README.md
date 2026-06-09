# portavault

Portable encrypted vault for **OpenBSD**, **FreeBSD**, and **Linux**.

**Design goal: as few dependencies as possible.** `portavault` is a single POSIX `sh` script with **no build step, no language runtime, and no third-party packages** beyond what a normal Unix base system already provides. The only dependency you must install separately is **GnuPG** (`gpg`). Everything else is a standard OS utility (`mount`, `gzip`, `mktemp`, loop/format tools, and the like).

It creates a FAT32 disk image, optionally compresses it with gzip, encrypts it with GPG (AES-256), and on demand decrypts into a private tmpfs, mounts via the OS-native loopback device, and tears everything down on close. Plaintext exists only in memory-backed tmpfs while the vault is open.

## Dependencies

### Required (install yourself)

| Tool | Purpose |
|------|---------|
| `gpg` | Symmetric encrypt/decrypt (loopback pinentry required) |

### Base system (already on a normal Unix install)

These ship with OpenBSD, FreeBSD, or a typical Linux distribution — not separate packages to add for portavault:

| Tool | Purpose |
|------|---------|
| `/bin/sh`, `mount`, `umount`, `mktemp`, `truncate`, `od` | Script runtime and mounts |
| `gzip` / `gunzip` | Compression (optional at create time) |
| `file` | FAT payload detection (gzip also detected via `od`) |
| **Linux:** `mkfs.fat` | FAT32 image creation |
| **Linux:** `curl` or `wget` | URL fetch only (if you open remote vaults) |
| **OpenBSD:** `vnconfig`, `newfs_msdos`, `mount_tmpfs`, `ftp` | Loop, format, tmpfs, fetch |
| **FreeBSD:** `mdconfig`, `newfs_msdos`, `fetch` | Loop, format, fetch |

**Not used:** Python, Ruby, Node, Docker, `openssl enc`, FUSE modules, or any extra crypto stack beyond GPG.

**Privileges:** `open`, `close`, and `passwd` require root (tmpfs + mount). On Linux, `create` runs as a normal user; on BSD it needs root for vnode formatting.

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

# Open (sudo required)
sudo portavault open ~/vault.img.gpg -m ~/vault

# Use the mount, then close and save
echo "secret" > ~/vault/notes.txt
sudo portavault close

# Check status (no sudo needed when vault is open)
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
- On Linux under `sudo`, files are owned by the invoking user (`SUDO_UID`)

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

Requires passwordless or interactive `sudo` on Linux for mount tests.

## Platform notes

| OS | Loop device | FAT mount |
|----|-------------|-----------|
| OpenBSD | `vnconfig` (auto `vnd0`–`vnd7`) | `mount -t msdos` |
| FreeBSD | `mdconfig` (auto unit) | `mount -t msdosfs` |
| Linux | `mount -o loop` | `mount -t vfat` |

OpenBSD tmpfs size is derived from the encrypted file size (clamped by `size` and `tmpfs_size` config keys).

On **FreeBSD and OpenBSD**, images smaller than 256 MiB are formatted as **FAT16** (BSD `newfs_msdos` cannot fit FAT32 below that). Linux uses FAT32 at any supported size.

## License

BSD 3-Clause License. See [LICENSE](LICENSE).