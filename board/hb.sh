#!/bin/sh
# Liveness beacon.  Written to /dev/kmsg so it reaches the serial console:
# if the console goes silent while this is running, the CPU itself is stuck
# (bus hang / irq-off lockup); if it keeps printing while the network dies,
# the machine is alive and only the Wi-Fi path is broken -- which changes both
# the diagnosis and the recovery options (no power cycle needed).
#
# Every line carries: uptime, the mt7915e interrupt total, and the number of
# associated stations, so the serial log alone answers "when did it stop".
set -u
interval=${1:-2}
while :; do
	up=$(cut -d ' ' -f1 /proc/uptime)
	irq=$(grep -m1 -i "mt79" /proc/interrupts 2>/dev/null | tr -s ' ')
	st=$(iw dev phy0-ap0 station dump 2>/dev/null | grep -c '^Station')
	sum=0
	[ -n "$irq" ] && for f in $(echo "$irq" | cut -d ':' -f2- | tr -s ' ' '\n' | grep -E '^[0-9]+$'); do
		sum=$((sum + f))
	done
	echo "HB up=$up irq=$sum sta=$st" > /dev/kmsg
	sleep "$interval"
done
