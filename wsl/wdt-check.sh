#!/bin/bash
# Can a hardware watchdog reset the SoC by itself when it hangs?  That turns
# every lethal experiment into "reboot yourself, we read the serial log", which
# is worth a lot of power cycles.
set -u
LOG=/mnt/d/AI/Qoder/E2631-OpenWRT/out/wdt-check.log
exec >"$LOG" 2>&1
K=$(ls -d ~/openwrt/build_dir/target-*/linux-*/linux-*/ | head -1)
echo "=== watchdog drivers that could match this SoC ==="
ls "$K/drivers/watchdog/" | head -40
echo
echo "=== any zte/sanechips/oxnas-ish watchdog in the tree or in the PR patches ==="
grep -rIln "zx279128\|sanechips\|zte" "$K/drivers/watchdog/" 2>/dev/null
ls ~/openwrt/target/linux/sanechips/patches-6.18/ | grep -iE "wdt|watchdog|reset"
echo
echo "=== does the board DT(S)O or the SoC dtsi describe a wdt node? ==="
grep -rn -iE "watchdog|wdt|sysctl-reset|reset-controller" ~/openwrt/target/linux/sanechips/dts/*.dts 2>/dev/null | head
DTSK=$(ls "$K/arch/arm/boot/dts/" 2>/dev/null | grep -i "zx279128\|zte" | head -5); echo "kernel dts: $DTSK"
for f in $(ls "$K/arch/arm/boot/dts/"*zx279128*.dts* 2>/dev/null); do
	echo "--- $f"; grep -n -iE "watchdog|wdt|compatible = \"zte" "$f" | head -12
done
echo
echo "=== vendor system: is there a watchdog device and who feeds it? ==="
echo "  (checked earlier from stock: /dev/watchdog presence unknown; see next section)"
grep -n "CONFIG_WATCHDOG\|WDT" "$K/.config" 2>/dev/null | head -8
echo
echo "=== vendor kernel config for a watchdog ==="
grep -inE "watchdog|wdt" /mnt/d/AI/Qoder/E2631-OpenWRT/device/backup/vendor-config-full.txt 2>/dev/null | head -12
echo
echo "=== also: does U-Boot leave a boot watchdog armed? (strings from the dump) ==="
strings -a /mnt/d/AI/Qoder/E2631-OpenWRT/device/backup/mtd1-bootloader.bin 2>/dev/null | grep -iE "watchdog|wdt|timeout" | head -12
