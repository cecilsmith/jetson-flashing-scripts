#!/usr/bin/env bash
#
# flash-jetson.sh — one-stop flashing tool for the NVIDIA Jetson Orin family.
#
# Downloads and installs every host-side prerequisite, fetches the matching
# Jetson Linux BSP + sample root filesystem, assembles the rootfs, and flashes
# a Jetson Orin Nano / Orin NX / AGX Orin developer kit to NVMe, USB, microSD
# or eMMC — interactively, or fully unattended via flags.
#
# Host requirements: Ubuntu 20.04/22.04/24.04 on x86_64, with the Jetson in
# Force Recovery Mode connected over USB.
#
# Procedure follows the NVIDIA Jetson Linux Developer Guide "Quick Start":
#   JetPack 6.x : https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/IN/QuickStart.html
#   JetPack 7.x : https://docs.nvidia.com/jetson/archives/r39.2/DeveloperGuide/IN/QuickStart.html
#
# Written for bash 3.2+ so it can be syntax-checked on any host.
#
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
readonly NV_DL="https://developer.nvidia.com/downloads/embedded"

# ---------------------------------------------------------------------------
# Defaults (every one of these is overridable by a flag)
# ---------------------------------------------------------------------------
WORKDIR="${JETSON_FLASH_WORKDIR:-$HOME/jetson-flash}"
JETPACK=""              # 6.1 6.2 6.2.1 6.2.2 6.2.3 7.2 7.2.1 (or an L4T version)
DEVICE=""               # nano | nx | agx | agx-industrial
BOARD=""                # explicit board config, overrides DEVICE/SUPER
STORAGE=""              # nvme | usb | sd | emmc
SUPER_MODE=""           # "" | off | on | maxn
EXTERNAL_DEVICE=""      # override for --external-device (e.g. nvme0n1p1)
NVME_LAYOUT="default"   # default | ab | enc | ab-enc
TARGET=""               # override the positional target: internal | external
ROOTFS_SIZE=""          # -S value, e.g. 60GiB
ERASE_ALL=""            # "" = per-release default, yes, no
MASSFLASH=""            # integer: number of devices for concurrent flashing
NEW_USER=""; NEW_PASS=""; NEW_HOST=""; AUTOLOGIN="no"; ACCEPT_LICENSE="no"
ASSUME_YES="no"
DRY_RUN="no"
SKIP_DEPS="no"
DEPS_ONLY="no"
CHECK_ONLY="no"
LIST_ONLY="no"
NO_FLASH="no"           # build images only, do not touch the board
FLASH_ONLY="no"         # flash previously generated images
SHOWLOGS="yes"
FORCE_EXTRACT="no"
KEEP_DOWNLOADS="yes"
FORCE_HOST="no"         # bypass Ubuntu/x86_64 host checks
EXTRA_FLASH_ARGS=""
SUDO=""
SUDO_KEEPALIVE_PID=""
LOGFILE=""

# Populated by resolve_release()
JP_VER=""; L4T_VER=""; L4T_MAJOR=""; BSP_URL=""; RFS_URL=""; BSP_FILE=""; RFS_FILE=""
LFT=""                  # path to the prepared Linux_for_Tegra directory

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_BLD=""; C_OFF=""
fi

log()   { printf '%s==>%s %s\n'  "$C_BLU" "$C_OFF" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()   { printf '%serr %s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
step()  { printf '\n%s%s%s\n' "$C_BLD$C_CYN" "$*" "$C_OFF"; }
die()   { err "$*"; exit 1; }

on_error() {
    local rc=$? line=${1:-?}
    err "failed at line $line (exit $rc)"
    [ -n "$LOGFILE" ] && err "full log: $LOGFILE"
    exit "$rc"
}
trap 'on_error $LINENO' ERR

cleanup() {
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Quote an argv array for display so printed commands are copy-pasteable.
# Anything equal to a known secret is replaced, so passwords never reach the
# terminal or the log file.
show_cmd() {
    local out="" a
    for a in "$@"; do
        if [ -n "$NEW_PASS" ] && [ "$a" = "$NEW_PASS" ]; then
            out="$out ********"
            continue
        fi
        case "$a" in
            *[!A-Za-z0-9_/.=:,+-]*) out="$out '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'" ;;
            *) out="$out $a" ;;
        esac
    done
    printf '%s' "${out# }"
}

# Run a command, honouring --dry-run.
run() {
    printf '%s  $%s %s\n' "$C_CYN" "$C_OFF" "$(show_cmd "$@")"
    [ "$DRY_RUN" = "yes" ] && return 0
    "$@"
}

# Run a command from inside a directory, honouring --dry-run. Used for the BSP
# steps, which must all execute with Linux_for_Tegra as the working directory.
run_in() {
    local dir="$1"; shift
    if [ "$DRY_RUN" = "yes" ]; then
        printf '%s  $%s cd %s && %s\n' "$C_CYN" "$C_OFF" "$dir" "$(show_cmd "$@")"
        return 0
    fi
    printf '%s  $%s %s\n' "$C_CYN" "$C_OFF" "$(show_cmd "$@")"
    ( cd "$dir" && "$@" )
}

# ---------------------------------------------------------------------------
# Release matrix
#
# NVIDIA is inconsistent about capitalisation and about "release" vs
# "releases" in these paths, so every entry below was verified to return
# HTTP 200 rather than derived from a pattern.
# ---------------------------------------------------------------------------
readonly SUPPORTED_JETPACKS="6.1 6.2 6.2.1 6.2.2 6.2.3 7.2 7.2.1"

resolve_release() {
    local q dir tag
    q="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    case "$q" in
        6.1|jp6.1|36.4|36.4.0)
            JP_VER=6.1;   L4T_VER=36.4.0; dir="l4t/r36_release_v4.0/release";  tag="R36.4.0" ;;
        6.2|jp6.2|36.4.3)
            JP_VER=6.2;   L4T_VER=36.4.3; dir="l4t/r36_release_v4.3/release";  tag="r36.4.3" ;;
        6.2.1|jp6.2.1|36.4.4)
            JP_VER=6.2.1; L4T_VER=36.4.4; dir="l4t/r36_release_v4.4/release";  tag="r36.4.4" ;;
        6.2.2|jp6.2.2|36.5|36.5.0)
            JP_VER=6.2.2; L4T_VER=36.5.0; dir="l4t/r36_release_v5.0/release";  tag="r36.5.0" ;;
        6.2.3|jp6.2.3|36.5.2)
            JP_VER=6.2.3; L4T_VER=36.5.2; dir="l4t/r36_release_v5.2/releases"; tag="r36.5.2" ;;
        7.2|jp7.2|39.2|39.2.0)
            JP_VER=7.2;   L4T_VER=39.2.0; dir="L4T/r39_Release_v2.0/release";  tag="R39.2.0" ;;
        7.2.1|jp7.2.1|39.2.1)
            JP_VER=7.2.1; L4T_VER=39.2.1; dir="L4T/r39_Release_v2.1/release";  tag="R39.2.1" ;;
        6.0|6.0dp|36.2|36.3)
            die "JetPack $1 predates the supported range. Use one of: $SUPPORTED_JETPACKS" ;;
        7.0|7.1|38.*)
            die "JetPack $1 (Jetson Linux 38.x) supports Jetson AGX Thor only — it has no Orin
     support. JetPack 7.2 (L4T 39.2) is the first JetPack 7 release that
     flashes the Orin family. Use --jetpack 7.2, or a 6.x release." ;;
        *)
            return 1 ;;
    esac
    L4T_MAJOR="${L4T_VER%%.*}"
    BSP_FILE="Jetson_Linux_${tag}_aarch64.tbz2"
    RFS_FILE="Tegra_Linux_Sample-Root-Filesystem_${tag}_aarch64.tbz2"
    BSP_URL="$NV_DL/$dir/$BSP_FILE"
    RFS_URL="$NV_DL/$dir/$RFS_FILE"
    return 0
}

# Approximate free space needed under $WORKDIR, in GiB: tarballs + extracted
# rootfs + the flash images the initrd flasher stages before sending them.
space_needed_gib() {
    case "$L4T_MAJOR" in
        39) printf '80' ;;
        *)  printf '60' ;;
    esac
}

# ---------------------------------------------------------------------------
# Board / module tables
# ---------------------------------------------------------------------------
# USB product IDs reported in Force Recovery Mode (vendor 0955, NVIDIA Corp),
# from the Developer Guide's "To determine whether the developer kit is in
# force recovery mode" table.
pid_to_module() {
    case "$1" in
        7023) printf 'agx|Jetson AGX Orin (P3701-0000 32GB / P3701-0005 64GB / P3701-0008 Industrial)' ;;
        7223) printf 'agx|Jetson AGX Orin 32GB (P3701-0004)' ;;
        7323) printf 'nx|Jetson Orin NX 16GB (P3767-0000)' ;;
        7423) printf 'nx|Jetson Orin NX 8GB (P3767-0001)' ;;
        7523) printf 'nano|Jetson Orin Nano 8GB (P3767-0003 / P3767-0005)' ;;
        7623) printf 'nano|Jetson Orin Nano 4GB (P3767-0004)' ;;
        *)    : ;;
    esac
}

# device family -> base board config name
device_to_board() {
    case "$1" in
        nano|nx)         printf 'jetson-orin-nano-devkit' ;;
        agx)             printf 'jetson-agx-orin-devkit' ;;
        agx-industrial)  printf 'jetson-agx-orin-devkit-industrial' ;;
        *) : ;;
    esac
}

is_agx_board() {
    case "$1" in
        jetson-agx-orin-devkit*) return 0 ;;
        *) return 1 ;;
    esac
}

storage_to_device_node() {
    case "$1" in
        nvme) printf 'nvme0n1p1' ;;
        usb)  printf 'sda1' ;;
        sd)   printf 'mmcblk0p1' ;;
        *) : ;;
    esac
}

nvme_layout_xml() {
    case "$1" in
        default) printf 'tools/kernel_flash/flash_l4t_t234_nvme.xml' ;;
        ab)      printf 'tools/kernel_flash/flash_l4t_t234_nvme_rootfs_ab.xml' ;;
        enc)     printf 'tools/kernel_flash/flash_l4t_t234_nvme_rootfs_enc.xml' ;;
        ab-enc)  printf 'tools/kernel_flash/flash_l4t_t234_nvme_rootfs_ab_enc.xml' ;;
        *) : ;;
    esac
}

print_matrix() {
    cat <<'MATRIX'
Supported JetPack releases (Jetson Orin family)
-----------------------------------------------
  JetPack   Jetson Linux   Notes
  6.1       36.4.0         no SUPER configs (introduced in 6.2)
  6.2       36.4.3         first release with SUPER / MAXN_SUPER
  6.2.1     36.4.4
  6.2.2     36.5.0
  6.2.3     36.5.2         latest JetPack 6
  7.2       39.2.0         first JetPack 7 with Orin support
  7.2.1     39.2.1         latest

  JetPack 7.0 / 7.1 (L4T 38.x) are Jetson AGX Thor only and are rejected.

Devices and board configs
-------------------------
  --device nano | nx      -> jetson-orin-nano-devkit
                             jetson-orin-nano-devkit-super       (--super)
                             jetson-orin-nano-devkit-super-maxn  (--super-maxn)
  --device agx            -> jetson-agx-orin-devkit
  --device agx-industrial -> jetson-agx-orin-devkit-industrial

Storage targets
---------------
  --storage nvme  -> nvme0n1p1   (Orin Nano/NX and AGX Orin)
  --storage usb   -> sda1        (64 GB or larger on Orin Nano/NX)
  --storage sd    -> mmcblk0p1   (64 GB or larger on Orin Nano/NX)
  --storage emmc  -> AGX Orin only, flashed with flash.sh

SUPER mode
----------
  Orin Nano and Orin NX expose the uncapped MAXN_SUPER power mode only when
  the board was flashed with a SUPER config. After first boot:
    Orin Nano 8GB : sudo nvpmodel -m 2     (MAXN_SUPER; default is 25W, mode 1)
    Orin Nano 4GB : sudo nvpmodel -m 2     (MAXN_SUPER; default is 25W, mode 1)
    Orin NX 8/16GB: sudo nvpmodel -m 0     (MAXN_SUPER; default is 40W, mode 4)
  Verify with `sudo nvpmodel -q`; a reboot may be required.
MATRIX
}


# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<__USAGE_TEXT__
$SCRIPT_NAME $SCRIPT_VERSION — flash NVIDIA Jetson Orin devices end to end.

Run with no arguments for a guided, interactive session. Supply flags to skip
any prompt; supply enough flags plus --yes and it runs completely unattended.

Usage:
  $SCRIPT_NAME [options]

What to flash:
  -j, --jetpack <ver>       JetPack or Jetson Linux version.
                            One of: $SUPPORTED_JETPACKS
                            (L4T numbers such as 36.4.3 or 39.2.0 also work.)
  -d, --device <name>       nano | nx | agx | agx-industrial
                            Omit to auto-detect from the USB recovery-mode ID.
  -b, --board <config>      Explicit board config, e.g. jetson-orin-nano-devkit-super.
                            Overrides --device and --super.
  -s, --storage <target>    nvme | usb | sd | emmc
      --external-device <d> Override the storage node. Defaults to nvme0n1p1,
                            sda1 or mmcblk0p1 depending on --storage.

SUPER mode, for Orin Nano / Orin NX on JetPack 6.2 and newer:
      --super               Flash jetson-orin-nano-devkit-super, unlocking the
                            25W and MAXN_SUPER power modes.
      --super-maxn          Flash jetson-orin-nano-devkit-super-maxn, which
                            additionally raises EMC/scf/hub clock ceilings.
      --no-super            Force the plain non-SUPER config.

Partitioning and rootfs:
      --nvme-layout <kind>  default | ab | enc | ab-enc
                            ab = redundant A/B rootfs, enc = encrypted rootfs.
      --target <which>      internal | external. Overrides the positional target
                            the flasher is given. Only needed to deviate from
                            NVIDIA's documented value for your combination.
  -S, --rootfs-size <size>  APP partition size, e.g. 60GiB. Default: BSP default.
      --erase-all           Erase the whole target disk before flashing.
      --no-erase-all        Do not erase. This is the JetPack 6 default.

Pre-seeding first boot, which skips the on-device oem-config wizard:
  -u, --user <name>         Create this user account in the image.
  -p, --password <pw>       Password for that account. Prompted for if omitted.
  -n, --hostname <name>     Hostname to bake into the image.
      --autologin           Log that user in automatically.
      --accept-license      Accept the NVIDIA end user licence on their behalf.

Flash behaviour:
      --no-flash            Generate images only; do not touch the board.
      --flash-only          Flash images generated by an earlier --no-flash run.
      --massflash <n>       Flash up to <n> boards concurrently.
      --extra-flash-args    Extra arguments appended verbatim to the flasher.
      --quiet               Do not pass --showlogs to the flasher.

Host and workspace:
  -w, --workdir <path>      Download/build directory. Default: $WORKDIR
      --skip-deps           Do not install host packages.
      --deps-only           Install host prerequisites, then exit.
      --force-extract       Re-extract the BSP even if it looks prepared.
      --clean               Delete downloaded tarballs when finished.
      --force-host          Continue even if the host is not Ubuntu x86_64.

Modes:
      --check               Diagnose the host and the connected board, then exit.
      --list                Print the supported version/board matrix, then exit.
      --dry-run             Print every command instead of running it.
  -y, --yes                 Never prompt; accept defaults and confirmations.
  -h, --help                This message.
  -V, --version             Print version.

Examples:
  # Guided, asks everything:
  ./$SCRIPT_NAME

  # Orin Nano Super devkit, JetPack 6.2, onto NVMe, unattended:
  ./$SCRIPT_NAME -j 6.2 -d nano --super -s nvme -y

  # Orin NX on NVMe with a pre-created user, latest JetPack 6:
  ./$SCRIPT_NAME -j 6.2.3 -d nx --super -s nvme \\
      -u nvidia -p nvidia -n orin-nx --accept-license -y

  # AGX Orin devkit to its internal eMMC on JetPack 7.2:
  ./$SCRIPT_NAME -j 7.2 -d agx -s emmc -y

  # See exactly what would run, without downloading or flashing:
  ./$SCRIPT_NAME -j 6.2 -d nano --super -s sd -y --dry-run
__USAGE_TEXT__
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
need_arg() { [ $# -ge 2 ] || die "option $1 requires a value"; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -j|--jetpack)        need_arg "$@"; JETPACK="$2"; shift 2 ;;
            -d|--device)         need_arg "$@"; DEVICE="$(printf '%s' "$2" | tr 'A-Z' 'a-z')"; shift 2 ;;
            -b|--board)          need_arg "$@"; BOARD="$2"; shift 2 ;;
            -s|--storage)        need_arg "$@"; STORAGE="$(printf '%s' "$2" | tr 'A-Z' 'a-z')"; shift 2 ;;
            --external-device)   need_arg "$@"; EXTERNAL_DEVICE="$2"; shift 2 ;;
            --super)             SUPER_MODE="on"; shift ;;
            --super-maxn)        SUPER_MODE="maxn"; shift ;;
            --no-super)          SUPER_MODE="off"; shift ;;
            --nvme-layout)       need_arg "$@"; NVME_LAYOUT="$2"; shift 2 ;;
            --target)            need_arg "$@"; TARGET="$(printf '%s' "$2" | tr 'A-Z' 'a-z')"; shift 2 ;;
            -S|--rootfs-size)    need_arg "$@"; ROOTFS_SIZE="$2"; shift 2 ;;
            --erase-all)         ERASE_ALL="yes"; shift ;;
            --no-erase-all)      ERASE_ALL="no"; shift ;;
            -u|--user)           need_arg "$@"; NEW_USER="$2"; shift 2 ;;
            -p|--password)       need_arg "$@"; NEW_PASS="$2"; shift 2 ;;
            -n|--hostname)       need_arg "$@"; NEW_HOST="$2"; shift 2 ;;
            --autologin)         AUTOLOGIN="yes"; shift ;;
            --accept-license)    ACCEPT_LICENSE="yes"; shift ;;
            --no-flash)          NO_FLASH="yes"; shift ;;
            --flash-only)        FLASH_ONLY="yes"; shift ;;
            --massflash)         need_arg "$@"; MASSFLASH="$2"; shift 2 ;;
            --extra-flash-args)  need_arg "$@"; EXTRA_FLASH_ARGS="$2"; shift 2 ;;
            --quiet)             SHOWLOGS="no"; shift ;;
            -w|--workdir)        need_arg "$@"; WORKDIR="$2"; shift 2 ;;
            --skip-deps)         SKIP_DEPS="yes"; shift ;;
            --deps-only)         DEPS_ONLY="yes"; shift ;;
            --force-extract)     FORCE_EXTRACT="yes"; shift ;;
            --clean)             KEEP_DOWNLOADS="no"; shift ;;
            --force-host)        FORCE_HOST="yes"; shift ;;
            --check)             CHECK_ONLY="yes"; shift ;;
            --list)              LIST_ONLY="yes"; shift ;;
            --dry-run)           DRY_RUN="yes"; shift ;;
            -y|--yes)            ASSUME_YES="yes"; shift ;;
            -h|--help)           usage; exit 0 ;;
            -V|--version)        printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
            --)                  shift; break ;;
            -*)                  die "unknown option: $1 (try --help)" ;;
            *)                   die "unexpected argument: $1 (try --help)" ;;
        esac
    done
}

validate_args() {
    if [ -n "$JETPACK" ]; then
        resolve_release "$JETPACK" \
            || die "unrecognised JetPack/L4T version '$JETPACK'. Supported: $SUPPORTED_JETPACKS"
    fi
    if [ -n "$DEVICE" ]; then
        [ -n "$(device_to_board "$DEVICE")" ] \
            || die "unrecognised --device '$DEVICE'. Use nano, nx, agx or agx-industrial."
    fi
    case "$STORAGE" in
        ""|nvme|usb|sd|emmc) : ;;
        *) die "unrecognised --storage '$STORAGE'. Use nvme, usb, sd or emmc." ;;
    esac
    case "$TARGET" in
        ""|internal|external) : ;;
        *) die "unrecognised --target '$TARGET'. Use internal or external." ;;
    esac
    [ -n "$(nvme_layout_xml "$NVME_LAYOUT")" ] \
        || die "unrecognised --nvme-layout '$NVME_LAYOUT'. Use default, ab, enc or ab-enc."
    if [ -n "$MASSFLASH" ]; then
        case "$MASSFLASH" in
            ''|*[!0-9]*) die "--massflash takes a positive integer" ;;
        esac
    fi
    if [ "$NO_FLASH" = "yes" ] && [ "$FLASH_ONLY" = "yes" ]; then
        die "--no-flash and --flash-only are mutually exclusive"
    fi
    if [ -n "$NEW_PASS" ] && [ -z "$NEW_USER" ]; then
        die "--password requires --user"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Host preflight
# ---------------------------------------------------------------------------
host_id() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s %s' "${ID:-unknown}" "${VERSION_ID:-unknown}"
    else
        printf 'unknown unknown'
    fi
}

check_host() {
    step "Checking the host"

    local os arch
    os="$(uname -s)"; arch="$(uname -m)"

    if [ "$os" != "Linux" ] || [ "$arch" != "x86_64" ]; then
        if [ "$FORCE_HOST" = "yes" ] || [ "$DRY_RUN" = "yes" ]; then
            warn "host is $os/$arch, not Linux/x86_64 — continuing anyway"
        else
            die "this host is $os/$arch. NVIDIA's flashing tools are x86_64 Linux
     binaries and cannot flash a Jetson from anywhere else. Run this on an
     Ubuntu x86_64 machine, or pass --force-host to override (or --dry-run
     to preview the commands)."
        fi
    else
        ok "host architecture: Linux $arch"
    fi

    local id ver
    set -- $(host_id); id="$1"; ver="$2"
    if [ "$id" = "ubuntu" ]; then
        case "$ver" in
            20.04|22.04|24.04) ok "host distribution: Ubuntu $ver" ;;
            *) warn "Ubuntu $ver is outside NVIDIA's tested set (20.04/22.04/24.04)" ;;
        esac
    elif [ "$os" = "Linux" ]; then
        warn "host is '$id', not Ubuntu — package installation may not work"
    fi

    if [ "$DRY_RUN" != "yes" ] && [ "$os" = "Linux" ]; then
        case "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1)" in
            0) warn "unprivileged user namespaces are disabled; some BSP steps may fail" ;;
        esac
    fi
}

check_space() {
    local need_gib avail_gib target="$1"
    need_gib="$(space_needed_gib)"
    [ -d "$target" ] || target="$(dirname "$target")"
    avail_gib="$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}')"
    if [ -z "$avail_gib" ]; then
        warn "could not determine free space on $target"
        return 0
    fi
    if [ "$avail_gib" -lt "$need_gib" ]; then
        warn "only ${avail_gib} GiB free on $target; JetPack $JP_VER wants about ${need_gib} GiB"
        confirm "Continue anyway?" || die "aborted: not enough disk space"
    else
        ok "free space: ${avail_gib} GiB (need about ${need_gib} GiB)"
    fi
}

require_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || die "sudo is required but not installed"
    if [ "$DRY_RUN" = "yes" ]; then
        SUDO="sudo"
        return 0
    fi
    log "Flashing needs root. Requesting sudo up front so it does not"
    log "interrupt a long download or a flash in progress."
    sudo -v || die "could not obtain sudo privileges"
    SUDO="sudo"
    # Refresh the sudo timestamp until this script exits.
    ( while true; do
          sleep 50
          kill -0 "$$" 2>/dev/null || exit 0
          sudo -n true 2>/dev/null || exit 0
      done ) &
    SUDO_KEEPALIVE_PID=$!
}

# ---------------------------------------------------------------------------
# Host dependencies
#
# Two layers: the packages this script itself needs to fetch and unpack the
# BSP, and the packages NVIDIA's flashing tools need. After the BSP is
# extracted we also run NVIDIA's own tools/l4t_flash_prerequisites.sh, which
# is authoritative and version-matched — this list just gets us that far and
# covers hosts where that script is incomplete.
# ---------------------------------------------------------------------------
readonly DEPS_FETCH="curl wget tar lbzip2 ca-certificates usbutils"
readonly DEPS_L4T="abootimg binutils bzip2 cpio device-tree-compiler dosfstools \
libxml2-utils lz4 nfs-kernel-server openssl python3 python3-yaml qemu-user-static \
rsync sshpass udev uuid-runtime whois xxd zstd bc"

pkg_installed() {
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -q '^installed$'
}

install_deps() {
    step "Installing host prerequisites"

    if [ "$SKIP_DEPS" = "yes" ]; then
        log "--skip-deps given; not touching host packages"
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        warn "apt-get not found; skipping package installation"
        warn "make sure these are present: $DEPS_FETCH $DEPS_L4T"
        return 0
    fi

    local missing="" p
    for p in $DEPS_FETCH $DEPS_L4T; do
        pkg_installed "$p" || missing="$missing $p"
    done
    # xxd moved out of vim-common on 22.04+; fall back if the package is absent.
    case " $missing " in
        *" xxd "*)
            if ! apt-cache show xxd >/dev/null 2>&1; then
                missing="$(printf '%s' "$missing" | sed 's/ xxd/ vim-common/')"
            fi ;;
    esac
    missing="${missing# }"

    if [ -z "$missing" ]; then
        ok "all host prerequisites already installed"
        return 0
    fi

    log "missing packages: $missing"
    run $SUDO apt-get update -qq || warn "apt-get update failed; using the existing package lists"
    # One batch first; if any single package is unavailable on this release,
    # retry individually so one bad name does not block the rest.
    if ! run env DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y $missing; then
        warn "batch install failed; retrying package by package"
        for p in $missing; do
            run env DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "$p" \
                || warn "could not install '$p' — continuing"
        done
    fi

    # apply_binaries.sh chroots into an aarch64 rootfs via binfmt_misc.
    if [ "$DRY_RUN" != "yes" ] && [ -d /proc/sys/fs/binfmt_misc ]; then
        if ! ls /proc/sys/fs/binfmt_misc 2>/dev/null | grep -qi 'aarch64\|qemu-aarch64'; then
            warn "no aarch64 binfmt handler registered; apply_binaries.sh may fail."
            warn "if it does, run: sudo systemctl restart systemd-binfmt"
        fi
    fi
    ok "host prerequisites ready"
}

# ---------------------------------------------------------------------------
# Recovery-mode detection
# ---------------------------------------------------------------------------
# Echoes "<pid> <family> <description>" for each Jetson found in recovery mode.
detect_recovery_devices() {
    command -v lsusb >/dev/null 2>&1 || return 0
    local pid info
    for pid in $(lsusb 2>/dev/null | sed -n 's/.*ID 0955:\([0-9a-fA-F]\{4\}\).*/\1/p'); do
        pid="$(printf '%s' "$pid" | tr 'A-Z' 'a-z')"
        info="$(pid_to_module "$pid")"
        if [ -n "$info" ]; then
            printf '%s %s %s\n' "$pid" "${info%%|*}" "${info#*|}"
        else
            printf '%s %s %s\n' "$pid" "unknown" "Unrecognised NVIDIA device (USB ID 0955:$pid)"
        fi
    done
}

recovery_help() {
    cat <<'__RECOVERY__'
  To put the board into Force Recovery Mode:

    Jetson Orin Nano / Orin NX developer kit
      1. Disconnect the power cable.
      2. Short the REC and GND pins on the 12-pin button header with a jumper.
      3. Reconnect power. (Leave the jumper on until flashing starts.)

    Jetson AGX Orin developer kit
      1. Power the kit off.
      2. Press and hold the Force Recovery button.
      3. Press and release the Power button.
      4. Release the Force Recovery button.
      Connect the host to the USB-C port next to the 40-pin header.

  Confirm with `lsusb` — you should see a device with ID 0955:xxxx (NVidia Corp).
__RECOVERY__
}

# ---------------------------------------------------------------------------
# Interactive prompts
# ---------------------------------------------------------------------------
interactive() { [ "$ASSUME_YES" != "yes" ] && [ -t 0 ]; }

confirm() {
    local prompt="$1" reply
    if ! interactive; then
        return 0
    fi
    while :; do
        printf '%s%s%s [Y/n] ' "$C_BLD" "$prompt" "$C_OFF"
        read -r reply || return 1
        case "$(printf '%s' "$reply" | tr 'A-Z' 'a-z')" in
            ''|y|yes) return 0 ;;
            n|no)     return 1 ;;
        esac
    done
}

# ask_choice <varname> <prompt> <default-index> <value:label> ...
ask_choice() {
    local __var="$1" prompt="$2" default="$3"; shift 3
    local n=0 reply item
    local values="" labels=""

    printf '\n%s%s%s\n' "$C_BLD" "$prompt" "$C_OFF"
    for item in "$@"; do
        n=$((n + 1))
        values="$values ${item%%:*}"
        printf '  %2d) %s\n' "$n" "${item#*:}"
    done

    while :; do
        printf '%sChoice [%s]:%s ' "$C_BLD" "$default" "$C_OFF"
        read -r reply || reply=""
        [ -z "$reply" ] && reply="$default"
        case "$reply" in
            ''|*[!0-9]*) printf '  enter a number between 1 and %d\n' "$n"; continue ;;
        esac
        if [ "$reply" -ge 1 ] && [ "$reply" -le "$n" ]; then
            set -- $values
            eval "$__var=\$$reply"
            return 0
        fi
        printf '  enter a number between 1 and %d\n' "$n"
    done
}

ask_value() {
    local __var="$1" prompt="$2" default="$3" reply
    printf '%s%s%s' "$C_BLD" "$prompt" "$C_OFF"
    [ -n "$default" ] && printf ' [%s]' "$default"
    printf ': '
    read -r reply || reply=""
    [ -z "$reply" ] && reply="$default"
    eval "$__var=\$reply"
}

ask_secret() {
    local __var="$1" prompt="$2" a b
    while :; do
        printf '%s%s%s: ' "$C_BLD" "$prompt" "$C_OFF"
        stty -echo 2>/dev/null || true
        read -r a || a=""
        stty echo 2>/dev/null || true
        printf '\n'
        printf '%sConfirm%s: ' "$C_BLD" "$C_OFF"
        stty -echo 2>/dev/null || true
        read -r b || b=""
        stty echo 2>/dev/null || true
        printf '\n'
        if [ -z "$a" ]; then
            printf '  password cannot be empty\n'
        elif [ "$a" != "$b" ]; then
            printf '  passwords did not match, try again\n'
        else
            eval "$__var=\$a"
            return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# Downloading
# ---------------------------------------------------------------------------
remote_size() {
    # A dry run must not touch the network.
    [ "$DRY_RUN" = "yes" ] && { printf '0'; return 0; }
    curl -sIL --retry 3 --retry-delay 2 --max-time 60 "$1" 2>/dev/null \
        | tr -d '\r' | tr 'A-Z' 'a-z' \
        | awk -F': *' '/^content-length:/ {v=$2} END {print v+0}'
}

local_size() {
    [ -f "$1" ] || { printf '0'; return 0; }
    wc -c < "$1" | tr -d ' '
}

download_file() {
    local url="$1" dest="$2" label="$3" want have

    want="$(remote_size "$url")"
    have="$(local_size "$dest")"

    if [ "$want" -gt 0 ] && [ "$have" = "$want" ]; then
        ok "$label already downloaded ($(human_size "$have"))"
        return 0
    fi
    if [ "$have" -gt 0 ]; then
        log "resuming $label at $(human_size "$have") of $(human_size "$want")"
    else
        log "downloading $label ($(human_size "$want"))"
    fi

    if [ "$DRY_RUN" = "yes" ]; then
        printf '%s  $%s curl -fL --retry 3 -C - -o %s %s\n' "$C_CYN" "$C_OFF" "$dest" "$url"
        return 0
    fi

    curl -fL --retry 5 --retry-delay 3 --retry-connrefused -C - \
         --progress-bar -o "$dest" "$url" \
        || die "download failed: $url"

    have="$(local_size "$dest")"
    if [ "$want" -gt 0 ] && [ "$have" != "$want" ]; then
        die "size mismatch for $label: got $have bytes, expected $want.
     Delete '$dest' and re-run."
    fi
    ok "$label downloaded ($(human_size "$have"))"
}

human_size() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b <= 0)         { printf "unknown"; exit }
        if (b >= 1073741824) { printf "%.1f GiB", b/1073741824; exit }
        if (b >= 1048576)    { printf "%.1f MiB", b/1048576; exit }
        printf "%d B", b
    }'
}

# ---------------------------------------------------------------------------
# BSP preparation
# ---------------------------------------------------------------------------
prepare_bsp() {
    local dl_dir="$WORKDIR/downloads"
    local build_root="$WORKDIR/jetpack-$JP_VER-l4t-$L4T_VER"
    local marker

    LFT="$build_root/Linux_for_Tegra"
    marker="$LFT/.jetson-flash-prepared"

    step "Preparing Jetson Linux $L4T_VER (JetPack $JP_VER)"

    if [ -f "$marker" ] && [ "$FORCE_EXTRACT" != "yes" ]; then
        ok "BSP already prepared at $LFT"
        log "pass --force-extract to rebuild it from scratch"
        return 0
    fi

    run mkdir -p "$dl_dir" "$build_root"
    check_space "$WORKDIR"

    download_file "$BSP_URL" "$dl_dir/$BSP_FILE" "driver package (BSP)"
    download_file "$RFS_URL" "$dl_dir/$RFS_FILE" "sample root filesystem"

    if [ -d "$LFT" ] && [ "$FORCE_EXTRACT" = "yes" ]; then
        log "removing previous build tree"
        run $SUDO rm -rf "$LFT"
    fi

    # lbzip2 turns a ~10 minute single-threaded decompress into ~1 minute.
    local tar_bz=""
    if command -v lbzip2 >/dev/null 2>&1; then
        tar_bz="--use-compress-program=lbzip2"
    fi

    log "extracting the driver package"
    run tar $tar_bz -xf "$dl_dir/$BSP_FILE" -C "$build_root"
    [ "$DRY_RUN" = "yes" ] || [ -d "$LFT" ] \
        || die "expected $LFT after extracting $BSP_FILE"

    log "extracting the sample root filesystem (needs root to preserve ownership)"
    run $SUDO mkdir -p "$LFT/rootfs"
    run $SUDO tar $tar_bz -xpf "$dl_dir/$RFS_FILE" -C "$LFT/rootfs"

    log "running NVIDIA's own host prerequisite script"
    if [ -x "$LFT/tools/l4t_flash_prerequisites.sh" ] || [ "$DRY_RUN" = "yes" ]; then
        run_in "$LFT" $SUDO ./tools/l4t_flash_prerequisites.sh
    else
        warn "tools/l4t_flash_prerequisites.sh not found in this BSP; skipping"
    fi

    log "applying NVIDIA binaries to the root filesystem"
    run_in "$LFT" $SUDO ./apply_binaries.sh

    [ "$DRY_RUN" = "yes" ] || $SUDO touch "$marker"
    ok "BSP ready at $LFT"
}

create_default_user() {
    [ -n "$NEW_USER" ] || return 0
    step "Pre-creating the first-boot user account"

    local tool="tools/l4t_create_default_user.sh"
    if [ ! -x "$LFT/$tool" ] && [ "$DRY_RUN" != "yes" ]; then
        warn "$tool not present in this BSP; the device will run oem-config on first boot"
        return 0
    fi

    set -- -u "$NEW_USER"
    [ -n "$NEW_PASS" ] && set -- "$@" -p "$NEW_PASS"
    [ -n "$NEW_HOST" ] && set -- "$@" -n "$NEW_HOST"
    [ "$AUTOLOGIN" = "yes" ] && set -- "$@" -a
    [ "$ACCEPT_LICENSE" = "yes" ] && set -- "$@" --accept-license

    run_in "$LFT" $SUDO "./$tool" "$@"
    ok "user '$NEW_USER' will exist on first boot"
}

# ---------------------------------------------------------------------------
# Configuration resolution
# ---------------------------------------------------------------------------
# Compare dotted versions as integers: 36.4.3 -> 36004003
ver_num() { printf '%s' "$1" | awk -F. '{printf "%d%03d%03d", $1, ($2==""?0:$2), ($3==""?0:$3)}'; }
l4t_at_least() { [ "$(ver_num "$L4T_VER")" -ge "$(ver_num "$1")" ]; }

choose_jetpack() {
    [ -n "$JP_VER" ] && return 0
    if ! interactive; then
        JETPACK="6.2.3"
        resolve_release "$JETPACK"
        log "no --jetpack given; defaulting to JetPack $JP_VER (Jetson Linux $L4T_VER)"
        return 0
    fi
    local pick
    ask_choice pick "Which JetPack release do you want to flash?" 5 \
        "6.1:JetPack 6.1   (Jetson Linux 36.4.0) — no SUPER support" \
        "6.2:JetPack 6.2   (Jetson Linux 36.4.3) — first release with SUPER mode" \
        "6.2.1:JetPack 6.2.1 (Jetson Linux 36.4.4)" \
        "6.2.2:JetPack 6.2.2 (Jetson Linux 36.5.0)" \
        "6.2.3:JetPack 6.2.3 (Jetson Linux 36.5.2) — latest JetPack 6, recommended" \
        "7.2:JetPack 7.2   (Jetson Linux 39.2.0) — first JetPack 7 with Orin support" \
        "7.2.1:JetPack 7.2.1 (Jetson Linux 39.2.1) — latest overall"
    JETPACK="$pick"
    resolve_release "$JETPACK" || die "internal error resolving $JETPACK"
}

choose_device() {
    [ -n "$BOARD" ] && return 0
    [ -n "$DEVICE" ] && return 0

    local found count line
    found="$(detect_recovery_devices)"
    count="$(printf '%s' "$found" | grep -c . || true)"

    if [ "$count" = "1" ]; then
        set -- $found
        local pid="$1" family="$2"
        line="$(printf '%s' "$found" | cut -d' ' -f3-)"
        if [ "$family" != "unknown" ]; then
            ok "detected on USB: $line"
            DEVICE="$family"
            if [ "$family" = "agx" ] && [ "$pid" = "7023" ] && interactive; then
                local pick
                ask_choice pick "That USB ID covers both AGX Orin variants. Which is it?" 1 \
                    "agx:Jetson AGX Orin developer kit (jetson-agx-orin-devkit)" \
                    "agx-industrial:Jetson AGX Orin Industrial (jetson-agx-orin-devkit-industrial)"
                DEVICE="$pick"
            fi
            return 0
        fi
        warn "found NVIDIA USB device 0955:$pid but it is not a known Orin module"
    elif [ "$count" -gt 1 ]; then
        warn "more than one Jetson is in recovery mode:"
        printf '%s\n' "$found" | sed 's/^/    /' >&2
        warn "connect only the board you want to flash, or pass --device explicitly"
    fi

    if ! interactive; then
        die "no Jetson detected in Force Recovery Mode and no --device given.
$(recovery_help)"
    fi

    local pick
    ask_choice pick "Which Jetson are you flashing?" 1 \
        "nano:Jetson Orin Nano developer kit (4GB or 8GB)" \
        "nx:Jetson Orin NX on the Orin Nano carrier (8GB or 16GB)" \
        "agx:Jetson AGX Orin developer kit" \
        "agx-industrial:Jetson AGX Orin Industrial"
    DEVICE="$pick"
}

choose_super() {
    # Only Orin Nano / Orin NX have SUPER configs.
    case "$DEVICE" in
        nano|nx) : ;;
        *)
            if [ "$SUPER_MODE" = "on" ] || [ "$SUPER_MODE" = "maxn" ]; then
                warn "SUPER configs apply to Orin Nano/NX only; ignoring for $DEVICE"
            fi
            SUPER_MODE="off"
            return 0 ;;
    esac

    if [ "$SUPER_MODE" = "on" ] || [ "$SUPER_MODE" = "maxn" ]; then
        l4t_at_least 36.4.3 || die "SUPER configs were introduced in JetPack 6.2 (Jetson Linux 36.4.3).
     JetPack $JP_VER ships Jetson Linux $L4T_VER, which has no
     jetson-orin-nano-devkit-super config. Choose JetPack 6.2 or newer, or
     drop --super."
        return 0
    fi
    [ -n "$SUPER_MODE" ] && return 0

    if ! l4t_at_least 36.4.3; then
        SUPER_MODE="off"
        return 0
    fi
    if ! interactive; then
        SUPER_MODE="on"
        log "no SUPER preference given; defaulting to the SUPER config"
        return 0
    fi

    local pick
    ask_choice pick "SUPER mode? It raises the power/clock ceiling on Orin Nano and NX." 1 \
        "on:SUPER — jetson-orin-nano-devkit-super (recommended: adds 25W and MAXN_SUPER)" \
        "maxn:SUPER MAXN — jetson-orin-nano-devkit-super-maxn (also raises EMC/scf/hub clocks)" \
        "off:Standard — jetson-orin-nano-devkit (original power profile)"
    SUPER_MODE="$pick"
}

resolve_board() {
    if [ -n "$BOARD" ]; then
        # --board was given explicitly; infer SUPER from its name so the
        # post-flash notes still mention nvpmodel.
        case "$BOARD" in
            *-super-maxn) SUPER_MODE="maxn" ;;
            *-super)      SUPER_MODE="on" ;;
        esac
        return 0
    fi
    BOARD="$(device_to_board "$DEVICE")"
    case "$SUPER_MODE" in
        on)   BOARD="${BOARD}-super" ;;
        maxn) BOARD="${BOARD}-super-maxn" ;;
    esac
}

choose_storage() {
    [ -n "$STORAGE" ] && return 0

    if is_agx_board "$BOARD"; then
        if ! interactive; then
            STORAGE="nvme"
            log "no --storage given; defaulting to nvme"
            return 0
        fi
        local pick
        ask_choice pick "Where should the root filesystem live?" 1 \
            "nvme:NVMe SSD  (/dev/nvme0n1 — recommended)" \
            "emmc:Internal eMMC (flashed with flash.sh)" \
            "usb:USB drive (/dev/sda)" \
            "sd:microSD card (/dev/mmcblk0)"
        STORAGE="$pick"
    else
        if ! interactive; then
            STORAGE="nvme"
            log "no --storage given; defaulting to nvme"
            return 0
        fi
        local pick
        ask_choice pick "Where should the root filesystem live?" 1 \
            "nvme:NVMe SSD  (/dev/nvme0n1 — recommended)" \
            "sd:microSD card (/dev/mmcblk0 — 64GB or larger)" \
            "usb:USB drive (/dev/sda — 64GB or larger)"
        STORAGE="$pick"
    fi
}

validate_combination() {
    if [ "$STORAGE" = "emmc" ] && ! is_agx_board "$BOARD"; then
        die "Orin Nano and Orin NX modules have no eMMC. Their bootloader lives in
     QSPI-NOR and the root filesystem must go to NVMe, USB or microSD.
     Use --storage nvme, usb or sd."
    fi
    if [ "$STORAGE" = "sd" ] && ! is_agx_board "$BOARD"; then
        warn "only the Orin Nano 8GB development module (P3767-0005) that ships in the"
        warn "developer kit has a microSD slot; production modules do not."
    fi
    case "$STORAGE" in
        usb|sd)
            if ! is_agx_board "$BOARD"; then
                log "note: NVIDIA requires 64GB or larger USB/microSD media on Orin Nano/NX"
            fi ;;
    esac
    return 0
}

collect_user_details() {
    interactive || return 0
    [ -n "$NEW_USER" ] && return 0

    printf '\n'
    if ! confirm "Pre-create a user account so the device skips the first-boot setup wizard?"; then
        return 0
    fi
    ask_value NEW_USER "  Username" "nvidia"
    ask_secret NEW_PASS "  Password for '$NEW_USER'"
    ask_value NEW_HOST "  Hostname" "$(printf '%s' "$BOARD" | sed 's/^jetson-//; s/-devkit.*//')"
    confirm "  Log in automatically at boot?" && AUTOLOGIN="yes"
    confirm "  Accept the NVIDIA end user licence agreement on the device's behalf?" \
        && ACCEPT_LICENSE="yes"
}

# ---------------------------------------------------------------------------
# Flash command construction
#
# Each branch below mirrors a command printed verbatim in the Developer Guide
# Quick Start for the matching release. See README.md for the citations.
# ---------------------------------------------------------------------------
FLASH_CMD=""
FLASH_ARGV=""

initrd_flash_path() {
    local top="l4t_initrd_flash.sh" nested="tools/kernel_flash/l4t_initrd_flash.sh"
    # Printed with a leading ./ so the command matches the Developer Guide and
    # is safe to copy-paste.
    # JetPack 7 documents the top-level wrapper; JetPack 6 documents the nested
    # one. Probe for both so an unexpected layout still works.
    if [ "$L4T_MAJOR" -ge 39 ]; then
        [ -f "$LFT/$top" ]    && { printf './%s' "$top"; return 0; }
        [ -f "$LFT/$nested" ] && { printf './%s' "$nested"; return 0; }
        printf './%s' "$top"
    else
        [ -f "$LFT/$nested" ] && { printf './%s' "$nested"; return 0; }
        [ -f "$LFT/$top" ]    && { printf './%s' "$top"; return 0; }
        printf './%s' "$nested"
    fi
}

partition_xml() {
    local xml
    xml="$(nvme_layout_xml "$NVME_LAYOUT")"
    if [ -n "$LFT" ] && [ -d "$LFT" ] && [ ! -f "$LFT/$xml" ]; then
        if [ -f "$LFT/tools/kernel_flash/flash_l4t_external.xml" ]; then
            warn "$xml not in this BSP; falling back to flash_l4t_external.xml"
            xml="tools/kernel_flash/flash_l4t_external.xml"
        else
            warn "$xml not found in $LFT — the flasher may reject it"
        fi
    fi
    printf '%s' "$xml"
}

should_erase_all() {
    if [ -n "$ERASE_ALL" ]; then
        [ "$ERASE_ALL" = "yes" ]
        return $?
    fi
    # JetPack 7's documented commands all pass --erase-all; JetPack 6's do not.
    [ "$L4T_MAJOR" -ge 39 ]
}

build_flash_command() {
    local dev xml initrd
    initrd="$(initrd_flash_path)"

    if [ "$STORAGE" != "emmc" ]; then
        dev="${EXTERNAL_DEVICE:-$(storage_to_device_node "$STORAGE")}"
    fi

    set --

    if [ "$STORAGE" = "emmc" ]; then
        # AGX Orin internal eMMC — the only path that still uses flash.sh.
        set -- ./flash.sh
        should_erase_all && set -- "$@" --erase-all
        set -- "$@" "$BOARD" "${TARGET:-internal}"

    elif [ "$L4T_MAJOR" -ge 39 ]; then
        # ---- JetPack 7.x (Jetson Linux 39.x) ----
        set -- "$initrd"
        if is_agx_board "$BOARD"; then
            xml="$(partition_xml)"
            set -- "$@" --external-device "$dev" -c "$xml"
        else
            # On r39 the Orin Nano configs already default to NVMe, so the
            # documented NVMe command passes neither --external-device nor -c.
            if [ "$STORAGE" != "nvme" ] || [ -n "$EXTERNAL_DEVICE" ]; then
                set -- "$@" --external-device "$dev"
            fi
            if [ "$NVME_LAYOUT" != "default" ]; then
                xml="$(partition_xml)"
                set -- "$@" -c "$xml"
            fi
        fi
        should_erase_all && set -- "$@" --erase-all
        [ "$SHOWLOGS" = "yes" ] && set -- "$@" --showlogs

    else
        # ---- JetPack 6.x (Jetson Linux 36.x) ----
        xml="$(partition_xml)"
        set -- "$initrd" --external-device "$dev" -c "$xml"
        if ! is_agx_board "$BOARD"; then
            # Orin Nano/NX have no eMMC: the bootloader goes to QSPI-NOR in the
            # same run, which is what the -p ... qspi.xml argument selects.
            set -- "$@" -p "-c bootloader/generic/cfg/flash_t234_qspi.xml"
        fi
        should_erase_all && set -- "$@" --erase-all
        [ "$SHOWLOGS" = "yes" ] && set -- "$@" --showlogs
        set -- "$@" --network usb0
    fi

    # Options common to every initrd-flash path.
    if [ "$STORAGE" != "emmc" ]; then
        [ -n "$ROOTFS_SIZE" ] && set -- "$@" -S "$ROOTFS_SIZE"
        [ -n "$MASSFLASH" ]   && set -- "$@" --massflash "$MASSFLASH"
        [ "$NO_FLASH" = "yes" ]   && set -- "$@" --no-flash
        [ "$FLASH_ONLY" = "yes" ] && set -- "$@" --flash-only
        [ -n "$EXTRA_FLASH_ARGS" ] && set -- "$@" $EXTRA_FLASH_ARGS

        # Target selector goes last. Orin Nano/NX flash QSPI (internal) plus an
        # external rootfs; AGX Orin puts the rootfs on a genuinely external disk.
        #
        # NOTE: the r39.2 Quick Start shows "internal" for the AGX Orin microSD
        # case while showing "external" for its NVMe and USB cases. That reads
        # as a copy-paste slip in the doc, so we use "external" consistently for
        # AGX external media. Override with --extra-flash-args if you disagree.
        if [ -n "$TARGET" ]; then
            set -- "$@" "$BOARD" "$TARGET"
        elif is_agx_board "$BOARD"; then
            set -- "$@" "$BOARD" external
        else
            set -- "$@" "$BOARD" internal
        fi
    else
        if [ -n "$ROOTFS_SIZE" ] || [ -n "$MASSFLASH" ] \
           || [ "$NO_FLASH" = "yes" ] || [ "$FLASH_ONLY" = "yes" ]; then
            warn "-S/--massflash/--no-flash/--flash-only do not apply to eMMC flashing; ignored"
        fi
    fi

    # Keep the real argv in an array so nothing is ever re-parsed by the shell.
    FLASH_ARGV=("$@")
    FLASH_CMD="$(show_cmd "$@")"
}

preflight_bsp_checks() {
    [ "$DRY_RUN" = "yes" ] && return 0
    [ -d "$LFT" ] || die "BSP directory missing: $LFT"

    if [ ! -f "$LFT/$BOARD.conf" ]; then
        err "board config '$BOARD.conf' is not in this BSP."
        if ls "$LFT"/jetson-orin-*.conf >/dev/null 2>&1; then
            err "configs available in Jetson Linux $L4T_VER:"
            ls "$LFT"/jetson-*.conf 2>/dev/null \
                | sed 's|.*/||; s|\.conf$||; s|^|      |' >&2
        fi
        die "pick one with --board, or choose a JetPack version that ships '$BOARD'."
    fi
    ok "board config found: $BOARD.conf"
}

confirm_and_flash() {
    step "Ready to flash"

    cat <<__SUMMARY__
  JetPack        : $JP_VER  (Jetson Linux $L4T_VER)
  Board config   : $BOARD
  Root filesystem: $(describe_storage)
  Work directory : $LFT
__SUMMARY__
    if [ -n "$NEW_USER" ]; then
        printf '  First-boot user: %s%s%s\n' "$NEW_USER" \
            "$([ -n "$NEW_HOST" ] && printf ' on host %s' "$NEW_HOST")" \
            "$([ "$AUTOLOGIN" = yes ] && printf ' (autologin)')"
    fi
    printf '\n  Command:\n    cd %s\n    sudo %s\n\n' "$LFT" "$FLASH_CMD"

    if [ "$NO_FLASH" != "yes" ] && [ "$STORAGE" != "emmc" ]; then
        warn "this erases the target media on the Jetson. It cannot be undone."
    fi

    if ! confirm "Start flashing now?"; then
        log "aborted at your request; nothing was flashed"
        log "the prepared BSP is kept at $LFT"
        exit 0
    fi

    step "Flashing — this typically takes 10 to 30 minutes"
    log "do not disconnect USB or power during this step"
    [ -n "$LOGFILE" ] && log "log: $LOGFILE"

    if [ "$DRY_RUN" = "yes" ]; then
        printf '%s  $%s cd %s && sudo %s\n' "$C_CYN" "$C_OFF" "$LFT" "$FLASH_CMD"
        ok "dry run complete; nothing was downloaded, changed or flashed"
        return 0
    fi

    local rc=0
    if [ -n "$LOGFILE" ]; then
        ( cd "$LFT" && $SUDO "${FLASH_ARGV[@]}" ) 2>&1 | tee -a "$LOGFILE" || rc=$?
    else
        ( cd "$LFT" && $SUDO "${FLASH_ARGV[@]}" ) || rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        err "flashing failed (exit $rc)"
        printf '%s\n' "$(flash_troubleshooting)" >&2
        exit "$rc"
    fi
    ok "flashing completed"
}

describe_storage() {
    case "$STORAGE" in
        nvme) printf 'NVMe SSD (%s)' "${EXTERNAL_DEVICE:-nvme0n1p1}" ;;
        usb)  printf 'USB drive (%s)' "${EXTERNAL_DEVICE:-sda1}" ;;
        sd)   printf 'microSD card (%s)' "${EXTERNAL_DEVICE:-mmcblk0p1}" ;;
        emmc) printf 'internal eMMC' ;;
        *)    printf '%s' "$STORAGE" ;;
    esac
}

flash_troubleshooting() {
    cat <<'__TROUBLE__'

  Common causes:
    * The board left recovery mode. Re-enter it and try again; on the Orin
      Nano kit the REC-GND jumper must be in place when power is applied.
    * A USB hub or a long/charge-only cable. Connect the host directly with a
      known-good data cable.
    * ModemManager grabbing the USB device mid-flash:
        sudo systemctl stop ModemManager
    * Not enough free disk space on the host for the staged images.
    * Target media too small — NVIDIA requires 64GB or larger for USB/microSD
      on Orin Nano and Orin NX.

  Detailed logs from NVIDIA's flasher are under:
    <workdir>/Linux_for_Tegra/tools/kernel_flash/
__TROUBLE__
}

post_flash_notes() {
    step "Next steps"
    cat <<__NEXT__
  The Jetson reboots on its own when flashing finishes.

  In the UEFI boot menu, select the media you just flashed
  ($(describe_storage)) if it is not already first in the boot order.
__NEXT__

    if [ -z "$NEW_USER" ]; then
        printf '  Follow the on-screen setup wizard to create your user account.\n'
    else
        printf "  Log in as '%s'.\n" "$NEW_USER"
    fi

    case "$SUPER_MODE" in
        on|maxn)
            cat <<'__SUPER__'

  SUPER mode is available on this image. After first boot:
      sudo nvpmodel -q                 # show the current mode
      sudo nvpmodel -m 2               # MAXN_SUPER on Orin Nano 4GB / 8GB
      sudo nvpmodel -m 0               # MAXN_SUPER on Orin NX 8GB / 16GB
      sudo jetson_clocks               # pin clocks to their maximum
  A reboot may be required for the mode change to take effect. MAXN_SUPER is
  uncapped, so make sure the board has adequate cooling and a supply that can
  hold up under the higher draw.
__SUPER__
            ;;
    esac

    cat <<'__JETPACK__'

  To add the CUDA/cuDNN/TensorRT stack, run this on the Jetson itself:
      sudo apt update && sudo apt install nvidia-jetpack

  Handy on-device monitoring:
      sudo pip3 install jetson-stats && sudo jtop
__JETPACK__
}

# ---------------------------------------------------------------------------
# --check: diagnose the host and the attached board
# ---------------------------------------------------------------------------
doctor() {
    # A diagnostic must never block waiting for an answer.
    ASSUME_YES="yes"
    check_host

    step "Checking tools"
    local t missing=0
    for t in curl tar lsusb dpkg-query awk sed; do
        if command -v "$t" >/dev/null 2>&1; then
            ok "$t"
        else
            err "$t is missing"
            missing=$((missing + 1))
        fi
    done
    if command -v lbzip2 >/dev/null 2>&1; then
        ok "lbzip2 (parallel decompression)"
    else
        warn "lbzip2 not installed — extracting the BSP will be several times slower"
    fi

    step "Checking host packages"
    if ! command -v dpkg-query >/dev/null 2>&1; then
        warn "dpkg-query unavailable; cannot check for Debian packages on this host"
    else
        local p absent=""
        for p in $DEPS_FETCH $DEPS_L4T; do
            pkg_installed "$p" || absent="$absent $p"
        done
        if [ -z "$absent" ]; then
            ok "all prerequisites installed"
        else
            warn "not installed:${absent}"
            log "run '$SCRIPT_NAME --deps-only' to install them"
        fi
    fi

    step "Checking workspace"
    log "work directory: $WORKDIR"
    if [ -d "$WORKDIR" ]; then
        check_space "$WORKDIR"
        local d
        for d in "$WORKDIR"/jetpack-*; do
            [ -d "$d/Linux_for_Tegra" ] || continue
            if [ -f "$d/Linux_for_Tegra/.jetson-flash-prepared" ]; then
                ok "prepared BSP: $d"
            else
                warn "incomplete BSP: $d (re-run with --force-extract)"
            fi
        done
    else
        log "not created yet"
    fi

    step "Checking for a Jetson in Force Recovery Mode"
    local found
    found="$(detect_recovery_devices)"
    if [ -n "$found" ]; then
        printf '%s\n' "$found" | while read -r pid family desc; do
            ok "0955:$pid — $desc  [--device $family]"
        done
    else
        warn "no Jetson found in recovery mode"
        recovery_help
    fi

    step "Checking network access to NVIDIA"
    local code
    code="$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 20 \
        "$NV_DL/l4t/r36_release_v4.3/release/Jetson_Linux_r36.4.3_aarch64.tbz2" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then
        ok "developer.nvidia.com reachable"
    else
        warn "could not reach the NVIDIA download server (HTTP ${code:-none})"
    fi

    [ "$missing" -eq 0 ] || return 1
    return 0
}

setup_logging() {
    [ "$DRY_RUN" = "yes" ] && return 0
    local dir="$WORKDIR/logs"
    mkdir -p "$dir" 2>/dev/null || return 0
    LOGFILE="$dir/flash-$(date +%Y%m%d-%H%M%S).log"
    : > "$LOGFILE" 2>/dev/null || { LOGFILE=""; return 0; }
    {
        printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        printf 'date    : %s\n' "$(date)"
        printf 'host    : %s %s\n' "$(uname -srm)" "$(host_id)"
        printf 'jetpack : %s (L4T %s)\n' "$JP_VER" "$L4T_VER"
        printf 'board   : %s\n' "$BOARD"
        printf 'storage : %s\n' "$STORAGE"
        printf '\n'
    } >> "$LOGFILE"
}

banner() {
    printf '%s\n' "$C_BLD$C_CYN"
    cat <<'__BANNER__'
  ___      _                    ___ _         _
 |_  |___ | |_ ___ ___ ___ ___ | __| |__ _ __| |_
   | / -_)|  _|_ -| . |   |___|| _|| / _` (_-<   |
 |___\___| \__|___|___|_|_|    |_| |_\__,_/__/_|_|
__BANNER__
    printf '%s' "$C_OFF"
    printf '  Jetson Orin flashing tool %s\n' "$SCRIPT_VERSION"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    validate_args

    if [ "$LIST_ONLY" = "yes" ]; then
        print_matrix
        exit 0
    fi

    interactive && banner

    if [ "$CHECK_ONLY" = "yes" ]; then
        local rc=0
        doctor || rc=$?
        exit "$rc"
    fi

    check_host

    if [ "$DEPS_ONLY" = "yes" ]; then
        require_sudo
        install_deps
        ok "prerequisites installed; exiting because --deps-only was given"
        exit 0
    fi

    # Work out exactly what we are building before doing anything expensive.
    step "Choosing what to flash"
    choose_jetpack
    choose_device
    choose_super
    resolve_board
    choose_storage
    validate_combination
    collect_user_details

    ok "JetPack $JP_VER (Jetson Linux $L4T_VER), board '$BOARD', rootfs on $(describe_storage)"

    setup_logging
    require_sudo
    install_deps
    prepare_bsp
    create_default_user

    preflight_bsp_checks
    build_flash_command

    # Confirm the board really is in recovery mode before we commit.
    if [ "$NO_FLASH" != "yes" ] && [ "$DRY_RUN" != "yes" ]; then
        if [ -z "$(detect_recovery_devices)" ]; then
            warn "no Jetson is currently in Force Recovery Mode."
            recovery_help
            if interactive; then
                confirm "Continue anyway?" || die "aborted: board not in recovery mode"
            else
                die "aborted: board not in recovery mode (put it in recovery and re-run)"
            fi
        fi
    fi

    confirm_and_flash

    if [ "$KEEP_DOWNLOADS" = "no" ] && [ "$DRY_RUN" != "yes" ]; then
        log "removing downloaded tarballs (--clean)"
        rm -f "$WORKDIR/downloads/$BSP_FILE" "$WORKDIR/downloads/$RFS_FILE"
    fi

    if [ "$NO_FLASH" = "yes" ]; then
        step "Images built"
        log "no board was touched. Flash them later with:"
        log "  cd $LFT && sudo $(initrd_flash_path) --flash-only"
    else
        post_flash_notes
    fi
}

main "$@"
