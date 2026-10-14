#!/bin/sh
# Dump PCI config space for every enumerated device, as one contiguous hex
# string per device, for decoding off-box (out/decode_cfg.mjs).
#
# Deliberately dumb: only dd/hexdump and a loop.  Endianness and register
# decoding live in the Node tool, which is testable against the vendor's own
# captured config space (board/backup/vendor-ep*-config.txt).
#
# Usage:  sh mpscfg.sh dump            # read-only, ~8 KB of text
#         sh mpscfg.sh fix <dev> <off> <hex16>   # write one 16-bit register
set -u

MODE=${1:-dump}

if [ "$MODE" = fix ]; then
	dev=$2; off=$3; val=$4
	cfg="/sys/bus/pci/devices/$dev/config"
	[ -w "$cfg" ] || { echo "no writable config for $dev"; exit 1; }
	v=$(( val / 1 ))	# accept 0xNNNN or decimal-ish input
	lo=$(( v % 256 )); hi=$(( v / 256 ))
	before=$(dd bs=1 skip="$off" count=2 if="$cfg" 2>/dev/null | hexdump -v -e '1/1 "%02x"')
	esc=$(printf '\\%03o\\%03o' "$lo" "$hi")
	printf "$esc" | dd bs=1 count=2 of="$cfg" seek="$off" conv=notrunc 2>/dev/null
	after=$(dd bs=1 skip="$off" count=2 if="$cfg" 2>/dev/null | hexdump -v -e '1/1 "%02x"')
	echo "bytes at $off: before=$before after=$after expect=$(printf '%02x%02x' "$lo" "$hi")"
	exit 0
fi

for d in /sys/bus/pci/devices/*; do
	[ -r "$d/config" ] || continue
	printf '@@@ %s ' "${d##*/}"
	[ -e "$d/driver" ] && printf 'driver=%s ' "$(basename "$(readlink "$d/driver")")"
	printf 'hdr=%s ' "$(dd bs=1 skip=0 count=16 if="$d/config" 2>/dev/null | hexdump -v -e '1/1 "%02x"')"
	printf 'class=%s\n' "$(dd bs=1 skip=8 count=4 if="$d/config" 2>/dev/null | hexdump -v -e '1/1 "%02x"')"
	hexdump -v -e '1/1 "%02x"' "$d/config"
	printf '\n'
done
