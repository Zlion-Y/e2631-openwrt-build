#!/bin/bash
# Which mt7915 source actually builds the .ko we load? The kernel tree always
# contains drivers/net/wireless/.../mt7915, but kmod-mt7915e may come from the
# mt76 feed package instead. Patching the wrong copy is a silent no-op, so find
# the one that produced the object file.
set -u
LOG=/mnt/d/AI/Qoder/E2631-OpenWRT/out/mt7915-which-src.log
exec >"$LOG" 2>&1

echo "=== candidate source copies under build_dir ==="
find ~/openwrt/build_dir -maxdepth 3 -type d \( -name 'mt76*' -o -name 'mac80211*' \) 2>/dev/null | head
echo
echo "=== any eeprom.c for mt7915 anywhere in build_dir ==="
find ~/openwrt/build_dir -name eeprom.c -path '*mt7915*' 2>/dev/null | head
echo
echo "=== the built .ko and its modules.order / source dir ==="
find ~/openwrt/build_dir -name 'mt7915e.ko' 2>/dev/null | head
for d in $(find ~/openwrt/build_dir -maxdepth 3 -type d -name 'mt76*' 2>/dev/null); do
	echo "--- $d"
	ls "$d" 2>/dev/null | head -8
	grep -m2 -rn "MTK_VERSION\|backport" "$d"/*.c 2>/dev/null | head -2
done
echo
echo "=== package/kernel/mt76 Makefile: PKG_SOURCE / version ==="
sed -n '1,35p' ~/openwrt/package/kernel/mt76/Makefile 2>/dev/null
echo
echo "=== is kmod-mt7915e defined there or in the kernel? ==="
grep -rn "kmod-mt7915e\|MT7915" ~/openwrt/package/kernel/mt76/Makefile 2>/dev/null | head -6
grep -rn "config MT7915E\|mt7915" ~/openwrt/drivers/net/wireless/mediatek/mt76/mt7915/Kconfig 2>/dev/null | head -4
echo
echo "=== ipk the image actually shipped ==="
ls -l ~/openwrt/bin/packages/arm_arm1176jzf-s_vfp_*/base/kmod-mt7915e* 2>/dev/null || \
	 find ~/openwrt/bin/packages -name 'kmod-mt7915e*' 2>/dev/null | head
find ~/openwrt/bin -name 'kmod-mt7915e*' -newer ~/openwrt/package/kernel/mt76/Makefile 2>/dev/null | head -3
