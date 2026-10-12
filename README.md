# OpenWrt for the ZTE ZXHN E2631 (Sanechips ZX279128S)

Overlay-only repo: it carries the E2631 board files and CI, not an OpenWrt tree.
The base is the sanechips target from openwrt/openwrt#25469, pinned to a SHA on
our own fork so a force-push upstream cannot break the build.

    git clone --branch pr-zte-zxhn-h3600 https://github.com/Zlion-Y/openwrt-sanechips-base openwrt
    git -C openwrt checkout db8b8d4130457dbe46558a7cea872dd2dae539e6
    ./apply.sh openwrt

Images are built by .github/workflows/build.yml (no local compiler on this
workstation). Packaging into the vendor upgrade format happens locally with
tools/mkfactory.mjs, because the official package used as the version-header
template is not uploaded here.

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
