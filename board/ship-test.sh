#!/bin/sh
# Runs ON THE BOX. Validates exactly what the image will do at boot: reload the
# driver through e2631-wifi-eeprom (main function only) and then live with a
# 2.4G AP up.
up() { cut -d' ' -f1 /proc/uptime; }
irq() { grep -E "mt7915e" /proc/interrupts | tr -s ' ' | cut -d' ' -f1-4 | tr '\n' ' '; }

echo "### reload the driver the way the service does"
rmmod mt7915e 2>&1
sleep 1
/etc/init.d/e2631-wifi-eeprom start; echo "start rc=$?"
sleep 3
echo "--- bindings (790a must be driver=none)"
for d in /sys/bus/pci/devices/*; do
	[ -e "$d/device" ] || continue
	echo "  ${d##*/} $(cat $d/device) $(basename $(readlink $d/driver) 2>/dev/null || echo none)"
done
echo "--- phys: $(ls /sys/class/ieee80211/ | tr '\n' ' ')"
dmesg | grep -E "enabling device|registering led|eeprom load" | tail -6

echo "### bring up 2.4G only and keep it up for 160 s"
uci set wireless.radio0.disabled=0
uci set wireless.radio0.channel=6
uci set wireless.radio0.htmode=HE40
uci set wireless.default_radio0.disabled=0
uci set wireless.default_radio0.ssid=E2631-2G
uci set wireless.default_radio0.encryption=psk2
uci set wireless.default_radio0.key=OpenWrt2631
uci set wireless.radio1.disabled=1
uci set wireless.default_radio1.disabled=1
uci commit wireless
wifi
for i in $(seq 1 20); do
	sleep 8
	echo "--- $(up) load=$(cut -d' ' -f1-3 /proc/loadavg) irq=$(irq)"
	dmesg | tail -1
done

echo "### final state"
iw dev
echo "--- 2.4G phy sanity: $(iw phy $(ls /sys/class/ieee80211 | head -1) info | grep -c 'Band 1') band1 block"
echo "--- beacons actually going out:"
cat /sys/kernel/debug/ieee80211/phy0/mt76/hw-queues 2>/dev/null | head -3
ps | grep -c hostapd
echo "### DONE $(up)"
