#!/bin/bash
echo "=== did apply.sh land the patch in the tree? ==="
ls -l ~/openwrt/package/kernel/mt76/patches/ 2>&1 | head -5
echo
echo "=== apply.sh failure tail (build.log) ==="
sed -n '/overlay applied\|ERROR\|error:/,$p' ~/build.log 2>/dev/null | tail -25
echo
echo "=== last 15 lines of build.log ==="
tail -15 ~/build.log 2>/dev/null
echo
echo "=== mt76 source after prepare: does it carry the new block? ==="
SRC=$(ls -d ~/openwrt/build_dir/target-*/linux-sanechips_generic/mt76-*/ 2>/dev/null | head -1)
echo "SRC=$SRC"
grep -n "Try the file first" "$SRC/mt7915/eeprom.c" 2>/dev/null || echo "  NOT PRESENT in build_dir source"
grep -n "quilt\|Applied patch" ~/build.log 2>/dev/null | tail -4
