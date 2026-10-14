#!/bin/bash
# Follow-up on final-root-check: where is the A/B switcher, is the squashfs
# extraction complete, and what does the shipped wireless config default to?
set -u
LOG=/mnt/d/AI/Qoder/E2631-OpenWRT/out/final-root-check2.log
exec >"$LOG" 2>&1
W=/tmp/finalroot
P=/mnt/d/AI/Qoder/E2631-OpenWRT/out/wifix3/payload/sysupgrade-zte_zxhn-e2631
U=$(ls -d ~/openwrt/staging_dir/host/bin/unsquashfs* | head -1)

echo "=== every e2631* file in the shipped rootfs ==="
find "$W" -name 'e2631*' | sed "s|$W/||" | sort

echo
echo "=== extraction completeness: listing vs extracted ==="
"$U" -ll "$P/root" 2>/dev/null | wc -l
echo "  (unsquashfs -ll lines above; files on disk: $(find "$W" | wc -l) incl dirs)"
"$U" -stat "$P/root" 2>&1 | tail -6
echo "  squashfs bytes=$(stat -c %s "$P/root")  md5 of image inside build dir:"
md5sum "$P/root"

echo
echo "=== shipped /etc/config/wireless (does boot bring radios up by itself?) ==="
cat "$W/etc/config/wireless" 2>/dev/null | head -40

echo
echo "=== trial/commit gate: what decides 'accepted' ==="
sed -n '1,40p' "$W/etc/init.d/e2631-trial" 2>/dev/null
echo "--- sbin/e2631-trial ---"
sed -n '1,60p' "$W/sbin/e2631-trial" 2>/dev/null

echo
echo "=== does anything still auto-load mt7915e? ==="
grep -rn "mt7915e" "$W/etc/" 2>/dev/null | head
echo "--- hotplug.d/net setup hooks ---"
ls "$W/etc/hotplug.d/" 2>/dev/null

echo
echo "=== LED / DTB sanity: led aliases and names baked into the shipped dtb ==="
D=$(find "$W" -name '*e2631*.dtb' | head -1); echo "dtb=$D"
[ -n "$D" ] && ~/openwrt/staging_dir/host/bin/dtc -I dtb -O dts "$D" 2>/dev/null | sed -n '1,60p'
