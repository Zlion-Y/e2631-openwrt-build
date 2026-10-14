#!/bin/sh
# A/B the MT7916 firmware images without reflashing.
#
# The stock system carries different images from the ones linux-firmware ships
# (patch 8672 vs 8800, WA 458112 vs 504032, WM 1759340 vs 1767568) and reads
# them at runtime from /etc/wireless/mt7916/. Our fatal window is exactly the
# WM/WA download, so swap the files and re-probe.
#
# Re-probing without a reboot: unbind, remove the endpoint from the PCI tree,
# rescan, then let /sbin/e2631-wifi-on bind it again -- probe reloads the
# firmware from /lib/firmware. rmmod is deliberately not used: unloading the
# module while the card is live has killed this board before.
#
#   fw-ab.sh save                 snapshot what the image ships (once)
#   fw-ab.sh use ours|vendor      install one set
#   fw-ab.sh retry                re-probe without rebooting
#   fw-ab.sh status               what is in place now
#
# Keep this file plain busybox-ash: no nested case, no awk, no ${var:off:len}.
set -u
FW=/lib/firmware/mediatek
SAVED=/root/fw-ours
VEND=/root/vendor-fw
DEV=0000:01:00.0

# Flat "upstream vendor" word list, walked two at a time.
PAIRS="mt7916_rom_patch.bin mt7916_patch_e1_hdr.bin \
mt7916_wm.bin WIFI_RAM_CODE_MT7916.bin \
mt7916_wa.bin 7916_WACPU_RAM_CODE_release.bin"

# No stat on this busybox.
sz() {
	wc -c < "$1" 2>/dev/null || echo missing
}

save() {
	mkdir -p "$SAVED"
	cp -p "$FW/mt7916_rom_patch.bin" "$SAVED/mt7916_rom_patch.bin"
	cp -p "$FW/mt7916_wm.bin" "$SAVED/mt7916_wm.bin"
	cp -p "$FW/mt7916_wa.bin" "$SAVED/mt7916_wa.bin"
	[ -e "$FW/mt7916_eeprom.bin" ] && cp -p "$FW/mt7916_eeprom.bin" "$SAVED/mt7916_eeprom.bin"
	echo "saved to $SAVED:"
	ls -l "$SAVED" | tr -s ' ' | cut -d' ' -f5,9
}

use_ours() {
	if [ ! -d "$SAVED" ]; then
		echo "no $SAVED -- run: fw-ab save"
		return 1
	fi
	for o in mt7916_rom_patch.bin mt7916_wm.bin mt7916_wa.bin; do
		if [ -e "$SAVED/$o" ]; then
			cp -f "$SAVED/$o" "$FW/$o"
			echo "  $o restored ($(sz "$FW/$o") B)"
		else
			echo "  $o missing in $SAVED"
		fi
	done
	echo "installed set: ours"
}

use_vendor() {
	if [ ! -d "$VEND" ]; then
		echo "no $VEND"
		return 1
	fi
	set -- $PAIRS
	while [ "$#" -gt 0 ]; do
		o=$1
		v=$2
		shift
		shift
		if [ -e "$VEND/$v" ]; then
			cp -f "$VEND/$v" "$FW/$o"
			echo "  $o <= $v ($(sz "$FW/$o") B)"
		else
			echo "  $o: no vendor file $v"
		fi
	done
	echo "installed set: vendor"
}

retry() {
	if [ -e "/sys/bus/pci/devices/$DEV/driver" ]; then
		echo "$DEV" > "/sys/bus/pci/devices/$DEV/driver/unbind" 2>/dev/null
	fi
	echo "$DEV" > "/sys/bus/pci/devices/$DEV/remove" 2>/dev/null
	sleep 2
	echo 1 > /sys/bus/pci/rescan
	sleep 3
	/sbin/e2631-wifi-on 0
}

status() {
	echo "== in place now =="
	ls -l "$FW"/mt7916_rom_patch.bin "$FW"/mt7916_wm.bin "$FW"/mt7916_wa.bin 2>/dev/null | tr -s ' ' | cut -d' ' -f5,9
	echo "== live vs saved-ours =="
	for o in mt7916_rom_patch.bin mt7916_wm.bin mt7916_wa.bin; do
		a=$(md5sum "$FW/$o" 2>/dev/null | cut -c1-10)
		b=$(md5sum "$SAVED/$o" 2>/dev/null | cut -c1-10)
		if [ "$a" = "$b" ]; then echo "  $o ours"; else echo "  $o OTHER ($a vs $b)"; fi
	done
	echo "== driver =="
	basename "$(readlink "/sys/bus/pci/devices/$DEV/driver" 2>/dev/null)" 2>/dev/null || echo "  unbound"
	echo "== firmware versions the card reported =="
	dmesg | busybox grep -E 'Firmware Version|rom patch|WACPU|request firmware' | busybox tail -8
}

case "${1:-status}" in
	save) save ;;
	retry) retry ;;
	status) status ;;
	use)
		if [ "${2:-ours}" = vendor ]; then use_vendor; else use_ours; fi
		;;
	*)
		echo "usage: fw-ab save|use ours|use vendor|retry|status"
		return 1 2>/dev/null || exit 1
		;;
esac
