#!/bin/bash
# Prove at instruction level that the rebuilt object waits 8000 ms, and stage the
# freshly packaged (ipkg) copy of the module.
set -u
WIN=/mnt/d/AI/Qoder/E2631-OpenWRT
TREE=$HOME/openwrt
cd "$TREE" || exit 1
LOG=/tmp/objdump-fwt.out
exec >"$LOG" 2>&1

M=build_dir/target-arm_cortex-a9_musl_eabi/linux-sanechips_generic/mt76-2026.10.08~467ae2e3
UNSTR=$M/mt7915/mt7915e.ko
IPKG=$M/ipkg-arm_cortex-a9/kmod-mt7915e/lib/modules/6.18.55/mt7915e.ko
[ -f "$UNSTR" ] && [ -f "$IPKG" ] || { echo missing; exit 1; }

mkdir -p "$WIN/out/fwt"
cp -f "$IPKG" "$WIN/out/fwt/mt7915e.ko"
printf 'staged-size='
wc -c < "$WIN/out/fwt/mt7915e.ko"
printf 'staged-sha256='
sha256sum "$WIN/out/fwt/mt7915e.ko"

OD=$(ls "$HOME"/openwrt/staging_dir/toolchain-*/bin/*objdump 2>/dev/null)
echo "objdump=$OD"
echo '== disassembly of mt7915_firmware_state only'
"$OD" -d --disassemble=mt7915_firmware_state "$UNSTR"
echo '== and the two source lines that define the constants'
n=0
while IFS= read -r l; do
  case "$l" in *'mt76_poll_msec'*|*'state, '*) n=$((n + 1)); printf '  src%d: %s\n' "$n" "$l" ;; esac
done < "$M/mt7915/mcu.c"
echo OBJDUMP-FWT-DONE
