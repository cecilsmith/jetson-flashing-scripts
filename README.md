# jetson-flashing-scripts

A one-stop shop for flashing the Jetson Orin Nano / Orin NX / AGX Orin series boards.

[`flash-jetson.sh`](flash-jetson.sh) takes an Ubuntu x86_64 host from nothing to a
flashed Jetson: it installs every host prerequisite, downloads the matching Jetson
Linux BSP and sample root filesystem, assembles and patches the rootfs, and runs the
correct flash command for your board, JetPack version and target media.

It is interactive by default and fully scriptable via flags.

```bash
git clone https://github.com/cecilsmith/jetson-flashing-scripts.git
cd jetson-flashing-scripts
./flash-jetson.sh
```

## What it handles

| | |
|---|---|
| **JetPack** | 6.1, 6.2, 6.2.1, 6.2.2, 6.2.3, 7.2, 7.2.1 |
| **Boards** | Orin Nano devkit, Orin NX (on the Nano carrier), AGX Orin devkit, AGX Orin Industrial |
| **Media** | NVMe, USB, microSD, internal eMMC (AGX only) |
| **SUPER** | `-super` and `-super-maxn` configs — Orin Nano/NX from JetPack 6.2, AGX Orin from 7.2 |
| **Layouts** | default, redundant A/B rootfs, encrypted rootfs, A/B + encrypted |
| **Extras** | pre-created first-boot user, `--massflash`, build-only / flash-only, custom rootfs size, `--erase-all` |

## Examples

```bash
# Guided — asks which JetPack, board, storage and whether you want SUPER mode
./flash-jetson.sh
```

```bash
# Orin Nano Super devkit, JetPack 6.2, onto NVMe, no prompts
./flash-jetson.sh -j 6.2 -d nano --super -s nvme -y
```

```bash
# Orin NX to NVMe on the latest JetPack 6, with the first-boot wizard skipped
./flash-jetson.sh -j 6.2.3 -d nx --super -s nvme \
    -u nvidia -p nvidia -n orin-nx --accept-license -y
```

```bash
# AGX Orin devkit to its internal eMMC on JetPack 7.2
./flash-jetson.sh -j 7.2 -d agx -s emmc -y
```

```bash
# Print every command that would run, without downloading or flashing anything
./flash-jetson.sh -j 6.2 -d nano --super -s sd -y --dry-run
```

Two more modes worth knowing:

```bash
./flash-jetson.sh --check
```

diagnoses the host — architecture, missing packages, free space, whether a Jetson is
visible in recovery mode, and whether NVIDIA's download server is reachable.

```bash
./flash-jetson.sh --list
```

prints the supported version/board matrix. `--help` documents every flag.

## Force Recovery Mode

The board has to be in Force Recovery Mode before it can be flashed. Nothing on the
host can do this for you — it is a hardware state.

### Orin Nano / Orin NX developer kit

The **button header** is the 12-pin header on the carrier board, near the front edge
underneath the module. **Pin 9 is `FC_REC`, pin 10 is `GND`.**

If the board is powered off:

1. Disconnect the DC power plug.
2. Place a jumper across pins **9 and 10** of the button header.
3. Reconnect power. The kit powers on automatically, straight into recovery mode.

If the board already boots into Linux, this is much easier — no jumper needed:

```bash
sudo reboot --force forced-recovery
```

If it is powered on but you cannot log in, jumper pins 9–10, then briefly short pins
**7 and 8** to reset it.

Connect the host to the devkit's **USB-C** port.

### AGX Orin developer kit

1. Power the kit off.
2. Press and hold the **Force Recovery** button.
3. Press and release the **Power** button.
4. Release the Force Recovery button.

Connect the host to the USB-C port next to the 40-pin header.

### Confirming it worked

```bash
lsusb | grep 0955
```

You want an `ID 0955:<nnnn>` entry — `7523` is Orin Nano 8GB, `7623` Orin Nano 4GB,
`7323`/`7423` Orin NX 16GB/8GB, `7023`/`7223` AGX Orin. `./flash-jetson.sh --check`
does this for you and names the module it finds.

> **Remove the jumper once the host has detected the board.** If you leave it in, the
> Jetson re-enters recovery mode when it reboots after flashing, instead of booting
> the system you just installed. This is the single most common "it flashed fine but
> won't boot" report.

Use a known-good USB-C **data** cable, straight into the host — not through a hub, and
not a charge-only cable.

## Release matrix

Board configs and download URLs were each verified against NVIDIA's servers rather
than derived from a pattern — NVIDIA is inconsistent about capitalisation and about
`release/` vs `releases/` in these paths.

| JetPack | Jetson Linux | Notes |
|---|---|---|
| 6.1 | 36.4.0 | No SUPER configs |
| 6.2 | 36.4.3 | First release with SUPER / MAXN_SUPER |
| 6.2.1 | 36.4.4 | |
| 6.2.2 | 36.5.0 | |
| 6.2.3 | 36.5.2 | Latest JetPack 6 |
| 7.2 | 39.2.0 | First JetPack 7 release that supports Orin |
| 7.2.1 | 39.2.1 | Latest |

**JetPack 7.0 and 7.1 (Jetson Linux 38.x) are Jetson AGX Thor only** and have no Orin
support at all. The script rejects them with an explanation rather than downloading
2 GB of BSP that cannot flash your board.

## Commands it generates

Every command below is reproduced verbatim from the NVIDIA Developer Guide Quick
Start for that release. Run with `--dry-run` to see the exact command for your
configuration before committing to it.

**JetPack 6.x — Orin Nano / Orin NX.** These modules have no eMMC: the bootloader
goes to QSPI-NOR and the rootfs to external media in a single run, which is what the
`-p ... flash_t234_qspi.xml` argument and the `internal` target select.

```bash
sudo ./tools/kernel_flash/l4t_initrd_flash.sh --external-device nvme0n1p1 \
  -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
  --erase-all --showlogs --network usb0 jetson-orin-nano-devkit-super internal
```

`--erase-all` appears here only from JetPack 6.2.2 (Jetson Linux 36.5) onward —
see the table below.

**JetPack 6.x — AGX Orin to external media:**

```bash
sudo ./tools/kernel_flash/l4t_initrd_flash.sh --external-device nvme0n1p1 \
  -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
  --showlogs --network usb0 jetson-agx-orin-devkit external
```

**JetPack 7.x — Orin Nano / Orin NX.** On r39 the Orin Nano configs already default
to NVMe, so the NVMe command passes neither `--external-device` nor `-c`:

```bash
sudo ./l4t_initrd_flash.sh --erase-all jetson-orin-nano-devkit-super internal
```

**AGX Orin internal eMMC** is the one remaining path that still uses `flash.sh`:

```bash
sudo ./flash.sh jetson-agx-orin-devkit internal            # JetPack 6
sudo ./flash.sh --erase-all jetson-agx-orin-devkit internal # JetPack 7
```

### `--erase-all` defaults

NVIDIA changed this mid-series, so the default is per-release *and* per-board,
matching each release's own documented command:

| Jetson Linux | Orin Nano / NX | AGX Orin |
|---|---|---|
| 36.4.0 / 36.4.3 / 36.4.4 | off | off |
| 36.5 / 36.5.2 | **on** | off |
| 39.2 / 39.2.1 | **on** | **on** (including `flash.sh`) |

`--erase-all` and `--no-erase-all` override it either way.

### One deliberate deviation from the docs

The r39.2 and r39.2.1 Quick Starts show `internal` as the target for the **AGX Orin
+ microSD** case while showing `external` for the AGX Orin NVMe and USB cases; every
r36 page shows `external` for all three. That reads as a copy-paste slip in the newer
doc, so this script uses `external` consistently for AGX external media. If you want
the literal documented behaviour, `--target` overrides the positional target:

```bash
./flash-jetson.sh -j 7.2 -d agx -s sd --target internal
```

Everything else matches the documentation exactly: the generated commands were
diffed token-by-token against every command on the r36.4.3, r36.4.4, r36.5, r36.5.2,
r39.2 and r39.2.1 Quick Start pages.

## SUPER mode

A board exposes the uncapped power mode **only if it was flashed with a SUPER
config** — it cannot be enabled later without reflashing. Which releases ship one
depends on the board:

| Board | SUPER config from | Config name |
|---|---|---|
| Orin Nano / Orin NX | Jetson Linux 36.4.3 (JetPack 6.2) | `jetson-orin-nano-devkit-super` |
| AGX Orin | Jetson Linux 39.2 (JetPack 7.2) | `jetson-agx-orin-devkit-super` |

Asking for `--super` on a release that has no such config — `-j 6.1`, or AGX on any
JetPack 6 — is rejected up front rather than failing halfway through a flash.

- `--super` → the `-super` config
- `--super-maxn` → the `-super-maxn` config, which additionally raises the
  EMC / scf / hub clock ceilings (EMC 3200 MHz and scf/hub 1067 MHz, versus 3199 MHz
  and 933 MHz)

Orin Nano and Orin NX default to SUPER when you do not say otherwise. AGX Orin does
not: its SUPER configs only appeared in r39.2 and the r39.2.0 Quick Start still
documents the plain config, so you have to ask for it.

After first boot:

```bash
sudo nvpmodel -q      # show the current mode
sudo nvpmodel -m 2    # MAXN_SUPER on Orin Nano 4GB / 8GB
sudo nvpmodel -m 0    # MAXN_SUPER on Orin NX 8GB / 16GB
sudo jetson_clocks    # pin clocks to their maximum
```

A reboot may be required. MAXN_SUPER is uncapped, so make sure the board has adequate
cooling and a power supply that holds up under the higher draw.

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04 on **x86_64**. NVIDIA's flashing tools are x86_64 Linux
  binaries; they cannot flash a Jetson from macOS, from a Jetson, or from any other
  aarch64 host. `--dry-run` works anywhere.
- About 60 GB free for JetPack 6, 80 GB for JetPack 7.
- `sudo`. The script asks once up front and keeps the timestamp alive so it never
  stalls mid-flash waiting for a password.
- The board in Force Recovery Mode, connected over USB. `--check` confirms this.

Everything else — `qemu-user-static`, `lbzip2`, `device-tree-compiler`,
`nfs-kernel-server`, `xmlstarlet` and the rest — is installed for you. The package
list mirrors NVIDIA's own `tools/l4t_flash_prerequisites.sh`, and after extracting
the BSP the script runs that script too, since it is version-matched and
authoritative.

## Notes

- **Re-runs are cheap.** Downloads resume and are size-checked against the server, and
  a prepared BSP is reused. `--force-extract` rebuilds from scratch.
- **Passwords** given with `-p` are masked in all terminal output and logs, but are
  still visible in `ps` while `l4t_create_default_user.sh` runs. Omit `-p` to be
  prompted instead, with echo disabled.
- **Logs** land in `<workdir>/logs/`. The default workdir is `~/jetson-flash`,
  overridable with `-w` or `$JETSON_FLASH_WORKDIR`.
- **USB/microSD media must be 64 GB or larger** on Orin Nano and Orin NX.
- Only the Orin Nano 8GB *development* module (P3767-0005), the one in the developer
  kit, has a microSD slot. Production modules do not.
- After flashing, select the media you flashed in the UEFI boot menu if it is not
  already first in the boot order.

## Troubleshooting

If a flash fails, the script prints the usual suspects. The most common are a board
that dropped out of recovery mode (on the Orin Nano kit the REC–GND jumper must be in
place *when power is applied*), a USB hub or charge-only cable between host and board,
and `ModemManager` grabbing the USB device mid-flash:

```bash
sudo systemctl stop ModemManager
```

The other one that catches people out is `ufw`. The initrd flasher serves the root
filesystem to the board over NFS, so it refuses to start when the firewall is active
without a rule for port 2049 — it aborts with *"NFS port is blocked by UFW"* before
touching the board. `--check` now flags this, and so does the pre-flash preflight:

```bash
sudo ufw allow nfs
```

A connected VPN can break the same NFS export; disconnect it before flashing.

NVIDIA's own detailed logs are under `<workdir>/.../Linux_for_Tegra/initrdlog/`.

## Sources

- [Jetson Linux Developer Guide — Quick Start (r36.4.3 / JetPack 6.2)](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/IN/QuickStart.html)
- [Jetson Linux Developer Guide — Quick Start (r36.5.2 / JetPack 6.2.3)](https://docs.nvidia.com/jetson/archives/r36.5.2/DeveloperGuide/IN/QuickStart.html)
- [Jetson Linux Developer Guide — Quick Start (r39.2 / JetPack 7.2)](https://docs.nvidia.com/jetson/archives/r39.2/DeveloperGuide/IN/QuickStart.html)
- [Flashing Support — `l4t_initrd_flash.sh` options and partition layouts](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport.html)
- [Supported Modes and Power Efficiency — SUPER / MAXN_SUPER](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/PlatformPowerAndPerformance/JetsonOrinNanoSeriesJetsonOrinNxSeriesAndJetsonAgxOrinSeries.html)
- [JetPack SDK archive — JetPack ↔ Jetson Linux version mapping](https://developer.nvidia.com/embedded/jetpack-archive)
