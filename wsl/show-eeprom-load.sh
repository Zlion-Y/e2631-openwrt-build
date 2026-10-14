#!/bin/bash
K=$(ls -d ~/openwrt/build_dir/target-*/linux-*/linux-*/ | head -1)
F="$K/drivers/net/wireless/mediatek/mt76/mt7915/eeprom.c"
echo "=== mt7915_eeprom_load() ==="; sed -n '120,185p' "$F"
echo; echo "=== mt7915_eeprom_init() ==="; sed -n '255,305p' "$F"
