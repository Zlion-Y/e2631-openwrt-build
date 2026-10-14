#!/bin/bash
set -u
K=$(ls -d $HOME/openwrt/build_dir/target-*/linux-*/linux-*/ | head -1)
echo "K=$K"
echo "=== drivers/watchdog files mentioning twd / cortex-a compat ==="
grep -rIn "twd-wdt\|cortex-a15-wdt\|cortex-a7-wdt\|cortex-a9-twd" "$K/drivers/watchdog/" 2>/dev/null | head
ls "$K/drivers/watchdog/" | grep -iE "arm|twd" | head
echo
echo "=== Kconfig candidates ==="
grep -n -A10 "config ARM_V7S_WATCHDOG\|config ARM_V7M_WATCHDOG\|config ARM_SP805_WATCHDOG" "$K/drivers/watchdog/Kconfig" 2>/dev/null | head -34
echo
echo "=== does the binding yaml name the driver? ==="
sed -n '1,40p' "$K/Documentation/devicetree/bindings/watchdog/arm,twd-wdt.yaml" 2>/dev/null
echo
echo "=== our shipped dts/dtsi: twd or cpu-freq nodes present? ==="
grep -rn "twd" ~/openwrt/target/linux/sanechips/dts/ 2>/dev/null | head
echo "=== kernel dts for this SoC in the tree (from PR patch 026) ==="
ls "$K/arch/arm/boot/dts/" 2>/dev/null | grep -i "zte\|zx" | head
grep -n -A8 "twd\|watchdog" "$K/arch/arm/boot/dts/zte/zx279128s.dtsi" 2>/dev/null | head -24
