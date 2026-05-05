# Gentoo UEFI installer

[`gentoo_installer.sh`](gentoo_installer.sh) installs Gentoo with **UEFI**, **ext4** on `/`, optional **mdadm** RAID when multiple disks are listed, optional GUI (Plasma, GNOME, Xfce), and optional server packages (Apache, MariaDB, phpMyAdmin, vsftpd — off by default). Run it from a live environment as **root**.

**Host scope:** Defaults assume a **dedicated install environment** (e.g. official Gentoo LiveCD). See **`INSTALLER_LIVE_ENV`** below; set it to **`NO`** only when you understand the narrower cleanup behavior.

See the script header for **`PROFILE_TARGET`**, **`INIT_SYSTEM`**, and resume options.

## Upstream version check

After **`need_root`** (unless **`CHECK_UPSTREAM=NO`**), the script downloads the raw [`gentoo_installer.sh`](https://github.com/drkevorkian/Gentoo-Installer-2/blob/main/gentoo_installer.sh) from [**drkevorkian/Gentoo-Installer-2**](https://github.com/drkevorkian/Gentoo-Installer-2) and compares **`# INSTALLER_VERSION=`** to your copy.

- **`UPSTREAM_AUTO_UPDATE=YES`** (default): if GitHub is newer, the download is validated (**shebang**, **`bash -n`**), **`chmod +x`**, moved over **this script’s path**, and the process **`exec`**s the new file with the **same command-line arguments** (so the run continues with the updated code).
- **`UPSTREAM_AUTO_UPDATE=NO`**: only print a warning; **`UPSTREAM_STRICT=YES`** then aborts if GitHub is newer.

Override repo/ref with **`INSTALLER_GITHUB_REPO`** and **`INSTALLER_GITHUB_REF`** if you fork. The script directory must be writable for in-place replacement.

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
| `CHECK_UPSTREAM` | `YES` | Compare **`# INSTALLER_VERSION=`** to GitHub raw script before continuing |
| `UPSTREAM_AUTO_UPDATE` | `YES` | If GitHub is newer: replace this script in place, **`chmod +x`**, **`exec`** same argv |
| `UPSTREAM_STRICT` | `NO` | `YES`: exit if GitHub is newer and auto-update is off or failed |
| `INSTALLER_GITHUB_REPO` | `drkevorkian/Gentoo-Installer-2` | **`owner/repo`** for **`raw.githubusercontent.com`** |
| `INSTALLER_GITHUB_REF` | `main` | Branch or tag name on GitHub |

Further options (GUI, passwords, swap, **`GRUB_INSTALL_TO_DISK_B`**, …) are at the top of [`gentoo_installer.sh`](gentoo_installer.sh).

Bump **`# INSTALLER_VERSION=`** near the top of the script when you publish meaningful changes so the check stays meaningful.

## Download verification

When **`STAGE3_VERIFY_MD5=YES`**, the installer downloads **`${STAGE3}.DIGESTS`** and checks the tarball using **SHA512** (preferred), **SHA256**, or **MD5**, matching the sections present in the file. Gentoo often omits MD5 now; the variable name is unchanged for compatibility.

Gentoo’s **`latest-stage3-amd64-*.txt`** index files are **OpenPGP cleartext-signed**; the installer skips the armor and comment lines and reads the **`…/stage3-….tar.xz`** path line.

## Stage3 / `INIT_SYSTEM` consistency

Manual **`STAGE3`** URLs must match **`INIT_SYSTEM`** (openrc vs systemd tarball names). See script **`validate_init_stage3_consistency`**.

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

## Limitations

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

On push/PR, GitHub Actions runs **`bash -n`** and **shellcheck** on [`gentoo_installer.sh`](gentoo_installer.sh) (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)).
