#!/bin/sh
# Overlay the E2631 files onto a checked-out OpenWrt tree and wire them in.
# Idempotent: re-running only refreshes the copies.
#
#   git clone --branch <base-branch> https://github.com/Zlion-Y/openwrt-sanechips-base openwrt
#   git -C openwrt checkout $BASE_SHA
#   ./apply.sh openwrt
set -eu

BASE_SHA=db8b8d4130457dbe46558a7cea872dd2dae539e6
TREE=${1:-openwrt}
HERE=$(cd "$(dirname "$0")" && pwd)

[ -d "$TREE/target/linux/sanechips" ] || { echo "no sanechips target in $TREE - fetch the base first" >&2; exit 1; }

cp -r "$HERE/overlay/." "$TREE/"
mkdir -p "$TREE/tools"
cp "$HERE/tools/mkfactory.mjs" "$TREE/tools/e2631-mkfactory.mjs"

IMG="$TREE/target/linux/sanechips/image/Makefile"
if ! grep -q 'Makefile.e2631' "$IMG"; then
	# Insert before BuildImage so the Device definition is seen by image.mk.
	sed -i 's|^$(eval $(call BuildImage))$|include $(TOPDIR)/target/linux/sanechips/image/Makefile.e2631\n\n$(eval $(call BuildImage))|' "$IMG"
fi
grep -q 'Makefile.e2631' "$IMG" || { echo "failed to hook image/Makefile" >&2; exit 1; }

# The target inherits cortex-a9 hard-float defaults; this SoC has no VFP at all.
CFG="$TREE/target/linux/sanechips/config-6.18"
for opt in CONFIG_VFP CONFIG_VFPV3 CONFIG_NEON CONFIG_ARM_THUMBEE; do
	if grep -q "^$opt=y$" "$CFG"; then
		sed -i "s|^$opt=y\$|# CONFIG_$opt is not set|" "$CFG"
		echo "kernel config: disabled $opt"
	fi
done

# The vendor U-Boot hands the kernel its own bootargs - on this board they are
# "root=/dev/mtdblock8 rootfstype=jffs2 init=/bin/sh -c ..." (read from
# /proc/cmdline of the running vendor system), which describes the vendor
# partition table and would leave PID 1 as a shell. Compile in the command line
# of our own table and ignore the bootloader's, the way the SR1010 port does.
# root=/dev/mtdblock7 is the "rootfs" row of the board DTS, counted from mtd0
# because CONFIG_MTD_PARTITIONED_MASTER is off in the OpenWrt baseline.
if ! grep -q '^CONFIG_CMDLINE_FORCE=y' "$CFG"; then
	printf '%s\n' \
		'# E2631: the vendor bootargs name the vendor layout, not ours (see apply.sh)' \
		'CONFIG_CMDLINE_BOOL=y' \
		'CONFIG_CMDLINE="console=ttyAMA0,115200n8 root=/dev/mtdblock7 rootfstype=squashfs ro rootwait"' \
		'CONFIG_CMDLINE_FORCE=y' >> "$CFG"
	echo "kernel config: forced the OpenWrt command line"
fi

echo "overlay applied to $TREE (base $BASE_SHA)"
