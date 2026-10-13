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
# The overlay is authored on a filesystem without exec bits; these have to be
# runnable on the device, and rc.common refuses to enable a service script that
# is not executable.
for f in sbin/e2631-probe sbin/e2631-trial sbin/e2631-commit etc/init.d/e2631-trial; do
	chmod +x "$TREE/target/linux/sanechips/base-files/$f"
done

# Only two feeds matter for this board: packages (kmod-mt7915e, ttyd) and luci.
# Cloning routing/telephony/video costs several minutes of every local build and
# contributes nothing but unresolved-dependency warnings (bmx7) to the log.
# feeds.conf is regenerated from the .default, so drop any stale copy.
if [ -f "$TREE/feeds.conf.default" ]; then
	sed -i -E 's@^src-git (routing|telephony|video) @#src-git \1 @' "$TREE/feeds.conf.default"
	rm -f "$TREE/feeds.conf"
fi

# A dead mirror is worse than a slow one: OpenWrt's curl is started with
# --connect-timeout but no transfer watchdog, so a host that accepts the
# connection and then sends nothing (ftpmirror.gnu.org did exactly that here,
# 0 bytes for 6 minutes, load 0.03) blocks the build forever instead of falling
# through to the next entry. Two knobs, both supported upstream:
#   CURL_OPTIONS            honoured verbatim by scripts/download.pl -> rotate
#   E2631_GNU_MIRROR        put a fast GNU mirror at the head of "@GNU"
# The mirror is opt-in because the CI runner is not on such a network.
if [ -n "${E2631_GNU_MIRROR:-}" ] && [ -f "$TREE/scripts/projectsmirrors.json" ]; then
	# It is already in the list, just last: download.pl only rotates when curl
	# fails, so a stalled head entry costs the whole timeout chain per package.
	# Move the chosen mirror to the front instead of appending a duplicate.
	m=${E2631_GNU_MIRROR//\//\\/}
	sed -i "/$m/d" "$TREE/scripts/projectsmirrors.json"
	sed -i "0,/\"@GNU\": \[/s//\"@GNU\": [\n\t\t\"$E2631_GNU_MIRROR\",/" "$TREE/scripts/projectsmirrors.json"
	sed -n '/"@GNU": \[/,+2p' "$TREE/scripts/projectsmirrors.json"
fi

IMG="$TREE/target/linux/sanechips/image/Makefile"
if ! grep -q 'Makefile.e2631' "$IMG"; then
	# Insert before BuildImage so the Device definition is seen by image.mk.
	sed -i 's|^$(eval $(call BuildImage))$|include $(TOPDIR)/target/linux/sanechips/image/Makefile.e2631\n\n$(eval $(call BuildImage))|' "$IMG"
fi
grep -q 'Makefile.e2631' "$IMG" || { echo "failed to hook image/Makefile" >&2; exit 1; }

# The target inherits cortex-a9 hard-float defaults; this SoC has no VFP at all.
# Turn the option off together with everything that depends on it: leaving
# CONFIG_VFPv3=y with VFP unset makes the kernel's syncconfig restart and then
# stop on an interactive prompt (that is what a "VFP ... [N/y/?] (NEW)" failure
# in a CI log means). The names are matched case-insensitively and rewritten
# with their own spelling, because the fragment writes CONFIG_VFPv3, not
# CONFIG_VFPV3.
CFG="$TREE/target/linux/sanechips/config-6.18"
for opt in VFP VFPv3 NEON KERNEL_MODE_NEON ARM_THUMBEE; do
	if sed -E -n "s|^CONFIG_(${opt})=y\$|# CONFIG_\\1 is not set|Ip" "$CFG" \
	   | grep -q .; then
		sed -E -i "s|^CONFIG_(${opt})=y\$|# CONFIG_\\1 is not set|I" "$CFG"
		echo "kernel config: disabled ${opt}"
	fi
done
for opt in VFP VFPv3 NEON; do
	grep -qiE "^CONFIG_${opt}=y$" "$CFG" && {
		echo "kernel config: $opt still enabled" >&2; exit 1; }
done

# The vendor U-Boot hands the kernel its own bootargs - on this board they are
# "root=/dev/mtdblock8 rootfstype=jffs2 init=/bin/sh -c ..." (read from
# /proc/cmdline of the running vendor system), which describes the vendor
# partition table and would leave PID 1 as a shell. Compile in the command line
# of our own table and ignore the bootloader's, the way the SR1010 port does.
#
# The mtdblock number is the row the "rootfs" label occupies in the board DTS,
# counted from mtd0 because CONFIG_MTD_PARTITIONED_MASTER is off. Counted, not
# remembered: a table edit that shifts the rows would otherwise bake a wrong
# root= into the kernel and only show up on the device, after the flash.
DTS="$TREE/target/linux/sanechips/dts/zx279128s-zte-zxhn-e2631.dts"
ROOTDEV=$(awk '
	/[[:space:]]partitions[[:space:]]*\{/ { p = 1 }
	p {
		d += gsub(/\{/, "{") - gsub(/\}/, "}")
		if (match($0, /label[ \t]*=[ \t]*"[^"]*"/)) {
			s = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
			if (s == "rootfs") { print n; exit }
			n++
		}
		if (d == 0) p = 0
	}' "$DTS")
[ -n "$ROOTDEV" ] || { echo "no partition labelled rootfs in $DTS" >&2; exit 1; }

# Written unconditionally, and our previous block removed first: apply.sh runs
# against a working tree that may already have been patched, and a stale
# CONFIG_CMDLINE in target/linux/sanechips/config-6.18 would otherwise survive
# every later edit here (that is how a changed root= or a dropped earlycon would
# silently keep the old value).
CMD_MARK='# E2631: the vendor bootargs name the vendor layout, not ours (see apply.sh)'
sed -i -e "\|^$CMD_MARK\$|d" -e '/^CONFIG_CMDLINE_BOOL=y$/d' -e '/^CONFIG_CMDLINE_FORCE=y$/d' \
	-e '/^CONFIG_CMDLINE=/d' "$CFG"
printf '%s\n' "$CMD_MARK" \
	'CONFIG_CMDLINE_BOOL=y' \
	"CONFIG_CMDLINE=\"console=ttyAMA0,115200n8 earlycon root=/dev/mtdblock$ROOTDEV rootfstype=squashfs ro rootwait\"" \
	'CONFIG_CMDLINE_FORCE=y' >> "$CFG"
echo "kernel config: forced the OpenWrt command line, root on mtdblock$ROOTDEV, earlycon on"

echo "overlay applied to $TREE (base $BASE_SHA)"
