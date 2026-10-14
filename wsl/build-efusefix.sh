#!/bin/bash
# Rebuild with the efuse-bypass patch, correctly this time:
#   - apply.sh takes the tree path as $1 (no argument = it looks for ./openwrt
#     and dies with "no sanechips target", silently leaving the tree unpatched)
#   - the patch must be numbered after the base tree's own 001-* patch, because
#     my diff's context was taken from the already-001-patched source in build_dir
#   - witnesses are printed so a green rc cannot hide an unapplied patch
set -u
TREE=$HOME/openwrt
HOME_LOG=$HOME/build.log
say() { echo "PHASE $1 $(date +%T) $2" | tee -a "$HOME_LOG"; }

say EFUSE_START ""
bash $HOME/e2631/wsl/sync.sh >/dev/null 2>&1

# renumber the overlay patch if the tree already owns 001
OV=$HOME/e2631/overlay/package/kernel/mt76/patches
if [ -f "$OV/001-mt7915-use-caldata-file-before-efuse.patch" ] && \
   [ -f "$TREE/package/kernel/mt76/patches/001-wifi-mt76-serialize-register-reads-with-outer-cache.patch" ]; then
	mv "$OV/001-mt7915-use-caldata-file-before-efuse.patch" \
	   "$OV/002-mt7915-use-caldata-file-before-efuse.patch"
	say RENUMBERED "002-"
fi

( cd $HOME/e2631 && bash apply.sh "$TREE" ) >> "$HOME_LOG" 2>&1
say APPLY "rc=$?"
ls -l "$TREE/package/kernel/mt76/patches/" | tee -a "$HOME_LOG"

cd "$TREE" || exit 1
# refresh = re-extract + re-patch, so the new patch actually lands
make package/kernel/mt76/{download,refresh,prepare} >> "$HOME_LOG" 2>&1
say MT76_PREP "rc=$?"
SRC=$(ls -d build_dir/target-*/linux-sanechips_generic/mt76-*/ | head -1)
echo "WITNESS patch-in-source: $(grep -c 'Try the file first' "$SRC/mt7915/eeprom.c")" | tee -a "$HOME_LOG"
echo "WITNESS patch-order: $(sed -n '/u32 eeprom_blk_size = MT7915_EEPROM_BLOCK_SIZE;/,+12p' "$SRC/mt7915/eeprom.c" | grep -c 'mt7915_eeprom_load_default')" | tee -a "$HOME_LOG"

make package/kernel/mt76/compile >> "$HOME_LOG" 2>&1
say MT76_COMPILE "rc=$?"
echo "WITNESS eeprom.o still references the efuse helpers (must stay 1, they are just no longer reached first): $(nm "$SRC/mt7915/eeprom.o" 2>/dev/null | grep -c 'mt7915_mcu_get_eeprom_free_block')" | tee -a "$HOME_LOG"

make -j8 world >> "$HOME_LOG" 2>&1
say WORLD "rc=$?"
bash $HOME/e2631/wsl/collect.sh >> "$HOME_LOG" 2>&1
say COLLECT "rc=$?"
