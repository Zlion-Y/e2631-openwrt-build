#!/bin/sh
# Staged MT7916 experiment: one boot, several variables, each one tagged.
#
# Every stage transition is written both to the console and, synced, to the
# jffs2 overlay -- so after a hard hang plus a power cut the log still says which
# stage was running and at what uptime.  That is the whole point: this board
# dies without printing anything, and the heartbeat stops meaning "CPU stopped"
# (proven: HB ran to up=89.22 and vanished exactly when a link retrain hung it).
#
#   S0 baseline           radio untouched (the loader is opt-in now)
#   S1 load driver        the exact action that used to stall boots, done on an
#                         idle, fully-up system instead of inside rc.d
#   S2 AP, beacon only    no client
#   S3 monitor iface up   RX rings allocated, still no client
#   S4 air traffic into it device->host DMA with real frames, still no client
#   S5 client associates  needs a person
#
# Usage: sh /tmp/stages.sh            # S0..S4, no client needed
#        sh /tmp/stages.sh --s5       # then wait for a client
set -u
HB=/sbin/e2631-hb
LOGF=/root/e2631-hb.log

tag() {
	[ -x "$HB" ] && "$HB" now "PHASE=$1 $2" || { echo "PHASE=$1 $2" > /dev/kmsg; echo "PHASE=$1 $2" >> "$LOGF"; sync; }
}
hold() { i=0; while [ "$i" -lt "$1" ]; do sleep 3; i=$((i + 3)); done; }

tag S0 "baseline, radio untouched"
hold 18

tag S1 "loading mt7915e on an idle system"
/sbin/e2631-wifi-on 0
echo "  after load: 7906=$(basename $(readlink /sys/bus/pci/devices/0000:01:00.0/driver) 2>/dev/null || echo none) 790a=$(basename $(readlink /sys/bus/pci/devices/0001:01:00.0/driver) 2>/dev/null || echo none) phys=$(ls /sys/class/ieee80211 2>/dev/null | tr '\n' ' ')" >> "$LOGF"; sync
hold 24

tag S2 "AP up, beacon only, no client"
uci set wireless.radio0.disabled=0
uci set wireless.radio0.channel=6
uci set wireless.radio0.htmode=HE20
uci set wireless.default_radio0.disabled=0
uci set wireless.default_radio0.ssid=E2631-2G
uci set wireless.default_radio0.encryption=none
uci commit wireless
wifi reload
hold 24

tag S3 "monitor iface added (RX rings live, no reader)"
iw phy phy0 interface add mon0 type monitor
ip link set mon0 up
hold 24

tag S4 "monitor reading air frames (device->host DMA, no client)"
( iw dev mon0 set channel 6; timeout 25 tcpdump -i mon0 -nn -q -c 300 2>&1 | tail -3 ) >> "$LOGF" 2>&1
sync
hold 12
ip link set mon0 down
iw phy phy0 interface del mon0

if [ "$1" = --s5 ]; then
	tag S5 "waiting for a client to associate"
	n=0
	while [ "$n" -lt 300 ]; do sleep 3; n=$((n + 3)); done
else
	tag S5-SKIPPED "pass --s5 to wait for a client"
fi
tag END "stages finished, box alive"
