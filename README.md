# OpenWrt for the ZTE ZXHN E2631 (Sanechips ZX279128S)

Overlay-only repo: it carries the E2631 board files and CI, not an OpenWrt tree.
The base is the sanechips target from openwrt/openwrt#25469, pinned to a SHA on
our own fork so a force-push upstream cannot break the build.

    git clone --branch pr-zte-zxhn-h3600 https://github.com/Zlion-Y/openwrt-sanechips-base openwrt
    git -C openwrt checkout db8b8d4130457dbe46558a7cea872dd2dae539e6
    ./apply.sh openwrt

Images are built by .github/workflows/build.yml, or locally inside WSL with
wsl/build.sh (see below). Packaging into the vendor upgrade format happens on
the Windows side with tools/mkfactory.mjs, because the official package used as
the version-header template is not uploaded here.

Three screens run before the forty-minute build is allowed to be the test:
`tools/dts_lint.mjs` resolves the board file's includes, `&labels` and
dt-binding macros against the kernel patches and the fetched headers; the
slot tool is compiled natively with `-Werror` and has to accept a synthesized
package and reject one byte-flipped copy; and `tools/verify_img.mjs` checks
the finished image for the things that stop a boot - `root=` against the
partition order the dtb really creates, built-in flash/squashfs/jffs2
drivers, the forced command line, USB and watchdog staying disabled,
soft-float, and the root filesystem's package list.

What is deliberately different from the H3600 board file:

* one WAN + three LAN, all four on the integrated GbE PHYs - no external PHY
* 256 MiB RAM, not 512
* whole-image A/B slots (0x700000 / 0x2300000, 28 MiB each) instead of a
  4 MiB kernel partition plus UBI
* no USB: the vendor kernel has no USB at all, and probing the controller on
  boards where it is not populated reboots the SoC
* soft-float userspace: this SoC implements no VFP, so CONFIG_VFP must stay off
* JFFS2 clean markers go in the data area, not the OOB (patches 029 and 030):
  SPI-NAND with on-die ECC regenerates page ECC on every program, so a page
  written twice comes back uncorrectable. Without this the overlay fails to
  remount and the box is stuck on a read-only root.
* the kernel command line is compiled in and CONFIG_CMDLINE_FORCE is on: the
  vendor U-Boot passes `root=/dev/mtdblock8 rootfstype=jffs2 init=/bin/sh`,
  which names the vendor layout and would replace PID 1 with a shell.

The two config edits above are per-target, so a tree that has been overlaid here
builds the E2631, not the H3600.

## Building it inside WSL

The Windows side of this machine has no cross toolchain, WSL does, and
`wsl/build.sh` runs the same steps CI does against `~/openwrt` with this repo at
`~/e2631`. What differs is the network: no proxy here, and the mirrors that
answer throttle per connection (kernel.org 73 KB/s, sources.cdn.openwrt.org
25 KB/s, sources.openwrt.org 14 KB/s, musl.libc.org nothing at all inside a 12 s
probe). Three things keep that from owning the build:

* `wsl/segdl.sh` fetches every distfile as eight parallel byte ranges and is
  wired in through `DOWNLOAD_TOOL_CUSTOM` - the only hook scripts/download.pl
  offers, since its select_tool() prefers curl and never reaches aria2c. The cap
  is per connection rather than per host, so linux-6.18.55.tar.xz (147 MiB)
  arrived in about three minutes at ~288 KB/s aggregate, and its sha256 matched
  the one in the download.pl command line, so the result is byte-exact rather
  than merely fast. A server that answers a range request with 200 and the whole
  file (mirrors.huaweicloud.com does) falls back to one connection, otherwise
  every worker would receive the same bytes.
* `CURL_OPTIONS="--speed-limit 20000 --speed-time 20"` gives curl a transfer
  watchdog, which OpenWrt does not set by default, so a mirror that accepts the
  connection and sends nothing fails over instead of blocking forever. A
  finished toolchain once sat for five minutes on the 1 MiB musl tarball.
* `wsl/parget.sh <url> <dl/name> [conns] [sha256]` is the same trick by hand,
  for a file that has to land before the build is restarted.

`make download` is deliberately not run up front: it walks every package in the
tree, so it was fetching broadcom-wl and libwebsockets - neither of which this
build selects - while the selected packages waited.

`wsl/collect.sh <out-dir>` then lays the build out the way the CI artifact does
(`kernel` / `root` / `e2631.dtb` / `config-6.18` / `e2631-fwslot`), which is
what `node tools/release.mjs --dir <out-dir>` packs and screens. The Windows
drives are mounted inside the distro, so nothing has to be piped over stdio.
`wsl/INDEX.md` groups the other scripts in there (build path / patch generators /
witnesses / probes) so the file count does not hide which ones to run.

## Status on the real board (2026-10-14, slot 1 = `e2631-openwrt-gen1.bin`)

| | |
|---|---|
| flash through the vendor `supgrade.html` page | **works** - the page accepted the package as-is, wrote slot 1, serial went 33 -> 34 on its own, and rebooted into our OpenWrt |
| switch back to the vendor system from OpenWrt | **works** - `e2631-fwslot switch` + `reboot`, also reachable from failsafe |
| LuCI (Argon theme), `reboot`, the three-colour LED | **work** |
| Ethernet | link trains at 1 Gbps, but throughput plateaus at ~305 Mbit/s in and ~190 Mbit/s out - the driver has no checksum/TSO/SG/RSS offload and one RX queue, and all of that work lands on CPU0 even though both cores are online |
| Wi-Fi (MT7916) | **usable, not stable, off by default** - see below |

The radio does not come up unless `/etc/e2631-wifi-autoload` exists or someone runs
`/sbin/e2631-wifi-on 0`. That is a deliberate choice, not a workaround: with the driver
loaded from `rc.d`, a failed experiment cost the ability to get back into the box.
Everything up to "AP beaming, monitor interface, air RX" has been verified alive on this
board. Two things have not: the **first firmware download after a power cycle** succeeds on
roughly one attempt in three (three cold boots on this exact image: hung, worked, hung),
and a **client associating** still hard-hangs the machine, silently, with no AER record and
no oops. Both are documented with their sample data in `docs/02-...md` section P.

## What lives outside this repo

The workspace root (`D:\AI\Qoder\E2631-OpenWRT`) holds the parts that are not build inputs
and so are not in here: `docs/` (the two working documents, Chinese, with every offset and
log line behind the conclusions), `device/` (board-side helper scripts and the vendor-side
flash plans), `tools/` (Windows-side: `release.mjs`, `stage.mjs`, serial/telnet/ssh drivers),
`out/` (every artifact and log, including the images), and the reference clones.

Two sibling repos of ours are related. `Zlion-Y/e2631-mainline-zx279128s` (mainline
Linux port) stays a separate effort - it is still where the real "this SoC boots"
evidence comes from. `Zlion-Y/e2631-openwrt`, the stage-1 initramfs scaffold, has
been folded in here: its history is the `stage1-scaffold` branch
(`git log --oneline stage1-scaffold`), and `tools/PROBE.md` - the list of unknowns
the first board file was written against - now lives on `main` with a status table
saying which of those unknowns a flashed board closed and which it did not.
Everything else on that branch is an older copy of what is here: its board DTS,
`apply.sh` and seed config predate the slot geometry, the nvmem MAC wiring and the
JFFS2 patches, and its `tools/*.py` screens were rewritten as `.mjs` because this
machine has no usable python.
