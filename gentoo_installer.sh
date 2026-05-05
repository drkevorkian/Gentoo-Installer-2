#!/usr/bin/env bash
# shellcheck shell=bash
# gentoo_installer.sh
# INSTALLER_VERSION=6
#
# Gentoo UEFI installer: one disk (GPT EFI + ext4 root) or N disks with mdadm RAID 0/1/4/5/6/10 (INSTALL_DISKS).
# Set INIT_SYSTEM=systemd|openrc; stage3 flavor and profiles follow automatically
# unless STAGE3 / STAGE3_FLAVOR are overridden (see README.md).
# Supports PROFILE_TARGET:
#   server|desktop|gnome|plasma|xfce|hardened|hardened-gnome|hardened-plasma|hardened-xfce
#
# Key:
# - Whole-disk validation (lsblk TYPE=disk) for INSTALL_DISKS / DISK_A|B
# - INSTALLER_LIVE_ENV=YES (default): preflight stops all md + swapoff -a (LiveCD); NO: only $MD
# - FULL rerunnable phases via state file
# - INIT_SYSTEM=systemd|openrc selects stage3, Portage profiles (.../systemd vs .../openrc), and service startup (systemctl vs rc-update)
# - Stage3 tarball verified against mirror ${STAGE3}.DIGESTS (SHA512, else SHA256, else MD5) when STAGE3_VERIFY_MD5=YES
# - Fixes ERR-trap boolean-test crash by never running standalone [[ ... ]] in run_step()
# - Fixes dracut tmpdir leak by env -i in chroot + TMPDIR=/var/tmp
# - Forces initramfs output to /boot/initramfs-<kver>.img
# - Root password defaults to FIRST_USER_PASSWORD
# - Prints SAFE TO REBOOT readiness report
# - --print-erase-token: print CONFIRM_ERASE=ERASE-… only (no install)
# - CHECK_UPSTREAM=YES: compare # INSTALLER_VERSION= to GitHub; UPSTREAM_AUTO_UPDATE replaces self + exec
# - gentoo_installer.conf next to this script: loaded before defaults (env vars win); auto-saved before self-update
#
set -Eeuo pipefail
IFS=$'\n\t'

# One key per line — variables that may be loaded from / saved to GENTOO_INSTALLER_CONF (not INSTALLER_VERSION).
installer_conf_tracked_keys(){
  cat <<'KEYS'
ARMED
WIPE_DISKS
DISK_A
DISK_B
INSTALL_DISKS
ROOT_RAID10_LAYOUT
TARGET
MD
ROOT_RAID_LEVEL
ROOT_FS
EFI_SIZE_MIB
SWAP_SIZE_GB
RESUME
CONFIRM_ERASE
STAGE3
STAGE3_FLAVOR_AUTO
STAGE3_FLAVOR
STAGE3_AUTOBUILDS_BASE
INIT_SYSTEM
STAGE3_VERIFY_MD5
PROFILE_TARGET
GUI_ENABLE
GUI_FLAVOR
GUI_ENABLE_NETWORKMANAGER
MAKE_JOBS_DEFAULT
NODE_JOBS
ACCEPT_LICENSE
VIDEO_CARDS
INPUT_DEVICES
FIRST_USER_ENABLE
FIRST_USER_NAME
FIRST_USER_GROUPS
FIRST_USER_SHELL
SUDO_WHEEL_NOPASSWD
KERNEL_CMDLINE_OVERRIDE
AUTO_MERGE_PORTAGE_CFGS
CONFIG_PROTECT_MASK_PORTAGE
BREAK_CIRCULAR_DEPS_TIFF_WEBP
BREAK_CIRCULAR_DEPS_PILLOW_TRUETYPE
INSTALL_FIRMWARE
INSTALL_SERVER_STACK
INSTALL_NODE
GRUB_INSTALL_TO_DISK_B
GRUB_REMOVABLE
CHROOT_DEBUG
CHROOT_TMPDIR
LOG_DIR
LOG_BASENAME
LOG_ROTATE_MB
RO_CHECK_INTERVAL
INSTALLER_LIVE_ENV
INSTALLER_GITHUB_REPO
INSTALLER_GITHUB_REF
CHECK_UPSTREAM
UPSTREAM_AUTO_UPDATE
UPSTREAM_STRICT
GENTOO_INSTALLER_CONF
SAVE_INSTALLER_CONF
SAVE_INSTALLER_SECRETS
FIRST_USER_PASSWORD
ROOT_PASSWORD
KEYS
}

installer_conf_key_may_write(){
  case "$1" in
    FIRST_USER_PASSWORD|ROOT_PASSWORD)
      [[ "${SAVE_INSTALLER_SECRETS:-NO}" == "YES" ]] || return 1
      ;;
  esac
  return 0
}

# Apply $GENTOO_INSTALLER_CONF before TOP CONFIG defaults: lines are VAR=value.
# Variables already present in the process environment (e.g. VAR=value ./script) are not overridden.
installer_conf_apply_file(){
  local f="$1"
  declare -A __env_lock=() __tk=()
  local __k __line __rest
  while IFS= read -r __k; do
    [[ -z "$__k" ]] && continue
    __tk["$__k"]=1
    printenv "$__k" >/dev/null 2>&1 && __env_lock["$__k"]=1
  done < <(installer_conf_tracked_keys)

  [[ -f "$f" ]] || return 0
  echo "Loading installer settings from: $f"
  while IFS= read -r __line || [[ -n "$__line" ]]; do
    __line="${__line#"${__line%%[![:space:]]*}"}"
    [[ -z "$__line" || "$__line" == \#* ]] && continue
    if [[ "$__line" =~ ^export[[:space:]]+(.+)$ ]]; then
      __line="${BASH_REMATCH[1]}"
      __line="${__line#"${__line%%[![:space:]]*}"}"
    fi
    [[ "$__line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    __k="${BASH_REMATCH[1]}"
    __rest="${BASH_REMATCH[2]}"
    __rest="${__rest#"${__rest%%[![:space:]]*}"}"
    __rest="${__rest%"${__rest##*[![:space:]]}"}"
    [[ -n "${__tk[$__k]+x}" ]] || continue
    [[ -n "${__env_lock[$__k]+x}" ]] && continue
    # shellcheck disable=SC2086 -- trusted local file; value is the RHS of VAR=value
    eval "$__k=$__rest"
  done < "$f"
}

# Snapshot effective settings before self-update so the new process reloads the same choices.
installer_conf_save_snapshot(){
  [[ "${SAVE_INSTALLER_CONF:-YES}" == "YES" ]] || return 0
  local f="${GENTOO_INSTALLER_CONF:-}"
  [[ -n "$f" ]] || return 0
  local tmp="${f}.tmp.$$" __k
  umask 077
  {
    echo "# gentoo_installer.conf — written $(date -Is) before self-update"
    echo "# Precedence: environment variables override this file; file overrides script defaults."
    echo "# Passwords omitted unless SAVE_INSTALLER_SECRETS=YES when saving."
    while IFS= read -r __k; do
      [[ -z "$__k" ]] && continue
      installer_conf_key_may_write "$__k" || continue
      [[ -n "${!__k+x}" ]] || continue
      printf '%s=%q\n' "$__k" "${!__k}"
    done < <(installer_conf_tracked_keys)
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  echo "Saved installer settings for next run -> $f"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
: "${GENTOO_INSTALLER_CONF:=$SCRIPT_DIR/gentoo_installer.conf}"
installer_conf_apply_file "$GENTOO_INSTALLER_CONF"

# Structure (top to bottom): configs -> logging -> core helpers -> watchdog ->
#   preflight -> disk/RAID -> stage3/mount/chroot -> package lists ->
#   chroot install phases -> step_install/passwd -> readiness -> main.

# =============================================================================
# TOP CONFIGS
# =============================================================================
# Disks / paths / RAID

: "${ARMED:=YES}"
: "${WIPE_DISKS:=YES}"
: "${DISK_A:=/dev/sda}"
: "${DISK_B:=/dev/sdb}"
: "${INSTALL_DISKS:=}"               # space-separated; empty => legacy DISK_A + DISK_B (two disks)
: "${ROOT_RAID10_LAYOUT:=n2}"       # mdadm --layout for raid10 (e.g. n2 o2 f2)
: "${TARGET:=/mnt/gentoo}"
: "${MD:=/dev/md0}"
: "${ROOT_RAID_LEVEL:=raid0}"        # raid0|raid1|raid4|raid5|raid6|raid10 (multi-disk); ignored for 1 disk
: "${ROOT_FS:=ext4}"                 # ext4
: "${EFI_SIZE_MIB:=512}"
: "${SWAP_SIZE_GB:=16}"
: "${RESUME:=YES}"

: "${CONFIRM_ERASE:=}"               # set to output of confirm_erase_expected() after disks are resolved

# Stage3 / init

: "${STAGE3:=}"
: "${STAGE3_FLAVOR_AUTO:=YES}"
: "${STAGE3_FLAVOR:=hardened-openrc}"        # systemd|openrc|hardened-systemd|hardened-openrc (auto overrides when STAGE3_FLAVOR_AUTO=YES)
: "${STAGE3_AUTOBUILDS_BASE:=https://distfiles.gentoo.org/releases/amd64/autobuilds}"
: "${INIT_SYSTEM:=openrc}"           # systemd|openrc — must match stage3 tarball / profile init
: "${STAGE3_VERIFY_MD5:=YES}"       # YES: verify tarball vs mirror ${URL}.DIGESTS (prefers SHA512; MD5 name kept for compat)

# Profile / GUI

: "${PROFILE_TARGET:=hardened-plasma}"

: "${GUI_ENABLE:=YES}"               # YES/NO
: "${GUI_FLAVOR:=plasma}"            # plasma|gnome|xfce
: "${GUI_ENABLE_NETWORKMANAGER:=YES}"

: "${MAKE_JOBS_DEFAULT:=8}"
: "${NODE_JOBS:=2}"
: "${ACCEPT_LICENSE:=*}"
: "${VIDEO_CARDS:=intel nvidia amdgpu nouveau}"
: "${INPUT_DEVICES:=libinput}"

: "${FIRST_USER_ENABLE:=YES}"
: "${FIRST_USER_NAME:=owner}"
: "${FIRST_USER_PASSWORD:=}"         # empty => interactive
: "${ROOT_PASSWORD:=${FIRST_USER_PASSWORD}}"
: "${PASSWD_ALWAYS_SET:=YES}"
: "${FIRST_USER_GROUPS:=wheel,audio,video,usb,plugdev,portage}"
: "${FIRST_USER_SHELL:=/bin/bash}"
: "${SUDO_WHEEL_NOPASSWD:=NO}"

: "${KERNEL_CMDLINE_OVERRIDE:=}"

: "${AUTO_MERGE_PORTAGE_CFGS:=YES}"
: "${CONFIG_PROTECT_MASK_PORTAGE:=YES}"
: "${BREAK_CIRCULAR_DEPS_TIFF_WEBP:=YES}"
: "${BREAK_CIRCULAR_DEPS_PILLOW_TRUETYPE:=YES}"
: "${INSTALL_FIRMWARE:=YES}"
: "${INSTALL_SERVER_STACK:=NO}"
: "${INSTALL_NODE:=NO}"

: "${GRUB_INSTALL_TO_DISK_B:=YES}"
: "${GRUB_REMOVABLE:=NO}"

# Chroot / logging tunables

: "${CHROOT_DEBUG:=NO}"
: "${CHROOT_TMPDIR:=/var/tmp}"

: "${LOG_DIR:=}"
: "${LOG_BASENAME:=gentoo_install}"
: "${LOG_ROTATE_MB:=25}"
: "${RO_CHECK_INTERVAL:=15}"

# YES: aggressive cleanup (swapoff -a, stop all /dev/md*) — intended for Gentoo LiveCD / dedicated install VM only.
: "${INSTALLER_LIVE_ENV:=YES}"

# Upstream copy on GitHub (raw gentoo_installer.sh must carry the same # INSTALLER_VERSION= line).
: "${INSTALLER_GITHUB_REPO:=drkevorkian/Gentoo-Installer-2}"
: "${INSTALLER_GITHUB_REF:=main}"
: "${CHECK_UPSTREAM:=YES}"
: "${UPSTREAM_AUTO_UPDATE:=YES}"   # YES: replace this script with GitHub copy and exec it (same argv)
: "${UPSTREAM_STRICT:=NO}"
: "${SAVE_INSTALLER_CONF:=YES}"       # write gentoo_installer.conf before self-update
: "${SAVE_INSTALLER_SECRETS:=NO}"     # YES: include passwords in that file (avoid unless you accept the risk)

# So self-update `exec` and any child inherit effective settings (not only env-prefixed invocations).
installer_conf_export_tracked(){
  local __k
  while IFS= read -r __k; do
    [[ -z "$__k" ]] && continue
    [[ -n "${!__k+x}" ]] || continue
    export -- "$__k" 2>/dev/null || export "$__k"
  done < <(installer_conf_tracked_keys)
}
installer_conf_export_tracked

# =============================================================================
# Logging, paths, and session state
# =============================================================================

auto_pick_log_dir() {
  local -a candidates=("$SCRIPT_DIR" "$SCRIPT_DIR/logs" "$SCRIPT_DIR/../logs" "/tmp")
  local d
  for d in "${candidates[@]}"; do
    d="$(cd "$d" 2>/dev/null && pwd -P)" || continue
    mkdir -p "$d" 2>/dev/null || continue
    [[ -w "$d" ]] || continue
    echo "$d"
    return 0
  done
  echo "/tmp"
}

if [[ -z "${LOG_DIR}" ]]; then
  LOG_DIR="$(auto_pick_log_dir)"
fi
mkdir -p "$LOG_DIR" 2>/dev/null || true

LOG="${LOG_DIR}/${LOG_BASENAME}.log"
STATE="${LOG_DIR}/${LOG_BASENAME}.state"
STAGE3_CACHE_DIR="${LOG_DIR}/stage3-cache"
mkdir -p "$STAGE3_CACHE_DIR" 2>/dev/null || true

HOST_TMPDIR="$LOG_DIR"
export TMPDIR="/tmp"

rotate_log_if_needed() {
  local f="$1" max_mb="$2"
  [[ -f "$f" ]] || return 0
  local sz=0
  sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  if (( sz > max_mb * 1024 * 1024 )); then
    local ts; ts="$(date +%Y%m%d%H%M%S)"
    mv -f "$f" "${f}.${ts}" 2>/dev/null || true
    command -v gzip >/dev/null 2>&1 && gzip -9 "${f}.${ts}" >/dev/null 2>&1 || true
  fi
}
rotate_log_if_needed "$LOG" "$LOG_ROTATE_MB"

touch "$LOG" "$STATE" 2>/dev/null || true
chmod 600 "$LOG" "$STATE" 2>/dev/null || true
exec > >(tee -a "$LOG" 2>/dev/null || cat) 2>&1

die(){ echo "FATAL: $*" >&2; exit 1; }

on_err(){
  local ec=$?
  local line=${BASH_LINENO[0]:-?}
  local cmd=${BASH_COMMAND:-?}
  echo
  echo "==================== INSTALLER CRASH ===================="
  echo "Exit code : $ec"
  echo "Line      : $line"
  echo "Command   : $cmd"
  echo "Log       : $LOG"
  echo "State     : $STATE"
  echo "========================================================="
  if [[ "$cmd" == *'chroot '* ]]; then
    echo "Hint: chroot exit is usually the inner bash script failing. Search the log for the last CHROOT> line, then retry with CHROOT_DEBUG=YES." >&2
  fi
  echo
  exit "$ec"
}
trap on_err ERR

phase(){ echo; echo "===== PHASE: $* ====="; }

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
disk_base(){ basename "$1"; }

# GitHub raw script carries `# INSTALLER_VERSION=N`; bump N when releasing meaningful changes.
installer_version_from_file(){
  local f="$1"
  grep -m1 '^# INSTALLER_VERSION=' "$f" 2>/dev/null \
    | sed -e 's/^# INSTALLER_VERSION=//' -e 's/[[:space:]]*$//' | tr -d '\r'
}

# Absolute path to this script file (the path we replace when self-updating).
installer_self_abspath(){
  local s="${BASH_SOURCE[0]}"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$s" && return 0
  fi
  if readlink -f "$s" >/dev/null 2>&1; then
    readlink -f "$s" && return 0
  fi
  local dir
  dir="$(cd "$(dirname "$s")" && pwd -P)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$s")"
}

# Validate tmp, chmod +x, mv over running script path, exec with same argv. Does not return on success.
installer_self_update_from_tmp(){
  local tmp="$1" expect_ver="$2" ref_name="$3"
  local -n argv_ref="$ref_name"
  local target got
  got="$(installer_version_from_file "$tmp")"
  [[ "$got" == "$expect_ver" ]] || {
    echo "FATAL: Downloaded script version mismatch (expected ${expect_ver}, got ${got})." >&2
    return 1
  }
  head -n1 "$tmp" | grep -qE '^#!/usr/bin/(env )?bash' || {
    echo "FATAL: Downloaded file is not a bash script (bad shebang)." >&2
    return 1
  }
  bash -n "$tmp" 2>/dev/null || {
    echo "FATAL: bash -n failed on downloaded script; refusing to install." >&2
    return 1
  }
  target="$(installer_self_abspath)" || {
    echo "FATAL: Could not resolve absolute path to this installer." >&2
    return 1
  }
  local tdir
  tdir="$(dirname "$target")"
  [[ -w "$tdir" ]] || {
    echo "FATAL: Cannot write to ${tdir}; copy the script there manually or run from a writable directory." >&2
    return 1
  }
  installer_conf_save_snapshot || echo "NOTE: Could not save installer conf snapshot (continuing self-update)." >&2
  chmod a+x "$tmp" || return 1
  if ! mv -f "$tmp" "$target"; then
    echo "FATAL: Could not replace ${target} with new script." >&2
    [[ -e "$tmp" ]] && rm -f "$tmp"
    return 1
  fi
  echo "" >&2
  echo "===== Self-update: installed GitHub version ${expect_ver} -> ${target}; restarting installer =====" >&2
  echo "" >&2
  exec bash "$target" "${argv_ref[@]}"
}

# argv_ref_name: name of caller's array variable holding original "$@" (before option parsing).
check_installer_upstream(){
  [[ "${CHECK_UPSTREAM:-YES}" == "YES" ]] || return 0
  local argv_ref_name="${1:?check_installer_upstream: missing argv array name}"

  local self url tmp v_loc v_rem strict rc=1 target_dir
  strict="${UPSTREAM_STRICT:-NO}"
  self="${BASH_SOURCE[0]}"
  v_loc="$(installer_version_from_file "$self")"
  if [[ -z "$v_loc" ]]; then
    echo "NOTE: Missing # INSTALLER_VERSION= in this script; skipping GitHub version check." >&2
    return 0
  fi
  if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    echo "NOTE: Neither wget nor curl found; skipping GitHub version check." >&2
    return 0
  fi
  url="https://raw.githubusercontent.com/${INSTALLER_GITHUB_REPO}/${INSTALLER_GITHUB_REF}/gentoo_installer.sh"
  tmp=""
  if target_dir="$(dirname "$(installer_self_abspath 2>/dev/null || echo "$self")")" && [[ -w "$target_dir" ]]; then
    tmp="$(mktemp -p "$target_dir" ".gentoo_installer_new.XXXXXX")" || tmp=""
  fi
  if [[ -z "$tmp" ]]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/gentoo_installer_new.XXXXXX")" || {
      echo "NOTE: mktemp failed; skipping GitHub version check." >&2
      return 0
    }
  fi
  if wget -q --timeout=20 -O "$tmp" "$url" 2>/dev/null; then rc=0
  elif curl -fsS --connect-timeout 15 --max-time 60 -o "$tmp" "$url" 2>/dev/null; then rc=0
  fi
  if [[ "$rc" -ne 0 ]] || [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "NOTE: Could not download upstream script from GitHub; skipping version check." >&2
    echo "      (${url})" >&2
    return 0
  fi
  v_rem="$(installer_version_from_file "$tmp")"
  if [[ -z "$v_rem" ]]; then
    rm -f "$tmp"
    echo "NOTE: Upstream script has no # INSTALLER_VERSION=; skipping comparison." >&2
    return 0
  fi
  if [[ "$v_rem" == "$v_loc" ]]; then
    echo "Installer script version ${v_loc} matches GitHub (${INSTALLER_GITHUB_REPO}@${INSTALLER_GITHUB_REF})."
    rm -f "$tmp"
    return 0
  fi
  local newer outdated=0
  newer="$(printf '%s\n' "$v_loc" "$v_rem" | sort -V | tail -n1)"
  if [[ "$newer" == "$v_rem" && "$v_rem" != "$v_loc" ]]; then outdated=1; fi
  if [[ "$outdated" -eq 0 ]]; then
    rm -f "$tmp"
    return 0
  fi

  if [[ "${UPSTREAM_AUTO_UPDATE:-YES}" == "YES" ]]; then
    installer_self_update_from_tmp "$tmp" "$v_rem" "$argv_ref_name"
    rm -f "$tmp" 2>/dev/null || true
    echo "NOTE: Self-update failed (GitHub v${v_rem} > local v${v_loc}). See errors above; continuing with this copy." >&2
  else
    rm -f "$tmp"
    local gh_page="https://github.com/${INSTALLER_GITHUB_REPO}/blob/${INSTALLER_GITHUB_REF}/gentoo_installer.sh"
    echo "" >&2
    echo "================================================================" >&2
    echo "  UPDATE: GitHub has a newer installer (upstream version ${v_rem}; this copy is ${v_loc})." >&2
    echo "  Page:  ${gh_page}" >&2
    echo "  Raw:   ${url}" >&2
    echo "================================================================" >&2
    echo "" >&2
  fi
  if [[ "$strict" == "YES" ]]; then
    die "Refusing to run outdated installer (UPSTREAM_STRICT=YES). Fix self-update, refresh manually, or set CHECK_UPSTREAM=NO."
  fi
  if [[ "${UPSTREAM_AUTO_UPDATE:-YES}" == "YES" ]]; then
    echo "  Set CHECK_UPSTREAM=NO to skip the upstream check entirely." >&2
  else
    echo "  Set UPSTREAM_AUTO_UPDATE=YES to auto-replace from GitHub, or CHECK_UPSTREAM=NO to skip." >&2
  fi
  echo "" >&2
}

# Walk from any block device (partition, mapper, md, …) up to underlying TYPE=disk nodes.
# Prints unique whole-disk paths (for comparisons). Handles md RAID via /sys/.../slaves when lsblk PKNAME is empty.
backing_physical_disks(){
  local top="$1"
  [[ -e "$top" ]] || return 1
  declare -A seen=()
  local _walk
  _walk(){
    local src="$1"
    src="$(readlink -f "$src")"
    [[ -e "$src" ]] || return 0
    [[ -z "${seen[$src]:-}" ]] || return 0
    seen[$src]=1
    local ty pk b sl
    ty="$(lsblk -ndo TYPE "$src" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    if [[ "$ty" == "disk" ]]; then
      printf '%s\n' "$src"
      return 0
    fi
    pk="$(lsblk -ndo PKNAME "$src" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    if [[ -n "$pk" ]]; then
      _walk "/dev/$pk"
      return 0
    fi
    b="${src##*/}"
    shopt -s nullglob
    for sl in /sys/block/"$b"/slaves/*; do
      [[ -e "$sl" ]] || continue
      _walk "/dev/$(basename "$sl")"
    done
    shopt -u nullglob
  }
  _walk "$top"
}

# Reject partitions/mappers: layout code expects lsblk TYPE=disk whole devices.
install_disk_assert_whole_disk(){
  local dev="$1" ty
  dev="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"
  ty="$(lsblk -ndo TYPE "$dev" 2>/dev/null | head -n1 | tr -d '[:space:]')"
  case "$ty" in
    disk) return 0 ;;
    "")
      die "Cannot determine block type for: $1 (not found or lsblk failed). Use whole-disk paths."
      ;;
    *)
      die "Not a whole disk (lsblk TYPE=$ty): $1 — use e.g. /dev/sda or /dev/nvme0n1, not a partition or LV."
      ;;
  esac
}

# Whole-disk device -> partition path (sda1 vs nvme0n1p1).
disk_part(){
  local d="$1" num="$2"
  if [[ "$d" == *nvme* || "$d" == *mmcblk* || "$d" == /dev/loop* ]]; then
    printf '%s\n' "${d}p${num}"
    return
  fi
  printf '%s\n' "${d}${num}"
}

# Resolved install targets (populated by install_disks_resolve).
declare -a INSTALL_DISK_ARR=()
INSTALL_ROOT_IS_RAID=0

install_disks_resolve(){
  INSTALL_DISK_ARR=()
  local tok
  if [[ -n "${INSTALL_DISKS// }" ]]; then
    for tok in $INSTALL_DISKS; do
      [[ -n "$tok" ]] || continue
      INSTALL_DISK_ARR+=("$tok")
    done
  else
    # Legacy DISK_A + DISK_B: use each path that is actually a whole-disk node.
    # Many machines have no /dev/sdb (single disk, NVMe-only, etc.); requiring
    # both used to fail with "Not a block device: /dev/sdb".
    local -a legacy=()
    [[ -n "${DISK_A:-}" && -b "$DISK_A" ]] && legacy+=("$DISK_A")
    if [[ -n "${DISK_B:-}" && -b "$DISK_B" && "$DISK_B" != "$DISK_A" ]]; then
      legacy+=("$DISK_B")
    fi
    if (( ${#legacy[@]} == 0 )); then
      echo "No usable DISK_A/DISK_B block devices (DISK_A=${DISK_A:-} DISK_B=${DISK_B:-})." >&2
      echo "Whole-disk devices on this host (from lsblk):" >&2
      lsblk -dpno NAME,SIZE,TYPE,MODEL 2>/dev/null | sed 's/^/  /' >&2 || true
      die "Set INSTALL_DISKS to your target disk(s), e.g. INSTALL_DISKS=/dev/nvme0n1"
    fi
    INSTALL_DISK_ARR=("${legacy[@]}")
    if (( ${#INSTALL_DISK_ARR[@]} == 1 )); then
      echo "NOTE: INSTALL_DISKS unset; only one of DISK_A/DISK_B exists — using single disk ${INSTALL_DISK_ARR[0]}." >&2
      echo "      For explicit multi-disk RAID, set INSTALL_DISKS=\"/dev/sdX /dev/sdY ...\"." >&2
    fi
  fi
  local i j n="${#INSTALL_DISK_ARR[@]}"
  (( n >= 1 )) || die "No disks in INSTALL_DISKS / DISK_A"
  for (( i = 0; i < n; i++ )); do
    [[ -b "${INSTALL_DISK_ARR[i]}" ]] || die "Not a block device: ${INSTALL_DISK_ARR[i]}"
  done
  for (( i = 0; i < n; i++ )); do
    for (( j = i + 1; j < n; j++ )); do
      [[ "${INSTALL_DISK_ARR[i]}" != "${INSTALL_DISK_ARR[j]}" ]] || die "Duplicate disk in list: ${INSTALL_DISK_ARR[i]}"
    done
  done
  for (( i = 0; i < n; i++ )); do
    install_disk_assert_whole_disk "${INSTALL_DISK_ARR[i]}"
  done
  if (( n >= 2 )); then
    INSTALL_ROOT_IS_RAID=1
  else
    INSTALL_ROOT_IS_RAID=0
  fi
}

confirm_erase_expected(){
  local -a bases=()
  local x sorted_line
  for x in "${INSTALL_DISK_ARR[@]}"; do
    bases+=("$(disk_base "$x")")
  done
  sorted_line="$(printf '%s\n' "${bases[@]}" | LC_ALL=C sort | paste -sd-)"
  printf '%s\n' "ERASE-${sorted_line}"
}

validate_install_disk_policy(){
  local n="${#INSTALL_DISK_ARR[@]}"
  if (( n == 1 )); then
    case "${ROOT_RAID_LEVEL:-}" in
      raid0|raid1|raid4|raid5|raid6|raid10)
        echo "NOTE: Single disk — ignoring ROOT_RAID_LEVEL=${ROOT_RAID_LEVEL} (root on partition, no md RAID)." >&2
        ;;
    esac
    return 0
  fi
  case "${ROOT_RAID_LEVEL:-raid0}" in
    raid0|raid1)
      (( n >= 2 )) || die "raid0/raid1 requires at least 2 disks (have $n)"
      ;;
    raid4|raid5)
      (( n >= 3 )) || die "raid4/raid5 requires at least 3 disks (have $n)"
      ;;
    raid6)
      (( n >= 4 )) || die "raid6 requires at least 4 disks (have $n)"
      ;;
    raid10)
      (( n >= 4 )) || die "raid10 requires at least 4 disks (have $n)"
      (( n % 2 == 0 )) || die "raid10 with ROOT_RAID10_LAYOUT=${ROOT_RAID10_LAYOUT:-n2} expects an even disk count (have $n)"
      ;;
    *) die "ROOT_RAID_LEVEL must be raid0|raid1|raid4|raid5|raid6|raid10 (got ${ROOT_RAID_LEVEL:-})" ;;
  esac
}

assert_valid_init_system(){
  case "${INIT_SYSTEM:-systemd}" in
    systemd|openrc) ;;
    *) die "INIT_SYSTEM must be systemd or openrc (got ${INIT_SYSTEM:-})" ;;
  esac
}

init_state(){ touch "$STATE" 2>/dev/null || true; chmod 600 "$STATE" 2>/dev/null || true; }

step_done(){
  [[ "${RESUME:-NO}" == "YES" ]] || return 1
  grep -qE "^DONE[[:space:]]+$1([[:space:]]|$)" "$STATE" 2>/dev/null
}

mark_done(){ printf "DONE %s %s\n" "$1" "$(date -Is)" >> "$STATE" 2>/dev/null || true; }

# IMPORTANT: Never do standalone [[ ... ]] here (it can trip ERR trap).
run_step(){
  local s="${1:?missing step name}"
  shift || true

  local always=0
  if [[ "$s" == "passwd" && "${PASSWD_ALWAYS_SET:-NO}" == "YES" && -n "${ROOT_PASSWORD:-}" ]]; then
    always=1
  fi

  if [[ "$always" == "0" ]]; then
    if step_done "$s"; then
      echo "==> SKIP: $s"
      return 0
    fi
  fi

  echo "==> RUN : $s"
  "$@"
  echo "==> OK  : $s"

  if [[ "$always" == "0" ]]; then
    mark_done "$s"
  fi
}

truncate_state_from_phase(){
  local target="${1:?missing phase}"
  [[ -f "$STATE" ]] || return 0

  local tmp found=0
  tmp="$(mktemp -p "$HOST_TMPDIR" "${LOG_BASENAME}.state.XXXXXX")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" =~ ^DONE[[:space:]]+$target([[:space:]]|$) ]]; then found=1; break; fi
    printf '%s\n' "$line" >> "$tmp" 2>/dev/null || break
  done < "$STATE"

  if [[ "$found" -eq 1 ]]; then
    cp -a "$tmp" "$STATE" 2>/dev/null || true
    echo "STATE TRUNCATED: removed $target and later entries"
  fi
  rm -f "$tmp" 2>/dev/null || true
}

# =============================================================================
# Watchdog
# =============================================================================

RO_WATCHDOG_PID=""
ro_watchdog(){
  while true; do
    sleep "$RO_CHECK_INTERVAL" || true
    if mountpoint -q "$TARGET"; then
      local opts; opts="$(findmnt -n -o OPTIONS "$TARGET" 2>/dev/null || true)"
      if echo "$opts" | grep -qE '(^|,)ro(,|$)'; then
        echo; echo "!!! READ-ONLY MOUNT on $TARGET !!!"
        findmnt "$TARGET" || true
        dmesg -T | tail -n 200 || true
        exit 88
      fi
    fi
  done
}
start_watchdog(){ phase "watchdog:start"; ro_watchdog & RO_WATCHDOG_PID=$!; echo "Watchdog PID: $RO_WATCHDOG_PID"; }
stop_watchdog(){ phase "watchdog:stop"; kill "$RO_WATCHDOG_PID" 2>/dev/null || true; wait "$RO_WATCHDOG_PID" 2>/dev/null || true; }

# =============================================================================
# Preflight (network, stage3 URL, validation banner, confirmations)
# =============================================================================

check_internet(){
  phase "preflight:internet"
  wget -q --spider --timeout=10 https://www.gentoo.org 2>/dev/null \
    || curl -sSf --connect-timeout 10 -o /dev/null https://www.gentoo.org 2>/dev/null \
    || die "No internet connection detected."
  echo "Internet connectivity OK"
}

resolve_stage3(){
  [[ -n "${STAGE3:-}" ]] && return 0

  phase "preflight:stage3_resolve"

  assert_valid_init_system

  if [[ "${STAGE3_FLAVOR_AUTO:-NO}" == "YES" ]]; then
    if [[ "${PROFILE_TARGET:-}" == hardened* ]]; then
      STAGE3_FLAVOR="hardened-${INIT_SYSTEM}"
    else
      STAGE3_FLAVOR="${INIT_SYSTEM}"
    fi
  fi

  local idx_url="${STAGE3_AUTOBUILDS_BASE}/latest-stage3-amd64-${STAGE3_FLAVOR}.txt"
  local tmp="${STAGE3_CACHE_DIR}/latest-stage3-amd64-${STAGE3_FLAVOR}.txt"

  wget -qO "$tmp" "$idx_url" || die "Failed fetching: $idx_url"
  # Index files are OpenPGP cleartext-signed: first non-metadata line may be
  # "-----BEGIN PGP SIGNED MESSAGE-----", not the tarball path. Take the first
  # field that looks like .../stage3-....tar.xz (relative path under autobuilds/).
  local rel
  rel="$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^-----/ { next }
    /^Hash:/ { next }
    $1 ~ /\.tar\.xz$/ { gsub(/\r$/, "", $1); print $1; exit }
  ' "$tmp")"
  [[ -n "$rel" ]] || die "Could not parse stage3 path from $idx_url (see $tmp)"
  STAGE3="${STAGE3_AUTOBUILDS_BASE}/${rel}"

  echo "INIT_SYSTEM   : ${INIT_SYSTEM}"
  echo "Stage3 flavor : $STAGE3_FLAVOR"
  echo "Latest stage3 : $STAGE3"
  echo "Log  : $LOG"
  echo "State: $STATE"
  echo "Install disks : ${INSTALL_DISK_ARR[*]:-${DISK_A} ${DISK_B}}"
  echo "RAID root      : ${INSTALL_ROOT_IS_RAID:-?}  MD: $MD  Target: $TARGET  ROOT_RAID_LEVEL: $ROOT_RAID_LEVEL"
  echo "PROFILE_TARGET: $PROFILE_TARGET"
  echo "GUI_ENABLE: $GUI_ENABLE  GUI_FLAVOR: $GUI_FLAVOR"
  echo "RESUME: $RESUME"
}

validate_init_stage3_consistency(){
  assert_valid_init_system
  local base
  base="$(basename "${STAGE3:-}")"
  if [[ "$base" == *"-openrc-"* ]] || [[ "$base" == *"-hardened-openrc-"* ]]; then
    [[ "$INIT_SYSTEM" == openrc ]] || die "Stage3 tarball is OpenRC ($base) but INIT_SYSTEM=$INIT_SYSTEM"
  elif [[ "$base" == *"-systemd-"* ]] || [[ "$base" == *"-hardened-systemd-"* ]]; then
    [[ "$INIT_SYSTEM" == systemd ]] || die "Stage3 tarball is systemd ($base) but INIT_SYSTEM=$INIT_SYSTEM"
  fi
  if [[ "${STAGE3_FLAVOR_AUTO:-YES}" != YES ]]; then
    if [[ "${STAGE3_FLAVOR:-}" == *openrc* ]] && [[ "$INIT_SYSTEM" != openrc ]]; then
      die "STAGE3_FLAVOR=${STAGE3_FLAVOR:-} implies OpenRC but INIT_SYSTEM=$INIT_SYSTEM"
    fi
    if [[ "${STAGE3_FLAVOR:-}" == *systemd* ]] && [[ "$INIT_SYSTEM" != systemd ]]; then
      die "STAGE3_FLAVOR=${STAGE3_FLAVOR:-} implies systemd but INIT_SYSTEM=$INIT_SYSTEM"
    fi
  fi
}

announce_install_profile(){
  echo ""
  echo "======== INSTALL PROFILE (verify before proceeding) ========"
  echo "INIT_SYSTEM     : ${INIT_SYSTEM:-systemd}   # drives stage3, profiles, systemctl vs rc-update"
  echo "PROFILE_TARGET  : ${PROFILE_TARGET:-}"
  echo "STAGE3_FLAVOR   : ${STAGE3_FLAVOR:-}"
  echo "STAGE3 URL      : ${STAGE3:-}"
  echo "INSTALL_DISKS   : ${INSTALL_DISKS:-}" "(resolved: ${INSTALL_DISK_ARR[*]:-unset})"
  echo "==========================================================="
  echo ""
}

refuse_dangerous_disks(){
  local root_src d idl rdl
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -n "$root_src" ]] || die "Cannot determine current root device"

  declare -A root_disks=()
  while IFS= read -r rdl; do
    [[ -n "$rdl" ]] || continue
    root_disks["$rdl"]=1
  done < <(backing_physical_disks "$root_src" 2>/dev/null | sort -u)

  if ((${#root_disks[@]} == 0)); then
    echo "NOTE: Root filesystem source '$root_src' is not mapped to block disks (e.g. tmpfs/NFS/live overlay); skipping root-vs-install-disk overlap check." >&2
    return 0
  fi

  for d in "${INSTALL_DISK_ARR[@]}"; do
    while IFS= read -r idl; do
      [[ -n "$idl" ]] || continue
      [[ -z "${root_disks[$idl]:-}" ]] || die "Refusing: install disk $d (physical $idl) backs or overlaps current /"
    done < <(backing_physical_disks "$d" | sort -u)
  done
}

confirm_destroy(){
  local d
  echo
  echo "Installed system init: ${INIT_SYSTEM:-systemd} (stage3 + Portage profile + service commands match this)"
  echo "THIS WILL DESTROY ALL DATA ON:"
  for d in "${INSTALL_DISK_ARR[@]}"; do
    echo "  $d  ($(lsblk -dn -o MODEL,SERIAL,SIZE "$d" 2>/dev/null || true))"
  done
  echo
  echo "Type: I_UNDERSTAND"
  read -r ans
  [[ "$ans" == "I_UNDERSTAND" ]] || die "Not confirmed"
}

require_inputs(){
  [[ "${ARMED:-NO}" == "YES" ]] || die "Set ARMED=YES"
  [[ "${WIPE_DISKS:-NO}" == "YES" ]] || die "Set WIPE_DISKS=YES"
  [[ -n "${STAGE3:-}" ]] || die "STAGE3 is empty"
  validate_init_stage3_consistency
  validate_install_disk_policy
  local expect
  expect="$(confirm_erase_expected)"
  [[ "${CONFIRM_ERASE:-}" == "$expect" ]] || die "Set CONFIRM_ERASE=$expect"
}

# =============================================================================
# Disk layout, RAID, root filesystem
# =============================================================================

preflight_cleanup(){
  phase "preflight_cleanup"
  umount -R "$TARGET" 2>/dev/null || true
  if [[ "${INSTALLER_LIVE_ENV:-YES}" == "YES" ]]; then
    swapoff -a 2>/dev/null || true
    local md
    for md in /dev/md*; do
      [[ -b "$md" ]] || continue
      mdadm --stop "$md" 2>/dev/null || true
      mdadm --remove "$md" 2>/dev/null || true
    done
  else
    if [[ -b "${MD:-}" ]]; then
      mdadm --stop "$MD" 2>/dev/null || true
      mdadm --remove "$MD" 2>/dev/null || true
    fi
  fi
  udevadm settle 2>/dev/null || true
}

step_time(){ phase "time"; echo "Time now: $(date -Is)"; }

step_wipe(){
  phase "wipe"
  refuse_dangerous_disks
  confirm_destroy
  preflight_cleanup
  local d
  for d in "${INSTALL_DISK_ARR[@]}"; do
    sgdisk --zap-all "$d" || true
    sgdisk -o "$d" || true
    wipefs -a "$d" || true
    partprobe "$d" 2>/dev/null || true
  done
  udevadm settle || true
}

step_partition(){
  phase "partition"
  local efi_end="+${EFI_SIZE_MIB}MiB"
  local n="${#INSTALL_DISK_ARR[@]}"
  local d
  if (( n == 1 )); then
    d="${INSTALL_DISK_ARR[0]}"
    sgdisk -Z "$d" || true
    sgdisk -o "$d"
    sgdisk -n "1:0:${efi_end}" -t "1:EF00" -c "1:EFI" "$d"
    sgdisk -n "2:0:0" -t "2:8300" -c "2:ROOT" "$d"
    partprobe "$d" 2>/dev/null || true
  else
    for d in "${INSTALL_DISK_ARR[@]}"; do
      sgdisk -Z "$d" || true
      sgdisk -o "$d"
      sgdisk -n "1:0:${efi_end}" -t "1:EF00" -c "1:EFI" "$d"
      sgdisk -n "2:0:0" -t "2:FD00" -c "2:RAIDROOT" "$d"
    done
    partprobe "${INSTALL_DISK_ARR[@]}" 2>/dev/null || true
  fi
  udevadm settle || true
}

min_member_kib(){
  local minb="" sz d p2
  for d in "${INSTALL_DISK_ARR[@]}"; do
    p2="$(disk_part "$d" 2)"
    sz="$(blockdev --getsize64 "$p2")"
    [[ -n "$sz" ]] || die "blockdev size failed for $p2"
    if [[ -z "$minb" ]] || (( sz < minb )); then minb="$sz"; fi
  done
  echo $(( minb / 1024 ))
}

wipe_member_signatures(){
  mdadm --stop "$MD" 2>/dev/null || true
  mdadm --remove "$MD" 2>/dev/null || true
  local d p2
  for d in "${INSTALL_DISK_ARR[@]}"; do
    p2="$(disk_part "$d" 2)"
    mdadm --zero-superblock --force "$p2" 2>/dev/null || true
    wipefs -a "$p2" 2>/dev/null || true
  done
  udevadm settle 2>/dev/null || true
}

mdadm_supports(){ mdadm --help 2>/dev/null | grep -qE "$1"; }

mdadm_create_attempt(){
  local level="$1" raid_devs="$2" bitmap_arg="$3" size_kib="$4"
  shift 4
  local -a members=("$@")
  local -a mdargs=( --create "$MD" --metadata=1.2 --level="$level" --raid-devices="$raid_devs" )
  [[ "$level" == 10 ]] && mdargs+=( --layout="${ROOT_RAID10_LAYOUT:-n2}" )
  mdargs+=( --size="$size_kib" )
  [[ -n "$bitmap_arg" ]] && mdargs+=( "$bitmap_arg" )
  mdargs+=( --force )

  if mdadm_supports '(^|[[:space:]])--yes($|[[:space:]])'; then
    mdadm "${mdargs[@]}" --yes "${members[@]}"
    return $?
  fi
  if mdadm_supports '(^|[[:space:]])-y($|[[:space:]])'; then
    mdadm "${mdargs[@]}" -y "${members[@]}"
    return $?
  fi

  local rc
  set +o pipefail
  yes | mdadm "${mdargs[@]}" "${members[@]}"
  rc=$?
  set -o pipefail

  if [[ "$rc" -eq 0 || "$rc" -eq 141 ]]; then
    [[ -b "$MD" ]] && return 0
  fi
  return "$rc"
}

mdadm_create_with_retry(){
  local level="$1" raid_devs="$2" bitmap_arg="$3"
  local -a members=()
  local d
  for d in "${INSTALL_DISK_ARR[@]}"; do
    members+=("$(disk_part "$d" 2)")
  done
  local base_kib; base_kib="$(min_member_kib)"
  local margins=(0 262144 524288 1048576 2097152 4194304 8388608)

  for m in "${margins[@]}"; do
    local size_kib=$(( base_kib - m ))
    [[ "$size_kib" -gt 1024 ]] || continue
    wipe_member_signatures
    if mdadm_create_attempt "$level" "$raid_devs" "$bitmap_arg" "$size_kib" "${members[@]}"; then
      mdadm --detail "$MD" >/dev/null 2>&1 || die "mdadm created but cannot detail $MD"
      echo "mdadm: create succeeded with size_kib=$size_kib"
      return 0
    fi
    echo "mdadm: create failed with size_kib=$size_kib (trying smaller)"
    mdadm --stop "$MD" 2>/dev/null || true
  done
  die "mdadm create failed after retries"
}

step_mkfsraid(){
  phase "mkfsraid"
  preflight_cleanup

  local n="${#INSTALL_DISK_ARR[@]}"
  local d

  if (( n == 1 )); then
    local p1 p2
    d="${INSTALL_DISK_ARR[0]}"
    p1="$(disk_part "$d" 1)"
    p2="$(disk_part "$d" 2)"
    mkfs.vfat -F32 "$p1"
    case "$ROOT_FS" in
      ext4) mkfs.ext4 -F "$p2" ;;
      *) die "ROOT_FS unsupported: $ROOT_FS" ;;
    esac
    export ROOT_BLK="$p2"
    return 0
  fi

  for d in "${INSTALL_DISK_ARR[@]}"; do
    mkfs.vfat -F32 "$(disk_part "$d" 1)"
  done

  local level raid_devs bitmap_arg=""
  raid_devs="$n"
  case "${ROOT_RAID_LEVEL:-raid0}" in
    raid0)  level=0 ;;
    raid1)  level=1; bitmap_arg="--bitmap=internal" ;;
    raid4)  level=4 ;;
    raid5)  level=5 ;;
    raid6)  level=6 ;;
    raid10) level=10 ;;
    *) die "ROOT_RAID_LEVEL must be raid0|raid1|raid4|raid5|raid6|raid10" ;;
  esac

  mdadm_create_with_retry "$level" "$raid_devs" "$bitmap_arg"

  case "$ROOT_FS" in
    ext4) mkfs.ext4 -F "$MD" ;;
    *) die "ROOT_FS unsupported: $ROOT_FS" ;;
  esac
  export ROOT_BLK=""
}

# =============================================================================
# Stage3 tarball / mounts / chroot environment
# =============================================================================

ensure_md_present(){
  [[ -b "$MD" ]] && return 0
  mdadm --assemble --scan || true
  [[ -b "$MD" ]] || die "RAID device missing: $MD"
}

ensure_root_volume_present(){
  if [[ "${INSTALL_ROOT_IS_RAID:-0}" -eq 0 ]]; then
    local rp
    rp="$(disk_part "${INSTALL_DISK_ARR[0]}" 2)"
    [[ -b "$rp" ]] || die "Root partition missing: $rp"
    return 0
  fi
  ensure_md_present
}

stage3_cache_path(){ echo "${STAGE3_CACHE_DIR}/$(basename "$STAGE3")"; }

verify_stage3_tarball_md5(){
  local dst="${1:?}"
  [[ "${STAGE3_VERIFY_MD5:-YES}" == YES ]] || return 0
  local dig_url="${STAGE3}.DIGESTS"
  local dig_tmp base algo expected actual parse_out
  base="$(basename "$STAGE3")"
  dig_tmp="$(mktemp -p "$STAGE3_CACHE_DIR" ".digests.XXXXXX")"
  wget -qO "$dig_tmp" "$dig_url" || die "Failed fetching DIGESTS: $dig_url"
  # Upstream .DIGESTS files are OpenPGP-signed and often list SHA512 only (no MD5).
  parse_out="$(awk -v fn="$base" '
    /^# SHA512/ { sect="sha512"; next }
    /^# SHA256/ { sect="sha256"; next }
    /^# MD5/    { sect="md5"; next }
    /^#/       { sect=""; next }
    /^-----/   { sect=""; next }
    /^Hash:/   { next }
    sect != "" && NF>=2 {
      f=$2
      sub(/^\*/, "", f)
      if (f == fn) h[sect]=$1
    }
    END {
      if (h["sha512"] != "") { print "sha512", h["sha512"]; exit }
      if (h["sha256"] != "") { print "sha256", h["sha256"]; exit }
      if (h["md5"] != "")    { print "md5", h["md5"]; exit }
    }
  ' "$dig_tmp")"
  rm -f "$dig_tmp"
  [[ -n "$parse_out" ]] || die "No SHA512/SHA256/MD5 checksum for $base in $dig_url"
  # Shell IFS is $'\n\t' only; read would treat "sha512 <hex>" as one field. Use awk for whitespace fields.
  parse_out="$(printf '%s' "$parse_out" | tr -d '\r')"
  algo="$(printf '%s\n' "$parse_out" | awk 'NF>=2 { print $1; exit }')"
  expected="$(printf '%s\n' "$parse_out" | awk 'NF>=2 { print $2; exit }')"
  [[ -n "$algo" && -n "$expected" ]] || die "Could not parse digest algorithm and hash from DIGESTS (line: ${parse_out:0:120})"
  case "$algo" in
    sha512) need_cmd sha512sum; actual="$(sha512sum "$dst" | awk '{print $1}')" ;;
    sha256) need_cmd sha256sum; actual="$(sha256sum "$dst" | awk '{print $1}')" ;;
    md5)    need_cmd md5sum;    actual="$(md5sum "$dst" | awk '{print $1}')" ;;
    *) die "Unexpected digest algorithm from DIGESTS: $algo" ;;
  esac
  [[ "$actual" == "$expected" ]] || die "$algo mismatch for $base (expected $expected got $actual)"
  echo "$algo verified: $base"
}

fetch_stage3_if_needed(){
  mkdir -p "$STAGE3_CACHE_DIR" 2>/dev/null || true
  local dst; dst="$(stage3_cache_path)"
  if [[ ! -s "$dst" ]]; then
    phase "ensure:stage3_fetch"
    echo "Downloading Stage3 -> $dst"
    wget -O "$dst" "$STAGE3" || die "Stage3 download failed"
  fi
  verify_stage3_tarball_md5 "$dst"
}

ensure_target_mounted(){
  phase "ensure:mount"
  local n="${#INSTALL_DISK_ARR[@]}"
  local i d

  ensure_root_volume_present

  mkdir -p "$TARGET"
  if [[ "${INSTALL_ROOT_IS_RAID:-0}" -eq 0 ]]; then
    mountpoint -q "$TARGET" || mount "$(disk_part "${INSTALL_DISK_ARR[0]}" 2)" "$TARGET"
  else
    mountpoint -q "$TARGET" || mount "$MD" "$TARGET"
  fi

  mkdir -p "$TARGET/boot/efi" "$TARGET/efi"
  mountpoint -q "$TARGET/boot/efi" || mount "$(disk_part "${INSTALL_DISK_ARR[0]}" 1)" "$TARGET/boot/efi"
  mountpoint -q "$TARGET/efi" || mount --bind "$TARGET/boot/efi" "$TARGET/efi"

  if (( n >= 2 )); then
    for (( i = 1; i < n; i++ )); do
      d="${INSTALL_DISK_ARR[i]}"
      local ep num
      num=$((i + 1))
      ep="$(disk_part "$d" 1)"
      mkdir -p "$TARGET/boot/efi${num}" "$TARGET/efi${num}"
      mountpoint -q "$TARGET/boot/efi${num}" || mount "$ep" "$TARGET/boot/efi${num}" \
        || die "Failed to mount ESP $ep on $TARGET/boot/efi${num} (required for multi-disk UEFI)"
      mountpoint -q "$TARGET/efi${num}" || mount --bind "$TARGET/boot/efi${num}" "$TARGET/efi${num}" \
        || die "Failed bind-mount $TARGET/efi${num}"
    done
  fi
}

ensure_stage3_present(){
  phase "ensure:stage3"
  ensure_target_mounted
  [[ -x "$TARGET/bin/bash" ]] && return 0
  fetch_stage3_if_needed
  local tarball; tarball="$(stage3_cache_path)"
  ( cd "$TARGET" && tar xpf "$tarball" --xattrs-include='*.*' --numeric-owner ) || die "Stage3 extraction failed"
  [[ -x "$TARGET/bin/bash" ]] || die "Stage3 extraction failed: bash missing"
}

ensure_chrootprep(){
  phase "ensure:chroot"
  ensure_stage3_present
  ensure_target_mounted

  mkdir -p "$TARGET/tmp" "$TARGET/var/tmp"
  mkdir -p "$TARGET"/{proc,sys,dev,run,etc,root,home,usr,boot,boot/grub,boot/efi,efi,var/db/repos,etc/portage/repos.conf,etc/portage/package.use,etc/portage/package.accept_keywords,etc/portage/package.unmask,etc/portage/package.env,etc/portage/env,etc/dracut.conf.d,etc/kernel,etc/kernel/install.d} || true
  local nd="${#INSTALL_DISK_ARR[@]}"
  local i
  if (( nd >= 2 )); then
    for (( i = 2; i <= nd; i++ )); do
      mkdir -p "$TARGET/boot/efi$i" "$TARGET/efi$i" || true
    done
  fi
  cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null || true

  mountpoint -q "$TARGET/proc" || mount -t proc /proc "$TARGET/proc"
  mountpoint -q "$TARGET/sys"  || { mount --rbind /sys "$TARGET/sys"; mount --make-rslave "$TARGET/sys"; }
  mountpoint -q "$TARGET/dev"  || { mount --rbind /dev "$TARGET/dev"; mount --make-rslave "$TARGET/dev"; }
  mountpoint -q "$TARGET/run"  || { mount --rbind /run "$TARGET/run" 2>/dev/null || true; mount --make-rslave "$TARGET/run" 2>/dev/null || true; }

  mountpoint -q "$TARGET/efi" || mount --bind "$TARGET/boot/efi" "$TARGET/efi"
  if (( nd >= 2 )); then
    for (( i = 2; i <= nd; i++ )); do
      mountpoint -q "$TARGET/efi$i" || mount --bind "$TARGET/boot/efi$i" "$TARGET/efi$i" || true
    done
  fi
}

# Populates name-referenced array with env vars for `env -i` inside the chroot.
chroot_fill_base_env(){
  local -n __chroot_env="${1:?}"
  __chroot_env=(
    "HOME=/root"
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    "TERM=${TERM:-linux}"
    "LANG=${LANG:-C.UTF-8}"
    "TMPDIR=${CHROOT_TMPDIR}"
    "TMP=${CHROOT_TMPDIR}"
    "TEMP=${CHROOT_TMPDIR}"
    "CHROOT_DEBUG=${CHROOT_DEBUG}"
  )
}

# Path to coreutils `env` *inside* $TARGET (required for env -i in chroot).
chroot_env_exe(){
  if [[ -x "$TARGET/usr/bin/env" ]]; then
    printf '%s\n' /usr/bin/env
  elif [[ -x "$TARGET/bin/env" ]]; then
    printf '%s\n' /bin/env
  else
    die "chroot: 'env' not found under ${TARGET} (expected stage3 with /usr/bin/env). Extract stage3 or remount ${TARGET}."
  fi
}

chroot_cmd(){
  local cmd="$1"
  ensure_chrootprep

  local -a base_env
  chroot_fill_base_env base_env
  local envp
  envp="$(chroot_env_exe)"

  echo "CHROOT> $cmd"
  if [[ "${CHROOT_DEBUG:-NO}" == "YES" ]]; then
    chroot "$TARGET" "$envp" -i "${base_env[@]}" /bin/bash -x -l -c "$cmd"
  else
    chroot "$TARGET" "$envp" -i "${base_env[@]}" /bin/bash -l -c "$cmd"
  fi
}

chroot_script(){
  local -a envs=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do envs+=("$1"); shift; done

  ensure_chrootprep

  local -a base_env
  chroot_fill_base_env base_env
  local envp
  envp="$(chroot_env_exe)"

  local name="/root/.installer.$(date +%s).$$.$RANDOM.sh"
  local host_path="$TARGET$name"
  # Strip CR so heredocs from CRLF-checked-out installer repos do not break inside chroot (set: invalid option, etc.).
  tr -d '\r' > "$host_path"
  chmod 0700 "$host_path"

  echo "CHROOT> (script) $name"
  if [[ "${CHROOT_DEBUG:-NO}" == "YES" ]]; then
    chroot "$TARGET" "$envp" -i "${base_env[@]}" "${envs[@]}" /bin/bash -x "$name"
  else
    chroot "$TARGET" "$envp" -i "${base_env[@]}" "${envs[@]}" /bin/bash "$name"
  fi
  local rc=$?
  rm -f "$host_path" 2>/dev/null || true
  return "$rc"
}

# =============================================================================
# Package lists (consumed by chroot_emerge_all)
# =============================================================================

PKGS_CORE=(
  sys-kernel/gentoo-kernel-bin
  sys-kernel/installkernel
  sys-kernel/dracut
  sys-fs/mdadm
  sys-boot/grub
  net-misc/openssh
  app-admin/sudo
  dev-lang/python
)

PKGS_FIRMWARE=( sys-kernel/linux-firmware )

PKGS_SERVER=(
  www-servers/apache
  app-eselect/eselect-php
  dev-lang/php
  dev-db/mariadb
  dev-db/phpmyadmin
  net-ftp/vsftpd
)

PKGS_NODE=( net-libs/nodejs )

PKGS_GUI_BASE=( x11-base/xorg-server x11-apps/xinit x11-base/xorg-drivers )
PKGS_GUI_PLASMA=( kde-plasma/plasma-meta x11-misc/sddm )
PKGS_GUI_GNOME=( gnome-base/gnome gnome-base/gdm )
PKGS_GUI_XFCE=( xfce-base/xfce4-meta x11-misc/lightdm x11-misc/lightdm-gtk-greeter )
PKGS_NET_GUI=( net-misc/networkmanager )

join_space(){ local IFS=' '; echo "$*"; }

# =============================================================================
# Chroot: Portage, kernel, services, bootloader (order matches step_install)
# =============================================================================

chroot_automerge_portage_cfgs(){
  [[ "${AUTO_MERGE_PORTAGE_CFGS:-NO}" == "YES" ]] || return 0
  phase "install:automerge_portage_cfgs"
  chroot_script <<'EOF'
set -euo pipefail
shopt -s nullglob globstar
for f in /etc/portage/**/._cfg*; do
  base="$(basename "$f")"
  new="$(echo "$base" | sed -E 's/^\._cfg[0-9]+_//')"
  dir="$(dirname "$f")"
  [ -n "$new" ] || continue
  dest="$dir/$new"
  [ -e "$dest" ] && cp -a "$dest" "$dest.bak.$(date +%s)" 2>/dev/null || true
  mv -f "$f" "$dest"
done
EOF
}

chroot_bootstrap_portage(){
  phase "install:portage_bootstrap"
  chroot_script "PROFILE_TARGET=$PROFILE_TARGET" "INIT_SYSTEM=${INIT_SYSTEM:-systemd}" <<'EOF'
set -euo pipefail
[ "${CHROOT_DEBUG:-NO}" = "YES" ] && set -x

prof_init="${INIT_SYSTEM:?INIT_SYSTEM unset in portage bootstrap}"

mkdir -p /etc/portage/repos.conf /var/db/repos

cat > /etc/portage/repos.conf/gentoo.conf <<'EOC'
[gentoo]
location = /var/db/repos/gentoo
sync-type = webrsync
EOC

emerge-webrsync
test -d /var/db/repos/gentoo/profiles || { echo "ERROR: repo profiles missing"; exit 1; }

plist="$(eselect profile list)"

pick_id_path() {
  local re="$1"
  echo "$plist" | awk -v n="$re" '
    $0 ~ n && $0 !~ /\/musl\// && $0 !~ /\/x32\// && $0 !~ /\/uclibc\// {
      id=$1; path=$2;
      gsub(/\[/,"",id); gsub(/\]/,"",id);
      print id, path; exit 0
    }'
}

set_profile_by_id() {
  local id="$1"
  [ -n "$id" ] || { echo "ERROR: empty profile id"; exit 2; }
  eselect profile set "$id"
  local p; p="$(readlink -f /etc/portage/make.profile 2>/dev/null || true)"
  echo "Active profile: $p"
  case "$p" in *"/musl/"*) echo "ERROR: musl profile selected"; exit 3 ;; esac
  case "$p" in *"/x32/"*)  echo "ERROR: x32 profile selected";  exit 4 ;; esac
}

pick_hardened_feature_path() {
  local d
  for d in "features/hardened/amd64" "features/hardened"; do
    if [ -d "/var/db/repos/gentoo/profiles/${d}" ]; then
      echo "$d"
      return 0
    fi
  done
  echo "features/hardened"
}

make_stacked_profile() {
  local base_path="$1" feature_path="$2" name="$3"
  local dir="/etc/portage/custom-profiles/$name"
  mkdir -p "$dir"
  printf 'gentoo:%s\ngentoo:%s\n' "$base_path" "$feature_path" > "$dir/parent"
  ln -snf "$dir" /etc/portage/make.profile
  local p; p="$(readlink -f /etc/portage/make.profile 2>/dev/null || true)"
  echo "Active stacked profile: $p"
  [ -f "$p/parent" ] && { echo "Stacked parent:"; cat "$p/parent"; }
}

target="${PROFILE_TARGET:-server}"
id=""
path=""

case "$target" in
  server)          read -r id path < <(pick_id_path "default/linux/amd64/.*/${prof_init}") ;;
  hardened)        read -r id path < <(pick_id_path "default/linux/amd64/.*/hardened/${prof_init}") ;;
  desktop)         read -r id path < <(pick_id_path "default/linux/amd64/.*/desktop/${prof_init}") ;;
  gnome)           read -r id path < <(pick_id_path "default/linux/amd64/.*/desktop/gnome/${prof_init}") ;;
  plasma)          read -r id path < <(pick_id_path "default/linux/amd64/.*/desktop/plasma/${prof_init}") ;;
  xfce)            read -r id path < <(pick_id_path "default/linux/amd64/.*/desktop/xfce/${prof_init}") ;;
  hardened-gnome)
                   read -r id path < <(pick_id_path "default/linux/amd64/.*/desktop/gnome/${prof_init}")
                   set_profile_by_id "$id"
                   make_stacked_profile "$path" "$(pick_hardened_feature_path)" "hardened-gnome"
                   id=""
                   ;;
  hardened-plasma)
                   read -r id path < <(pick_id_path "default/linux/amd64/.*/desktop/plasma/${prof_init}")
                   set_profile_by_id "$id"
                   make_stacked_profile "$path" "$(pick_hardened_feature_path)" "hardened-plasma"
                   id=""
                   ;;
  hardened-xfce)
                   read -r id path < <(pick_id_path "default/linux/amd64/.*/desktop/xfce/${prof_init}")
                   set_profile_by_id "$id"
                   make_stacked_profile "$path" "$(pick_hardened_feature_path)" "hardened-xfce"
                   id=""
                   ;;
  *) echo "ERROR: unknown PROFILE_TARGET=$target"; eselect profile list || true; exit 2 ;;
esac

if [ -n "$id" ]; then
  set_profile_by_id "$id"
fi

cat > /etc/portage/repos.conf/gentoo.conf <<'EOC' || true
[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
sync-uri = rsync://rsync.gentoo.org/gentoo-portage
auto-sync = yes
EOC
EOF
}

chroot_write_make_conf(){
  phase "install:make.conf"
  chroot_script \
    "MAKE_JOBS_DEFAULT=$MAKE_JOBS_DEFAULT" \
    "VIDEO_CARDS=$VIDEO_CARDS" \
    "INPUT_DEVICES=$INPUT_DEVICES" \
    "GUI_ENABLE=$GUI_ENABLE" \
    "ACCEPT_LICENSE=$ACCEPT_LICENSE" \
    "CONFIG_PROTECT_MASK_PORTAGE=$CONFIG_PROTECT_MASK_PORTAGE" \
    <<'EOF'
set -euo pipefail
mkdir -p /etc/portage

use_gui=""
if [ "${GUI_ENABLE:-NO}" = "YES" ]; then
  use_gui="X wayland"
fi

cat > /etc/portage/make.conf <<EOC
COMMON_FLAGS='-O2 -pipe'
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

MAKEOPTS='-j${MAKE_JOBS_DEFAULT}'
FEATURES='parallel-fetch'
ACCEPT_LICENSE='${ACCEPT_LICENSE}'

VIDEO_CARDS="${VIDEO_CARDS}"
INPUT_DEVICES="${INPUT_DEVICES}"

USE="\${use_gui}"
EOC

if [ "${CONFIG_PROTECT_MASK_PORTAGE:-YES}" = "YES" ]; then
  echo 'CONFIG_PROTECT_MASK="/etc/portage"' >> /etc/portage/make.conf
fi

mkdir -p /etc/dracut.conf.d /etc/kernel /etc/kernel/install.d
EOF
}

chroot_write_portage_overrides(){
  phase "install:portage_overrides"
  chroot_script \
    "BREAK_CIRCULAR_DEPS_TIFF_WEBP=$BREAK_CIRCULAR_DEPS_TIFF_WEBP" \
    "BREAK_CIRCULAR_DEPS_PILLOW_TRUETYPE=$BREAK_CIRCULAR_DEPS_PILLOW_TRUETYPE" \
    "GUI_ENABLE=$GUI_ENABLE" \
    "GUI_FLAVOR=$GUI_FLAVOR" \
    "NODE_JOBS=$NODE_JOBS" \
    <<'EOF'
set -euo pipefail
mkdir -p /etc/portage/package.use /etc/portage/package.accept_keywords /etc/portage/package.unmask /etc/portage/package.env /etc/portage/env

cat > /etc/portage/package.use/zz-installer-installkernel <<'EOC'
sys-kernel/installkernel dracut grub
EOC

cat > /etc/portage/package.use/zz-installer-python <<'EOC'
dev-lang/python ssl sqlite
EOC

if [ "${BREAK_CIRCULAR_DEPS_TIFF_WEBP:-NO}" = "YES" ]; then
  echo 'media-libs/tiff -webp' > /etc/portage/package.use/zz-installer-circular-tiff-webp
fi

if [ "${BREAK_CIRCULAR_DEPS_PILLOW_TRUETYPE:-NO}" = "YES" ]; then
  echo 'dev-python/pillow -truetype' > /etc/portage/package.use/zz-installer-circular-pillow
fi

if [ "${GUI_ENABLE:-NO}" = "YES" ] && [ "${GUI_FLAVOR:-}" = "plasma" ]; then
  cat > /etc/portage/package.use/zz-installer-plasma <<'EOC'
dev-qt/qtbase wayland opengl
x11-libs/libxkbcommon X
kde-plasma/kwin lock
EOC
fi

cat > /etc/portage/env/nodejs.conf <<EOC
MAKEOPTS='-j${NODE_JOBS}'
EOC
echo 'net-libs/nodejs nodejs.conf' > /etc/portage/package.env/nodejs
EOF
}

chroot_write_kernel_install_conf(){
  phase "install:kernel_install_conf"
  local root_vol="$MD"
  [[ "${INSTALL_ROOT_IS_RAID:-0}" -eq 0 ]] && root_vol="$(disk_part "${INSTALL_DISK_ARR[0]}" 2)"
  chroot_script \
    "ROOT_VOL_DEV=$root_vol" \
    "ROOT_FS=$ROOT_FS" \
    "KERNEL_CMDLINE_OVERRIDE=$KERNEL_CMDLINE_OVERRIDE" \
    "INIT_SYSTEM=${INIT_SYSTEM:-systemd}" \
    "INSTALL_ROOT_IS_RAID=${INSTALL_ROOT_IS_RAID:-0}" \
    <<'EOF'
set -euo pipefail
mkdir -p /etc/cmdline.d /etc/kernel /etc/kernel/install.d /etc/dracut.conf.d /boot

root_uuid="$(blkid -s UUID -o value "${ROOT_VOL_DEV}")"
[ -n "$root_uuid" ] || { echo "ERROR: cannot read UUID for ${ROOT_VOL_DEV}"; exit 1; }

if [ -n "${KERNEL_CMDLINE_OVERRIDE:-}" ]; then
  cmd="${KERNEL_CMDLINE_OVERRIDE}"
elif [ "${INSTALL_ROOT_IS_RAID:-0}" -eq 1 ]; then
  cmd="root=UUID=${root_uuid} rootfstype=${ROOT_FS} rw rd.auto=1"
else
  cmd="root=UUID=${root_uuid} rootfstype=${ROOT_FS} rw"
fi

printf '%s\n' "$cmd" > /etc/cmdline
printf '%s\n' "$cmd" > /etc/cmdline.d/00-installer.conf
printf '%s\n' "$cmd" > /etc/kernel/cmdline
chmod 0644 /etc/cmdline /etc/cmdline.d/00-installer.conf /etc/kernel/cmdline

cat > /etc/kernel/install.conf <<'EOC'
layout=compat
initrd_generator=dracut
uki_generator=none
EOC

cat > /etc/dracut.conf.d/10-installer-cmdline.conf <<EOC
kernel_cmdline="${cmd}"
EOC

rm -f /etc/dracut.conf.d/99-installer-mdraid.conf 2>/dev/null || true
if [ "${INSTALL_ROOT_IS_RAID:-0}" -eq 1 ]; then
  cat > /etc/dracut.conf.d/99-installer-mdraid.conf <<'EOC'
add_dracutmodules+=" mdraid "
EOC
fi

cat > /etc/kernel/install.d/05-check-chroot.install <<'EOC'
#!/bin/sh
exit 0
EOC
chmod 0755 /etc/kernel/install.d/05-check-chroot.install

if [ "${INIT_SYSTEM:-systemd}" = "systemd" ] && [ ! -s /etc/machine-id ]; then
  systemd-machine-id-setup >/dev/null 2>&1 || true
fi
EOF
}

chroot_create_swap(){
  phase "install:swap"
  chroot_script "SWAP_SIZE_GB=$SWAP_SIZE_GB" <<'EOF'
set -euo pipefail
swapfile=/swapfile
if ! grep -q '^/swapfile[[:space:]]' /etc/fstab 2>/dev/null; then
  rm -f "$swapfile" || true
  if ! fallocate -l "${SWAP_SIZE_GB}G" "$swapfile" 2>/dev/null; then
    dd if=/dev/zero of="$swapfile" bs=1M count=$((SWAP_SIZE_GB*1024)) status=progress
  fi
  chmod 600 "$swapfile"
  mkswap "$swapfile"
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
EOF
}

chroot_emerge_all(){
  phase "install:emerge"

  local -a pkgs=("${PKGS_CORE[@]}")
  [[ "$INSTALL_FIRMWARE" == "YES" ]] && pkgs+=("${PKGS_FIRMWARE[@]}")
  [[ "$INSTALL_SERVER_STACK" == "YES" ]] && pkgs+=("${PKGS_SERVER[@]}")
  [[ "$INSTALL_NODE" == "YES" ]] && pkgs+=("${PKGS_NODE[@]}")

  if [[ "$GUI_ENABLE" == "YES" ]]; then
    pkgs+=("${PKGS_GUI_BASE[@]}")
    [[ "$GUI_ENABLE_NETWORKMANAGER" == "YES" ]] && pkgs+=("${PKGS_NET_GUI[@]}")
    case "$GUI_FLAVOR" in
      plasma) pkgs+=("${PKGS_GUI_PLASMA[@]}") ;;
      gnome)  pkgs+=("${PKGS_GUI_GNOME[@]}") ;;
      xfce)   pkgs+=("${PKGS_GUI_XFCE[@]}") ;;
      *) die "Unknown GUI_FLAVOR=$GUI_FLAVOR" ;;
    esac
  fi

  local pkg_str; pkg_str="$(join_space "${pkgs[@]}")"

  chroot_script "PKGS=$pkg_str" "AUTO_MERGE_PORTAGE_CFGS=$AUTO_MERGE_PORTAGE_CFGS" <<'EOF'
set -euo pipefail

merge_cfgs() {
  shopt -s nullglob globstar
  for f in /etc/portage/**/._cfg*; do
    base="$(basename "$f")"
    new="$(echo "$base" | sed -E 's/^\._cfg[0-9]+_//')"
    dir="$(dirname "$f")"
    [ -n "$new" ] || continue
    dest="$dir/$new"
    [ -e "$dest" ] && cp -a "$dest" "$dest.bak.$(date +%s)" 2>/dev/null || true
    mv -f "$f" "$dest"
  done
}

set +e
emerge --resume --ask=n
resume_rc=$?
set -e
if [ "$resume_rc" -eq 0 ]; then
  exit 0
fi

attempt=1
while true; do
  log="/root/.emerge.$(date +%s).log"
  set +e
  emerge --ask=n --autounmask-write=y --autounmask-continue=y -v ${PKGS} 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e

  if [ "$rc" -eq 0 ]; then
    break
  fi

  if [ "${AUTO_MERGE_PORTAGE_CFGS:-YES}" = "YES" ]; then
    merge_cfgs
  fi

  if [ "$attempt" -ge 5 ]; then
    exit "$rc"
  fi

  attempt=$((attempt+1))
done
EOF

  chroot_automerge_portage_cfgs
}

chroot_kernel_deploy(){
  phase "install:kernel_deploy"
  chroot_script <<'EOF'
set -euo pipefail
if compgen -G '/var/db/pkg/sys-kernel/gentoo-kernel-bin-*' >/dev/null; then
  emerge --config sys-kernel/gentoo-kernel-bin || true
fi
EOF
}

chroot_write_fstab(){
  phase "install:fstab"
  local primary="${INSTALL_DISK_ARR[0]}"
  local efi_dev root_vol
  efi_dev="$(disk_part "$primary" 1)"
  root_vol="$MD"
  [[ "${INSTALL_ROOT_IS_RAID:-0}" -eq 0 ]] && root_vol="$(disk_part "$primary" 2)"
  chroot_script \
    "EFI_PART_DEV=$efi_dev" \
    "ROOT_VOL_DEV=$root_vol" \
    "ROOT_FS=$ROOT_FS" \
    "INSTALL_ROOT_IS_RAID=${INSTALL_ROOT_IS_RAID:-0}" \
    <<'EOF'
set -euo pipefail
efi_uuid="$(blkid -s UUID -o value "${EFI_PART_DEV}")"
root_uuid="$(blkid -s UUID -o value "${ROOT_VOL_DEV}")"
if [ "${INSTALL_ROOT_IS_RAID:-0}" -eq 1 ]; then
  mdadm --detail --scan > /etc/mdadm.conf || true
else
  : > /etc/mdadm.conf || true
fi
cat > /etc/fstab <<EOC
UUID=${root_uuid}  /          ${ROOT_FS}  noatime,errors=remount-ro  0 1
UUID=${efi_uuid}   /boot/efi   vfat       umask=0077               0 2
/swapfile          none        swap       sw                       0 0
EOC
EOF
}

chroot_dracut_initramfs(){
  phase "install:initramfs"
  chroot_script "INSTALL_ROOT_IS_RAID=${INSTALL_ROOT_IS_RAID:-0}" <<'EOF'
set -euo pipefail
mkdir -p /boot /etc/dracut.conf.d
kver="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1)"
[ -n "$kver" ] || { echo "ERROR: /lib/modules missing or empty"; exit 2; }
out="/boot/initramfs-${kver}.img"
if [ "${INSTALL_ROOT_IS_RAID:-0}" -eq 1 ]; then
  dracut --force "$out" "$kver" --add mdraid
else
  dracut --force "$out" "$kver"
fi
ls -l "$out"
EOF
}

chroot_enable_services(){
  phase "install:services (INIT_SYSTEM=${INIT_SYSTEM:-systemd})"
  chroot_script \
    "GUI_ENABLE=$GUI_ENABLE" \
    "GUI_FLAVOR=$GUI_FLAVOR" \
    "GUI_ENABLE_NETWORKMANAGER=$GUI_ENABLE_NETWORKMANAGER" \
    "INSTALL_SERVER_STACK=$INSTALL_SERVER_STACK" \
    "INIT_SYSTEM=${INIT_SYSTEM:-systemd}" \
    <<'EOF'
set -euo pipefail
# Single dispatcher: every boot service goes through svc_enable so systemd vs OpenRC stays consistent.
init="${INIT_SYSTEM:-systemd}"
case "$init" in systemd|openrc) ;; *) echo "ERROR: INIT_SYSTEM must be systemd or openrc (got $init)" >&2; exit 1 ;; esac

svc_enable(){
  local name="$1"
  case "$init" in
    systemd) systemctl enable "$name" || true ;;
    openrc)  rc-update add "$name" default || true ;;
  esac
}

svc_enable_php_fpm_if_present(){
  case "$init" in
    systemd)
      if systemctl list-unit-files 2>/dev/null | grep -q '^php-fpm\.service'; then
        svc_enable php-fpm
      fi
      ;;
    openrc)
      if [ -x /etc/init.d/php-fpm ]; then
        svc_enable php-fpm
      fi
      ;;
  esac
}

svc_enable sshd

if [ "${INSTALL_SERVER_STACK:-NO}" = "YES" ]; then
  svc_enable apache2
  svc_enable mariadb
  svc_enable vsftpd
  svc_enable_php_fpm_if_present
fi

if [ "${GUI_ENABLE:-NO}" = "YES" ]; then
  if [ "${GUI_ENABLE_NETWORKMANAGER:-NO}" = "YES" ]; then
    svc_enable NetworkManager
  fi
  case "${GUI_FLAVOR:-}" in
    plasma) svc_enable sddm ;;
    gnome)  svc_enable gdm ;;
    xfce)   svc_enable lightdm ;;
  esac
fi
EOF
}

chroot_install_grub(){
  phase "install:grub"
  chroot_script "GRUB_REMOVABLE=$GRUB_REMOVABLE" <<'EOF'
set -euo pipefail
rem=""
[ "${GRUB_REMOVABLE:-NO}" = "YES" ] && rem="--removable"
mkdir -p /boot/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo --recheck $rem
grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

mirror_esp_to_additional_disks(){
  [[ "$GRUB_INSTALL_TO_DISK_B" == "YES" ]] || return 0
  local n="${#INSTALL_DISK_ARR[@]}"
  (( n >= 2 )) || return 0
  phase "install:grub_mirror_extra_esps"
  local i efi_num
  for (( i = 1; i < n; i++ )); do
    efi_num=$((i + 1))
    chroot_script "GRUB_REMOVABLE=$GRUB_REMOVABLE" "EFI_NUM=$efi_num" <<'EOF'
set -euo pipefail
rem=""
[ "${GRUB_REMOVABLE:-NO}" = "YES" ] && rem="--removable"
efidir="/boot/efi${EFI_NUM}"
[[ -d "$efidir" ]] || { echo "ERROR: $efidir missing (extra ESP not mounted?)"; exit 1; }
grub-install --target=x86_64-efi --efi-directory="$efidir" --bootloader-id=Gentoo --recheck $rem
rsync -aHAX --delete /boot/efi/ "$efidir/"
EOF
  done
}

chroot_create_first_user(){
  [[ "$FIRST_USER_ENABLE" == "YES" ]] || return 0
  phase "install:first_user"
  chroot_script \
    "FIRST_USER_NAME=$FIRST_USER_NAME" \
    "FIRST_USER_PASSWORD=$FIRST_USER_PASSWORD" \
    "FIRST_USER_GROUPS=$FIRST_USER_GROUPS" \
    "FIRST_USER_SHELL=$FIRST_USER_SHELL" \
    "SUDO_WHEEL_NOPASSWD=$SUDO_WHEEL_NOPASSWD" \
    <<'EOF'
set -euo pipefail
user="${FIRST_USER_NAME}"
groups_csv="${FIRST_USER_GROUPS}"
shell="${FIRST_USER_SHELL}"

IFS=',' read -r -a groups_arr <<< "$groups_csv"
for g in "${groups_arr[@]}"; do
  g="$(echo "$g" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [ -n "$g" ] || continue
  getent group "$g" >/dev/null 2>&1 || groupadd "$g" || true
done

id "$user" >/dev/null 2>&1 || useradd -m -s "$shell" -G "$groups_csv" "$user"

if [ -n "${FIRST_USER_PASSWORD:-}" ]; then
  printf '%s:%s\n' "$user" "$FIRST_USER_PASSWORD" | chpasswd
else
  echo "No FIRST_USER_PASSWORD set; running passwd interactively."
  passwd "$user"
fi

mkdir -p /etc/sudoers.d
if [ "${SUDO_WHEEL_NOPASSWD:-NO}" = "YES" ]; then
  echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/00-wheel
else
  echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/00-wheel
fi
chmod 0440 /etc/sudoers.d/00-wheel
EOF
}

# =============================================================================
# Orchestration: emerge pipeline, passwords, readiness, main
# =============================================================================

step_install(){
  phase "install (INIT_SYSTEM=${INIT_SYSTEM:-systemd})"
  chroot_cmd "source /etc/profile && env-update || true"
  chroot_bootstrap_portage
  chroot_write_make_conf
  chroot_write_portage_overrides
  chroot_write_kernel_install_conf
  chroot_create_swap
  chroot_emerge_all
  chroot_kernel_deploy
  chroot_write_fstab
  chroot_dracut_initramfs
  chroot_enable_services
  chroot_install_grub
  mirror_esp_to_additional_disks
  chroot_create_first_user
}

step_passwd(){
  phase "passwd"
  chroot_script "ROOT_PASSWORD=$ROOT_PASSWORD" "PASSWD_ALWAYS_SET=$PASSWD_ALWAYS_SET" <<'EOF'
set -euo pipefail
root_hash="$(awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null || true)"
needs_set=0
case "$root_hash" in ""|"!"*|"*"*) needs_set=1 ;; esac
if [ "${PASSWD_ALWAYS_SET:-NO}" = "YES" ] && [ -n "${ROOT_PASSWORD:-}" ]; then
  needs_set=1
fi
if [ -n "${ROOT_PASSWORD:-}" ] && [ "$needs_set" -eq 1 ]; then
  printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
  echo "ROOT password set from ROOT_PASSWORD."
  exit 0
fi
if [ "$needs_set" -eq 1 ]; then
  echo "Set ROOT password now:"
  passwd
fi
EOF
}

reboot_readiness_report(){
  local ok=1
  local -a missing=()

  mountpoint -q "$TARGET" || missing+=("target mounted: $TARGET")
  [[ -f "$TARGET/etc/fstab" ]] || missing+=("/etc/fstab")
  if [[ "${INSTALL_ROOT_IS_RAID:-0}" -eq 1 ]]; then
    [[ -f "$TARGET/etc/mdadm.conf" ]] || missing+=("/etc/mdadm.conf")
  fi
  [[ -f "$TARGET/boot/grub/grub.cfg" ]] || missing+=("/boot/grub/grub.cfg")

  if ! ls "$TARGET/boot"/kernel-* "$TARGET/boot"/vmlinuz-* >/dev/null 2>&1; then
    missing+=("kernel image in /boot")
  fi
  if ! ls "$TARGET/boot"/initramfs-* "$TARGET/boot"/initrd* "$TARGET/boot"/*.img >/dev/null 2>&1; then
    missing+=("initramfs image in /boot")
  fi

  if [[ -f "$TARGET/etc/shadow" ]]; then
    local root_hash
    root_hash="$(awk -F: '$1=="root"{print $2}' "$TARGET/etc/shadow" 2>/dev/null || true)"
    case "$root_hash" in ""|"!"*|"*"*) missing+=("root password set") ;; esac
  else
    missing+=("/etc/shadow")
  fi

  if [[ "${FIRST_USER_ENABLE:-NO}" == "YES" && -n "${FIRST_USER_NAME:-}" ]]; then
    if [[ -f "$TARGET/etc/passwd" ]]; then
      grep -qE "^${FIRST_USER_NAME}:" "$TARGET/etc/passwd" || missing+=("user exists: ${FIRST_USER_NAME}")
    else
      missing+=("/etc/passwd")
    fi
  fi

  (( ${#missing[@]} == 0 )) || ok=0

  echo
  echo "===== REBOOT READINESS ====="
  if [[ "$ok" -eq 1 ]]; then
    echo "SAFE TO REBOOT"
    printf '\a' || true
  else
    echo "NOT SAFE TO REBOOT"
    for x in "${missing[@]}"; do
      echo "  - $x"
    done
  fi
  echo "============================"
  echo
}

finish_msg(){
  reboot_readiness_report
  echo "DONE."
  echo "Log  : $LOG"
  echo "State: $STATE"
  echo
  echo "Next:"
  echo "  umount -R $TARGET"
  echo "  reboot"
  echo
}

# =============================================================================
# main
# =============================================================================

main(){
  local -a INSTALLER_INVOCATION_ARGV=("$@")
  local RESET=0 RESET_PHASE="" PRINT_ERASE_TOKEN=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reset) RESET=1; shift ;;
      --reset-phase) shift; [[ $# -gt 0 ]] || die "--reset-phase requires arg"; RESET_PHASE="$1"; shift ;;
      --print-erase-token) PRINT_ERASE_TOKEN=1; shift ;;
      -h|--help)
        echo "Usage: $0 [--reset] [--reset-phase <phase>] [--print-erase-token]"
        exit 0
        ;;
      *) die "Unknown arg: $1" ;;
    esac
  done

  need_root
  check_installer_upstream INSTALLER_INVOCATION_ARGV
  if [[ "$PRINT_ERASE_TOKEN" -eq 1 ]]; then
    need_cmd lsblk
    install_disks_resolve
    printf 'CONFIRM_ERASE=%s\n' "$(confirm_erase_expected)"
    exit 0
  fi
  for c in sgdisk mdadm wipefs partprobe udevadm rsync tar mount umount findmnt lsblk mkfs.vfat mkfs.ext4 mktemp yes blockdev wget chroot blkid sed stat grep awk curl dd fallocate mkswap; do
    need_cmd "$c"
  done

  install_disks_resolve
  check_internet
  resolve_stage3
  require_inputs
  export INIT_SYSTEM
  announce_install_profile
  init_state

  if [[ "$RESET" -eq 1 ]]; then rm -f "$STATE"; init_state; fi
  if [[ -n "$RESET_PHASE" ]]; then truncate_state_from_phase "$RESET_PHASE"; fi

  start_watchdog

  run_step time      step_time
  run_step wipe      step_wipe
  run_step partition step_partition
  run_step mkfsraid  step_mkfsraid

  ensure_target_mounted; step_done mount || mark_done mount
  ensure_stage3_present; step_done stage3 || mark_done stage3
  ensure_chrootprep;     step_done chroot || mark_done chroot

  run_step install   step_install
  run_step passwd    step_passwd

  stop_watchdog
  finish_msg
}

main "$@"