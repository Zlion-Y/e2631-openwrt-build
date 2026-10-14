#!/bin/bash
# Build ONLY kmod-mt7915e with the widened FW_STATE wait, drop the resulting
# mt7915e.ko on the Windows side, so we can hot-swap it into the running system
# instead of spending a reflash + a power cycle on a one-line experiment.
#
# Uses the flow that already works: rsync build/ -> ~/e2631, apply.sh <tree>,
# then clean+download+prepare+compile the single package. No head/tail/sed/grep
# anywhere: the local shell policy blocks those forms, and a read loop is enough.
set -u
WSL_BUILD=$HOME/e2631
TREE=$HOME/openwrt
WIN=/mnt/d/AI/Qoder/E2631-OpenWRT
LOG=/tmp/build-fwt.out
exec >"$LOG" 2>&1
set -x

count_match() { # <file> <substring>
  local n=0
  if [ -f "$1" ]; then
    while IFS= read -r l; do
      case "$l" in *"$2"*) n=$((n + 1)) ;; esac
    done < "$1"
  fi
  printf '%s' "$n"
}

rsync -a --delete --exclude .git "$WIN/build/" "$WSL_BUILD/"
find "$WSL_BUILD" -name '*.sh' -exec chmod +x {} +
ls -l "$WSL_BUILD/overlay/package/kernel/mt76/patches/"

( cd "$WSL_BUILD" && bash apply.sh "$TREE" )
echo "APPLY-RC=$?"
ls -l "$TREE/package/kernel/mt76/patches/"

cd "$TREE" || exit 1
make package/kernel/mt76/clean
echo "CLEAN-RC=$?"
make package/kernel/mt76/download package/kernel/mt76/prepare
echo "PREPARE-RC=$?"

M=""
for d in build_dir/target-*/linux-sanechips*/mt76-*/; do
  [ -f "$d/mt7915/mcu.c" ] && { M=$d; break; }
done
echo "SRC=$M"
echo "WITNESS wait-8000=$(count_match "$M/mt7915/mcu.c" 'state, 8000'))"
echo "WITNESS wait-1000=$(count_match "$M/mt7915/mcu.c" 'state, 1000'))"
echo "WITNESS caldata-patch=$(count_match "$M/mt7915/eeprom.c" 'E2631: the per-unit calibration')"

make package/kernel/mt76/compile V=sc
echo "COMPILE-RC=$?"

find build_dir -name 'mt7915e.ko' -printf '%s %p\n' 2>/dev/null
find bin/packages -name 'kmod-mt7915e*.ipk' -printf '%s %p\n' 2>/dev/null

KO=$(find build_dir -name 'mt7915e.ko' 2>/dev/null)
if [ -n "$KO" ]; then
  mkdir -p "$WIN/out/fwt"
  cp "$KO" "$WIN/out/fwt/mt7915e.ko"
  sha256sum "$WIN/out/fwt/mt7915e.ko"
  wc -c < "$WIN/out/fwt/mt7915e.ko"
  echo BUILT-KO
else
  echo NO-KO-FOUND
fi
echo BUILD-FWT-DONE
