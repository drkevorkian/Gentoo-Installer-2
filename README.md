# Gentoo UEFI installer

[`gentoo_installer.sh`](gentoo_installer.sh) installs Gentoo with **UEFI**, **ext4** on `/`, optional **mdadm** RAID when multiple disks are listed, optional GUI (Plasma, GNOME, Xfce), and optional server packages (Apache, MariaDB, phpMyAdmin, vsftpd — off by default). Run it from a live environment as **root**.

**Host scope:** Defaults assume a **dedicated install environment** (e.g. official Gentoo LiveCD). See **`INSTALLER_LIVE_ENV`** below; set it to **`NO`** only when you understand the narrower cleanup behavior.

See the script header for **`PROFILE_TARGET`**, **`INIT_SYSTEM`**, and resume options.

## Install summary (before and after the run)

On startup, **`installer_gate_self_update`** runs as soon as the script can (right after optional **`--help`** without root). It calls **`need_root`**, then the [upstream version check](#upstream-version-check) so the live copy can **`exec`** into a newer script before any install work. After disk resolution, network check, stage3 selection, and **`require_inputs`**, the script prints an **install selection** banner: disks, RAID layout, stage3, GUI/server flags, and safety variables—**this is what you asked for and what will be installed**. When the pipeline completes, **`finish_msg`** prints an **install result** section: active Portage profile under **`$TARGET`**, kernel and initramfs names in **`/boot`**, first-user presence in **`/etc/passwd`**, **`DONE`** lines from the state file, and the first lines of **`/etc/fstab`**.

## Upstream version check

At process entry, **`installer_gate_self_update`** runs **`need_root`** and then (unless **`CHECK_UPSTREAM=NO`**) downloads the raw [`gentoo_installer.sh`](https://github.com/drkevorkian/Gentoo-Installer-2/blob/main/gentoo_installer.sh) from [**drkevorkian/Gentoo-Installer-2**](https://github.com/drkevorkian/Gentoo-Installer-2) and compares **`# INSTALLER_VERSION=`** (semver **`MAJOR.MINOR.PATCH`**) to your copy.

- **Version line:** **`MAJOR.MINOR.PATCH`** — major overhaul · major update · minor update (e.g. **`1.3.5`**). Older copies that used a **single integer** (digits only) are ordered as **`0.0.N`** for comparison only, so **`1.x.y`** correctly reads as newer than those legacy counters.
- **`UPSTREAM_AUTO_UPDATE=YES`** (default): if GitHub is newer, the download is validated (**shebang**, **`bash -n`**), current settings are written to **`gentoo_installer.conf`** (see below), then **`chmod +x`**, replace-in-place, and **`exec`** with the **same argv** plus inherited environment so the new script reloads your choices.
- **`UPSTREAM_AUTO_UPDATE=NO`**: only print a warning; **`UPSTREAM_STRICT=YES`** then aborts if GitHub is newer.

Override repo/ref with **`INSTALLER_GITHUB_REPO`** and **`INSTALLER_GITHUB_REF`** if you fork. The script directory must be writable for in-place replacement.

## Persistent settings (`gentoo_installer.conf`)

Beside **`gentoo_installer.sh`** (default path **`$SCRIPT_DIR/gentoo_installer.conf`**, override with **`GENTOO_INSTALLER_CONF`**) you can keep **`VAR=value`** lines for installer options so they survive script replacements.

- **Load order:** that file is read **before** script defaults. Any variable **already set in the environment** (e.g. `INSTALL_DISKS=/dev/nvme0n1 ./gentoo_installer.sh`) **wins** and is not overwritten by the file.
- **Self-update:** before **`exec`** to a newer GitHub copy, the installer writes the same file (**`SAVE_INSTALLER_CONF=YES`**, default) with **`chmod 600`**, using **`printf '%q'`** quoting. **Password variables are omitted** unless **`SAVE_INSTALLER_SECRETS=YES`** (avoid on shared machines).
- **Manual edit:** use **`KEY=value`** or **`export KEY=value`**; **`#`** starts a comment line. Only a fixed allowlist of keys is loaded (see **`installer_conf_tracked_keys`** in the script).

## Requirements

- **Architecture:** amd64  
- **Firmware:** UEFI  
- **Network:** stage3 download, Portage sync, binary kernel  
- **Host tools:** see the `need_cmd` loop in `main()` (`wget`, `md5sum` when verification is on, `sgdisk`, `mdadm`, `chroot`, …)

## Disks and RAID

### `INSTALL_DISKS`

Space-separated **whole disk** paths (e.g. `/dev/sda /dev/sdb /dev/sdc` or a single `/dev/nvme0n1`). The script checks **`lsblk` `TYPE=disk`** for each path and rejects partitions and LVM volumes so the GPT layout is applied to the correct device.

- **If empty (default):** the installer uses legacy **`DISK_A`** and **`DISK_B`**: each path that exists as a **block device** is included (one or two disks). If only **`DISK_A`** exists (common when there is no **`/dev/sdb`**), a single-disk install is used and a **NOTE** is printed. For RAID across specific disks, set **`INSTALL_DISKS`** explicitly.
- **One disk:** GPT layout is EFI (`EF00`) + Linux root (`8300`) on partition 2. No mdadm array; root is mounted directly. **`ROOT_RAID_LEVEL`** is ignored (a notice is printed if set).
- **Two or more disks:** each disk gets EFI + Linux RAID (`FD00`) on partition 2; **`mdadm`** builds **`$MD`** (default `/dev/md0`) across **all** disks using **`ROOT_RAID_LEVEL`**.

Partition names follow **`disk_part()`** in the script (e.g. `/dev/sda1` vs `/dev/nvme0n1p1`).

### `ROOT_RAID_LEVEL` (multi-disk only)

| Level   | Minimum disks | Notes |
|---------|----------------|-------|
| raid0   | 2 | Stripe |
| raid1   | 2 | Mirror; internal bitmap |
| raid4   | 3 | |
| raid5   | 3 | |
| raid6   | 4 | |
| raid10  | 4, **even** count | Uses **`ROOT_RAID10_LAYOUT`** (default **`n2`**) |

### `ROOT_RAID10_LAYOUT`

Passed to **`mdadm --layout=`** for **raid10** only (e.g. **`n2`**, **`o2`**, **`f2`**).

### `CONFIRM_ERASE`

Must equal:

```text
ERASE-<basename1>-<basename2>-...
```

where basenames are **`basename /dev/...`** for each install disk, sorted **lexicographically** (`LC_ALL=C`). Examples:

- One disk `/dev/nvme0n1` → **`CONFIRM_ERASE=ERASE-nvme0n1`**
- Legacy two disks `DISK_A=/dev/sda` `DISK_B=/dev/sdb` → **`ERASE-sda-sdb`**
- **`INSTALL_DISKS="/dev/sdc /dev/sda /dev/sdb"`** → **`ERASE-sda-sdb-sdc`**

### ESP / GRUB

- **`/boot/efi`** uses the **first** disk’s EFI partition.
- Extra disks mount at **`/boot/efi2`**, **`/boot/efi3`**, … inside the target.
- **`GRUB_INSTALL_TO_DISK_B=YES`** (default): after **`grub-install`** on the primary ESP, the installer runs **`grub-install`** + **`rsync`** to each additional ESP (**`mirror_esp_to_additional_disks`**).

### Root volume and initramfs

- **Single disk:** kernel cmdline uses **`root=UUID=…`** without **`rd.auto`**; dracut is built **without** the **`mdraid`** module.
- **RAID:** **`rd.auto=1`** and dracut **`mdraid`**; **`/etc/mdadm.conf`** is populated from **`mdadm --detail --scan`**.

## Init system: systemd vs OpenRC

**`INIT_SYSTEM`** selects stage3, Portage profile suffix (`…/systemd` vs `…/openrc`), and **`systemctl`** vs **`rc-update`**.

| `INIT_SYSTEM` | Auto stage3 flavor (when `STAGE3_FLAVOR_AUTO=YES`) |
|---------------|------------------------------------------------------|
| `systemd` (default) | `systemd` or `hardened-systemd` if `PROFILE_TARGET` starts with `hardened` |
| `openrc` | `openrc` or `hardened-openrc` for hardened targets |

## Important variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `ARMED` | `YES` | Must be `YES` |
| `WIPE_DISKS` | `YES` | Must be `YES` |
| `INSTALL_DISKS` | *(empty)* | Space-separated disks; empty ⇒ each of `DISK_A`, `DISK_B` that exists as a block device |
| `DISK_A`, `DISK_B` | `/dev/sda`, `/dev/sdb` | Used only when **`INSTALL_DISKS`** is empty |
| `CONFIRM_ERASE` | *(empty)* | Must match the **`ERASE-…`** formula above |
| `ROOT_RAID_LEVEL` | `raid0` | `raid0`–`raid10` for multi-disk |
| `ROOT_RAID10_LAYOUT` | `n2` | mdadm layout for raid10 |
| `MD` | `/dev/md0` | RAID device node (multi-disk) |
| `INIT_SYSTEM` | `systemd` | `systemd` or `openrc` |
| `PROFILE_TARGET` | `hardened-plasma` | Portage profile selection |
| `STAGE3_VERIFY_MD5` | `YES` | Verify stage3 tarball against **`${STAGE3}.DIGESTS`** using **SHA512** if present, else **SHA256**, else **MD5** (name kept for backward compatibility) |
| `INSTALL_SERVER_STACK` | `NO` | `YES` installs Apache, MariaDB, PHP, phpMyAdmin, vsftpd (large attack surface; enable only when needed) |
| `INSTALLER_LIVE_ENV` | `YES` | `YES`: **`swapoff -a`** and stop **all** `/dev/md*` before partitioning (typical LiveCD). `NO`: only unmount **`$TARGET`** and stop **`$MD`** — use on multi-purpose hosts only with care |
| `CHECK_UPSTREAM` | `YES` | Compare **`# INSTALLER_VERSION=`** (**semver** **`MAJOR.MINOR.PATCH`**) to GitHub raw script before continuing |
| `UPSTREAM_AUTO_UPDATE` | `YES` | If GitHub is newer: replace this script in place, **`chmod +x`**, **`exec`** same argv |
| `UPSTREAM_STRICT` | `NO` | `YES`: exit if GitHub is newer and auto-update is off or failed |
| `INSTALLER_GITHUB_REPO` | `drkevorkian/Gentoo-Installer-2` | **`owner/repo`** for **`raw.githubusercontent.com`** |
| `INSTALLER_GITHUB_REF` | `main` | Branch or tag name on GitHub |
| `GENTOO_INSTALLER_CONF` | *`$SCRIPT_DIR/gentoo_installer.conf`* | Optional settings file (loaded early; snapshot before self-update) |
| `SAVE_INSTALLER_CONF` | `YES` | Write that file before replacing the script from GitHub |
| `SAVE_INSTALLER_SECRETS` | `NO` | `YES`: include **`FIRST_USER_PASSWORD`** / **`ROOT_PASSWORD`** in the saved file |

Further options (GUI, passwords, swap, **`GRUB_INSTALL_TO_DISK_B`**, …) are at the top of [`gentoo_installer.sh`](gentoo_installer.sh).

Bump **`# INSTALLER_VERSION=`** (**`MAJOR.MINOR.PATCH`**) near the top of the script when you release so the upstream check stays meaningful.

## Download verification

When **`STAGE3_VERIFY_MD5=YES`**, the installer downloads **`${STAGE3}.DIGESTS`** and checks the tarball using **SHA512** (preferred), **SHA256**, or **MD5**, matching the sections present in the file. Gentoo often omits MD5 now; the variable name is unchanged for compatibility.

Gentoo’s **`latest-stage3-amd64-*.txt`** index files are **OpenPGP cleartext-signed**; the installer skips the armor and comment lines and reads the **`…/stage3-….tar.xz`** path line.

## Stage3 / `INIT_SYSTEM` consistency

Manual **`STAGE3`** URLs must match **`INIT_SYSTEM`** (openrc vs systemd tarball names). See script **`validate_init_stage3_consistency`**.

**Portage / `emerge-webrsync`:** On **`RESUME=YES`** or if a previous run left **`/var/db/repos/gentoo`** half-synced, **`emerge-webrsync`** can exit with a timestamp / gemato warning. The bootstrap script clears **`metadata/timestamp.x`**, retries, then tries **`--revert`**, then removes the partial tree and re-fetches if needed.

## Examples

Legacy two-disk RAID0 (sorted erase token **`ERASE-sda-sdb`**):

```bash
sudo ARMED=YES WIPE_DISKS=YES CONFIRM_ERASE=ERASE-sda-sdb ./gentoo_installer.sh
```

Single NVMe disk:

```bash
sudo INSTALL_DISKS=/dev/nvme0n1 CONFIRM_ERASE=ERASE-nvme0n1 \
  ARMED=YES WIPE_DISKS=YES ./gentoo_installer.sh
```

Three-disk RAID5:

```bash
sudo INSTALL_DISKS="/dev/sda /dev/sdb /dev/sdc" ROOT_RAID_LEVEL=raid5 \
  CONFIRM_ERASE=ERASE-sda-sdb-sdc ARMED=YES WIPE_DISKS=YES ./gentoo_installer.sh
```

OpenRC server on two disks (with optional LAMP / phpMyAdmin stack):

```bash
sudo INIT_SYSTEM=openrc PROFILE_TARGET=server INSTALL_SERVER_STACK=YES \
  ARMED=YES WIPE_DISKS=YES CONFIRM_ERASE=ERASE-sda-sdb ./gentoo_installer.sh
```

## Production use

Treat this like **infrastructure automation**, not a casual script:

- **Host:** Run only from a **known-good live image** or locked-down netboot; keep **`INSTALLER_LIVE_ENV=YES`** unless you fully understand **`swapoff`** / **md** cleanup scope on multi-purpose machines.
- **Supply chain:** Prefer **`UPSTREAM_AUTO_UPDATE=YES`** with your fork (**`INSTALLER_GITHUB_REPO`** / **`INSTALLER_GITHUB_REF`** are validated for URL-safe characters). For frozen environments use **`CHECK_UPSTREAM=NO`** or **`UPSTREAM_AUTO_UPDATE=NO`** and **`UPSTREAM_STRICT=YES`** after you pin a reviewed copy.
- **Audit:** Every run opens the log with an **installer session** header (version, host, time, paths). **`LOG`** / **`STATE`** are **`0600`**; when **`LOG_DIR`** sits under the script directory tree it is forced to **`0700`**.
- **CONFIRM_ERASE:** Always derive it from **`--print-erase-token`** (or the documented formula); never paste untrusted text (embedded newlines are rejected).
- **Accounts:** With **`FIRST_USER_ENABLE=YES`**, **`FIRST_USER_NAME`** must be a **POSIX login name** (lowercase **`[a-z_][a-z0-9_-]*`**, max 32 chars).
- **Evidence:** Archive **`LOG`** and **`STATE`** with change tickets; **`RESUME`** / **`--reset-phase`** are for controlled reruns after fixing failures.

## Limitations

- **Line endings:** If you edit this repo on Windows, keep **`gentoo_installer.sh`** checked out with **LF** (not CRLF). The installer strips carriage returns from chroot heredocs, but the main script itself should be LF-only on the LiveCD.
- **Chroot failures:** If the crash **`Command`** line shows **`chroot`**, the failure is almost always inside the nested bash script. Re-run with **`CHROOT_DEBUG=YES`** for **`bash -x`** in the target, and read **`gentoo_install.log`** from the last **`CHROOT>`** line upward.
- **Whole-disk paths** only (partition numbers are fixed: EFI `1`, root or RAID member `2`); the script enforces this with **`lsblk`**.
- **RAID levels** supported are those wired in **`ROOT_RAID_LEVEL`** (0, 1, 4, 5, 6, 10).
- **Firmware:** UEFI only (no legacy BIOS boot flow in this script).
- **Full install validation** is still your responsibility: run in a VM or spare hardware.

## Resume and reset

State file under the log directory; see **`RESUME`**, **`--reset`**, and **`--reset-phase`** in `main()`.

**Dry helper:** after setting **`INSTALL_DISKS`** (or legacy **`DISK_A`** / **`DISK_B`**) but before a destructive run, print the exact variable assignment (no wiping or downloads beyond disk resolution):

```bash
sudo ./gentoo_installer.sh --print-erase-token
# Example output: CONFIRM_ERASE=ERASE-nvme0n1
```

Prefix the real install command with that line or export it in your shell.

## CI

On push/PR, GitHub Actions runs **`bash -n`**, a **`--help`** smoke check, and **shellcheck** on [`gentoo_installer.sh`](gentoo_installer.sh) (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)).
