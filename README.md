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

What is deliberately different from the H3600 board file:

* one WAN + three LAN, all four on the integrated GbE PHYs - no external PHY
* 256 MiB RAM, not 512
* whole-image A/B slots (0x700000 / 0x2300000, 28 MiB each) instead of a
  4 MiB kernel partition plus UBI
* no USB: the vendor kernel has no USB at all, and probing the controller on
  boards where it is not populated reboots the SoC
* soft-float userspace: this SoC implements no VFP, so CONFIG_VFP must stay off
