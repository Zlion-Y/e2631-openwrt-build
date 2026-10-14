#!/bin/bash
# Prove the fix is in the artifacts we are about to flash, not just in the source:
#  1. disassemble mt7915_eeprom_load() and check the file-load happens BEFORE the
#     first efuse MCU call (comments do not survive into the .ko, so look at code)
#  2. check the shipped squashfs carries the beacon service and no mt7915e autoload
set -u
LOG=/mnt/d/AI/Qoder/E2631-OpenWRT/out/efusefix-verify.log
exec >"$LOG" 2>&1
SRC=$HOME/openwrt
M=$(ls -d $SRC/build_dir/target-*/linux-sanechips_generic/mt76-*/ | head -1)
OD=$(ls $SRC/staging_dir/toolchain-*/bin/*-objdump 2>/dev/null | head -1)
echo "objdump=$OD"
echo "=== 1. mt7915_eeprom_load(): call order ==="
"$OD" -d --disassemble=mt7915_eeprom_load "$M/mt7915/eeprom.o" 2>/dev/null | head -60
echo
echo "=== which functions does eeprom.o reference, in call order ==="
"$OD" -dr "$M/mt7915/eeprom.o" 2>/dev/null | \
	awk '/<mt7915_eeprom_load>:/{f=1} f && /R_ARM_.* (mt7915|mt76)_/{print} f && /^$/{c++; if(c>2) exit}' | head -20
echo
echo "=== 2. shipped rootfs contents ==="
ROOT=$SRC/build_dir/target-*/root-sanechips
U=$(ls -d $SRC/staging_dir/host/bin/unsquashfs* | head -1)
P=/mnt/d/AI/Qoder/E2631-OpenWRT/out/efusefix/payload/sysupgrade-zte_zxhn-e2631
W=/tmp/efroot; rm -rf $W; mkdir -p $W
"$U" -no-xattrs -d $W "$P/root" >/dev/null 2>&1 || true
for f in sbin/e2631-hb etc/init.d/e2631-hb etc/init.d/e2631-wifi-eeprom sbin/e2631-leds; do
	printf '%-34s %s\n' "$f" "$([ -e "$W/$f" ] && echo present || echo MISSING)"
done
echo "rc.d: $(ls $W/etc/rc.d/ | grep -E 'e2631' | tr '\n' ' ')"
echo "mt7915e in modules.d: $(grep -rl mt7915e $W/etc/modules.d/ 2>/dev/null | tr '\n' ' ')(empty=good)"
echo "module file sizes: $(ls -l $W/lib/modules/6.18.55/mt7915e.ko 2>/dev/null | awk '{print $5}')"
echo
echo "=== 3. the .ko inside the image: does its eeprom_load match the .o? ==="
KO=$W/lib/modules/6.18.55/mt7915e.ko
[ -e "$KO" ] && "$OD" -dr "$KO" 2>/dev/null | \
	awk '/<mt7915_eeprom_load>:/{f=1} f && /R_ARM_.* (mt7915|mt76)_/{print} f && /^$/{c++; if(c>3) exit}' | head -12
echo
echo "=== sizes ==="
ls -l "$P/kernel" "$P/root" | awk '{print $5, $NF}'
sha256sum "$P/kernel" "$P/root"
