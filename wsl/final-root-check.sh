#!/bin/bash
# What is actually inside the rootfs we are about to flash?  Format checks and
# CRCs say nothing about whether the bind-order fix and the LED service made it
# into the squashfs, so look at the files themselves.
set -u
LOG=/mnt/d/AI/Qoder/E2631-OpenWRT/out/final-root-check.log
exec >"$LOG" 2>&1

P=/mnt/d/AI/Qoder/E2631-OpenWRT/out/wifix3/payload/sysupgrade-zte_zxhn-e2631
U=$(ls -d ~/openwrt/staging_dir/host/bin/unsquashfs* 2>/dev/null | head -1)
echo "payload=$P  exists=$([ -d "$P" ] && echo yes || echo no)"
ls -l "$P" 2>/dev/null
echo "unsquashfs=$U"
[ -d "$P" ] || { echo "NO PAYLOAD DIR -- the final package was packed from something else"; exit 1; }

W=/tmp/finalroot
rm -rf "$W"; mkdir -p "$W"
"$U" -no-xattrs -d "$W" "$P/root" >/dev/null 2>&1 || echo "unsquashfs rc=$?"
echo "extracted files: $(find "$W" -type f | wc -l)"

echo
echo "=== the four things this image is supposed to fix ==="
for f in sbin/e2631-leds etc/init.d/e2631-leds etc/init.d/e2631-wifi-eeprom \
	 etc/hotplug.d/firmware/11-mt76-caldata sbin/e2631-fwslot sbin/e2631-commit; do
	if [ -e "$W/$f" ]; then
		printf 'PRESENT %-45s %sB exec=%s\n' "$f" "$(stat -c %s "$W/$f")" "$([ -x "$W/$f" ] && echo yes || echo NO)"
	else
		printf 'MISSING %s\n' "$f"
	fi
done

echo
echo "=== rc.d links actually created (auto-enable happens in rootfs.mk) ==="
ls "$W/etc/rc.d/" 2>/dev/null | sort | sed 's/^/  /'

echo
echo "=== bind order inside the shipped init script (must bind 0x7906 BEFORE re-enabling autoprobe) ==="
sed -n '1,80p' "$W/etc/init.d/e2631-wifi-eeprom" 2>/dev/null | grep -nE 'START=|drivers_autoprobe|modprobe|bind_one|echo \$\{dev' 
echo "--- firmware hook accepts the name the driver asks for? ---"
grep -n 'mt7916_eeprom.bin' "$W/etc/hotplug.d/firmware/11-mt76-caldata" 2>/dev/null

echo
echo "=== AutoProbe really gone from the shipped module autoload? ==="
grep -rn 'mt7915e' "$W/etc/modules.d/" 2>/dev/null || echo "  no /etc/modules.d entry mentioning mt7915e (good: nothing loads it at boot)"

echo
echo "=== wifi radios default state + LuCI/theme presence ==="
grep -A2 "option disabled" "$W/etc/config/wireless" 2>/dev/null | head -12
ls "$W/www/luci-static/" 2>/dev/null | tr '\n' ' '; echo
ls "$W/lib/firmware/mediatek/" 2>/dev/null | head -5

echo
echo "=== package manifest (control files) ==="
ls "$W"/usr/lib/opkg/status >/dev/null 2>&1 && grep -E "^Package: (luci|argon| luci-theme|kmod-mt7915|e2631)" /dev/null 2>/dev/null
grep -hoE "Package: [a-zA-Z0-9_.+-]+" "$W"/usr/lib/opkg/status 2>/dev/null | grep -iE "luci|argon|mt79|mt76|e2631|hostap|wpad" | sort -u

echo
echo "=== LED names the driver exposes in the shipped DTB ==="
for d in "$W"/rom/../*.dtb "$W"/*.dtb; do [ -e "$d" ] && echo "dtb at $d"; done 2>/dev/null
ls -l "$W/boot/" 2>/dev/null | head

echo
echo "=== sha256 of the extracted kernel + root, for cross-checking the packed header ==="
sha256sum "$P/kernel" "$P/root" 2>/dev/null
echo "kernel size: $(stat -c %s "$P/kernel" 2>/dev/null) (0x$(printf %x "$(stat -c %s "$P/kernel" 2>/dev/null)"))"
