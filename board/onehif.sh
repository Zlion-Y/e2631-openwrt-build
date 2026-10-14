#!/bin/sh
# Runs ON THE BOX. Decides whether the MT7916's second PCIe function is what
# takes the board down.
#
# mainline treats 14c3:7906 + 14c3:790a as one chip with two host interfaces and
# links them at probe: the main function writes the recog-id register through the
# OTHER function's BAR, and every later interrupt-mask update goes out as
# mt7915_dual_hif_set_irq_mask() to both. On this board the two functions sit on
# different root ports, which is not the topology upstream was written for, so
# that path is the prime suspect for "bringing up even one AP kills the SoC".
#
# Hiding the 0x790a function from the PCI core before the module loads leaves the
# main device single-HIF: band 1 (2.4G) only, and no dual-hif register traffic at
# all. If the box then survives an AP start, the cause is proven and 2.4G works.
echo "### step 0: current state"
cut -d' ' -f1 /proc/uptime
ls /sys/class/ieee80211/ 2>&1
iw dev 2>&1

echo "### step 1: unload the driver and hide the ext-HIF function"
ifb() { cat /proc/interrupts | grep -E "mt7915e"; }
ifb
rmmod mt7915e 2>&1
sleep 1
echo 1 > /sys/bus/pci/devices/0001:01:00.0/remove 2>&1
ls /sys/bus/pci/devices/

echo "### step 2: load with no auto-probe, bind only the main function"
echo 0 > /sys/bus/pci/drivers_autoprobe
modprobe mt7915e 2>&1
echo 1 > /sys/bus/pci/drivers_autoprobe
sleep 1
echo 0000:01:00.0 > /sys/bus/pci/drivers/mt7915e/bind 2>&1
sleep 4
ls /sys/class/ieee80211/ 2>&1
dmesg | tail -8
ifb

echo "### step 3: bring up one 2.4G AP on the surviving phy"
phy=$(ls /sys/class/ieee80211/ 2>/dev/null | head -1)
[ -n "$phy" ] || { echo "NO PHY - giving up"; exit 1; }
uci set wireless.radio0.disabled=0
uci set wireless.radio0.channel=6
uci set wireless.default_radio0.disabled=0
uci set wireless.default_radio0.ssid=E2631-2G-1hif
uci commit wireless
wifi
for i in 1 2 3 4 5 6 7 8 9 10; do
	sleep 5
	echo "--- $(cut -d' ' -f1 /proc/uptime) load=$(cut -d' ' -f1-3 /proc/loadavg) $(ifb | tr -s ' ' | cut -d' ' -f1-4 | tr '\n' ' ')"
	dmesg | tail -1
done
echo "### step 3 result"
iw dev
echo "### step 4: leave the box safe for the next boot"
uci set wireless.radio0.disabled=1
uci set wireless.default_radio0.disabled=1
uci commit wireless
sync
echo "### DONE $(cut -d' ' -f1 /proc/uptime)"
