#!/bin/bash
# Same witness, but find the real symbol name first: gcc splits/const-propagates
# static functions, so --disassemble=mt7915_eeprom_load silently matched nothing.
set -u
LOG=/mnt/d/AI/Qoder/E2631-OpenWRT/out/efusefix-verify2.log
exec >"$LOG" 2>&1
SRC=$HOME/openwrt
M=$(ls -d $SRC/build_dir/target-*/linux-sanechips_generic/mt76-*/ | head -1)
OD=$(ls $SRC/staging_dir/toolchain-*/bin/*-objdump | head -1)
U=$(ls -d $SRC/staging_dir/host/bin/unsquashfs* | head -1)
P=$SRC/build_dir/target-*/root-sanechips/lib/modules/6.18.55/mt7915e.ko
echo "=== symbols containing eeprom_load in eeprom.o ==="
nm "$M/mt7915/eeprom.o" | grep -i eeprom_load
echo
echo "=== relocations in the body of each candidate, in address order ==="
for s in $(nm "$M/mt7915/eeprom.o" | awk '/eeprom_load/{print $3}'); do
	echo "--- $s"
	"$OD" -dr "$M/mt7915/eeprom.o" 2>/dev/null | awk -v S="<$s>:" '$0 ~ S {f=1; next} f && /^$/{if (++b>1) exit} f && /R_ARM_/ {print}' | \
		sed -n 's/.*R_ARM_[A-Z0-9_]* *\([0-9a-f]*\) *\(mt7915_[a-z_]*\|mt76_[a-z_]*\).*/\1 \2/p' | head -14
done
echo
echo "=== the SAME check on the .ko that ships in the image ==="
KO=$(ls $P 2>/dev/null | head -1)
echo "KO=$KO"
if [ -n "$KO" ]; then
	nm "$KO" 2>/dev/null | grep -i eeprom_load | head -5
	"$OD" -dr "$KO" 2>/dev/null | awk '/<mt7915_eeprom_load[.:a-z0-9]*>:/{f=1; print "AT "$0; next} f && /^$/{if (++b>1) exit} f && /R_ARM_/ {print}' | \
		sed -n 's/.*R_ARM_[A-Z0-9_]* *\([0-9a-f]*\) *\([a-z_0-9.]*\).*/\1 \2/p' | head -16
fi
echo
echo "=== decisive ordering test: does load_default appear before free_block? ==="
"$OD" -dr "$KO" 2>/dev/null | awk '/<mt7915_eeprom_load/{f=1} f' | \
	awk '/default/{d=NR} /free_block/{fb=NR} END{if(d&&fb) print (d<fb ? "PASS: default-bin path comes FIRST (line "d" < "fb")" : "FAIL: efuse still first"); else print "INCONCLUSIVE d="d" fb="fb}'
"$OD" -dr "$M/mt7915/eeprom.o" 2>/dev/null | awk '/<mt7915_eeprom_load/{f=1} f' | \
	awk '/default/{d=NR} /free_block/{fb=NR} END{if(d&&fb) print "eeprom.o: " (d<fb ? "PASS first="d : "FAIL efuse-first="fb); else print "eeprom.o: INCONCLUSIVE"}'
