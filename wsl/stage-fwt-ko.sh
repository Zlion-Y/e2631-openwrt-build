#!/bin/bash
# Stage the mt7915e.ko that actually ships (the copy installed into the rootfs)
# into the workspace and prove it carries the widened wait.
set -u
WIN=/mnt/d/AI/Qoder/E2631-OpenWRT
TREE=$HOME/openwrt
cd "$TREE" || exit 1
LOG=/tmp/stage-fwt.out
exec >"$LOG" 2>&1

SHIP=build_dir/target-arm_cortex-a9_musl_eabi/root-sanechips/lib/modules/6.18.55/mt7915e.ko
[ -f "$SHIP" ] || { echo "missing $SHIP"; exit 1; }
mkdir -p "$WIN/out/fwt"
cp -f "$SHIP" "$WIN/out/fwt/mt7915e.ko"

printf 'staged-size='
wc -c < "$WIN/out/fwt/mt7915e.ko"
printf 'sha256='
sha256sum "$WIN/out/fwt/mt7915e.ko"
printf 'ipkg-copy-identical='
if cmp -s build_dir/target-arm_cortex-a9_musl_eabi/linux-sanechips_generic/mt76-2026.10.08~467ae2e3/ipkg-arm_cortex-a9/kmod-mt7915e/lib/modules/6.18.55/mt7915e.ko "$WIN/out/fwt/mt7915e.ko"; then echo yes; else echo no; fi

printf 'vermagic='
strings -a "$WIN/out/fwt/mt7915e.ko" | while IFS= read -r l; do
  case "$l" in vermagic*) printf '%s\n' "$l" ;; esac
done | while IFS= read -r l; do echo "$l"; done

echo '== source-level witnesses in the built-from tree'
M=build_dir/target-arm_cortex-a9_musl_eabi/linux-sanechips_generic/mt76-2026.10.08~467ae2e3
printf 'mcu.c wait-8000='
n=0
while IFS= read -r l; do case "$l" in *'state, 8000'*) n=$((n + 1));; esac; done < "$M/mt7915/mcu.c"
echo "$n"
printf 'mcu.c wait-1000='
n=0
while IFS= read -r l; do case "$l" in *'state, 1000'*) n=$((n + 1));; esac; done < "$M/mt7915/mcu.c"
echo "$n"
printf 'eeprom.c caldata-first='
n=0
while IFS= read -r l; do case "$l" in *'E2631: the per-unit calibration'*) n=$((n + 1));; esac; done < "$M/mt7915/eeprom.c"
echo "$n"
echo STAGE-FWT-DONE
