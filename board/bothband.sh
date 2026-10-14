#!/bin/sh
# Runs ON THE BOX. Second half of the one-HIF result: with the ext-HIF function
# hidden, does the 5G phy (which the main function registers by itself) also
# survive an AP start?
up() { cut -d' ' -f1 /proc/uptime; }
irq() { grep -E "mt7915e" /proc/interrupts | tr -s ' ' | cut -d' ' -f1-4 | tr '\n' ' '; }

echo "### pre: $(up) pci devices:"
ls /sys/bus/pci/devices/
iw dev 2>&1 | head -3

echo "### bands: which phy owns which band"
for p in /sys/class/ieee80211/*; do
	n=${p##*/}
	echo "    $n band=$(iw phy $n info 2>/dev/null | grep -oE '^\tBand [0-9]' | tr -d '\t' | tr '\n' ',') ant=$(iw phy $n info | grep -m1 'Configured Antennas' | sed 's/.*: //')"
done

echo "### bring up 2.4G ch6 HE20 and 5G ch44 HE80 together"
uci set wireless.radio0.disabled=0
uci set wireless.radio0.channel=6
uci set wireless.radio0.htmode=HE20
uci set wireless.default_radio0.disabled=0
uci set wireless.default_radio0.ssid=E2631-2G
uci set wireless.default_radio0.encryption=psk2
uci set wireless.default_radio0.key=TestPass123
uci set wireless.radio1.disabled=0
uci set wireless.radio1.channel=44
uci set wireless.radio1.htmode=HE80
uci set wireless.default_radio1.disabled=0
uci set wireless.default_radio1.ssid=E2631-5G
uci set wireless.default_radio1.encryption=psk2
uci set wireless.default_radio1.key=TestPass123
uci commit wireless
wifi
for i in $(seq 1 15); do
	sleep 6
	echo "--- $(up) load=$(cut -d' ' -f1-3 /proc/loadavg) irq: $(irq)"
	dmesg | tail -1
done

echo "### result"
iw dev
echo "### hostapd up?"
ps | grep -E "hostapd" | grep -v grep | head -3
logread | grep -iE "hostapd|wpad" | tail -8
echo "### DONE $(up)"
