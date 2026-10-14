#!/bin/bash
# Turn on CONFIG_DEVMEM (and off CONFIG_IO_STRICT_DEVMEM) the way this tree
# actually answers: appended to the TARGET fragment. Proof it is the target file
# that wins: CONFIG_MAGIC_SYSRQ_SERIAL and CONFIG_PCIEPORTBUS, which apply.sh
# appends there, are present in the built .config, while symbols flipped in
# target/linux/generic/config-6.18 (SOFTLOCKUP_DETECTOR, DEVMEM) are not.
set -u
TREE=$HOME/openwrt
CFG=$TREE/target/linux/sanechips/config-6.18
LOG=/tmp/devmem-enable.out
exec >"$LOG" 2>&1

MARK='# e2631: /dev/mem so FW_STATE can be read without a driver'
[ -f "$CFG" ] || { echo "missing $CFG"; exit 1; }

# idempotent: drop any previous block, then append
tmp=/tmp/sanechips.cfg.new
: > "$tmp"
keep=1
while IFS= read -r l; do
  case "$l" in
    "$MARK") keep=0; continue ;;
  esac
  case "$keep" in
    0) case "$l" in CONFIG_DEVMEM=*|'# CONFIG_IO_STRICT_DEVMEM'*) continue ;; esac; keep=1 ;;
  esac
  printf '%s\n' "$l" >> "$tmp"
done < "$CFG"
printf '%s\n' "$MARK" >> "$tmp"
printf 'CONFIG_DEVMEM=y\n' >> "$tmp"
printf '# CONFIG_IO_STRICT_DEVMEM is not set\n' >> "$tmp"
mv "$tmp" "$CFG"

echo "== tail of the target fragment"
i=0
tot=$(wc -l < "$CFG")
while IFS= read -r l; do
  i=$((i + 1))
  [ $i -gt $((tot - 8)) ] && printf '  %s\n' "$l"
done < "$CFG"

cd "$TREE" || exit 1
make target/linux/clean >>"$LOG" 2>&1
echo "CLEAN-RC=$?"
make target/linux/prepare >>"$LOG" 2>&1
echo "PREPARE-RC=$?"
K=""
for d in build_dir/target-*/linux-sanechips*/linux-*/; do
  [ -f "$d/.config" ] && { K=$d; break; }
done
echo "K=$K"
n=$(count=0; while IFS= read -r l; do case "$l" in CONFIG_DEVMEM=y) count=$((count+1));; esac; done < "$K/.config"; echo $count)
echo "WITNESS kernel-dotconfig-devmem=$n (want 1)"
o=$(count=0; while IFS= read -r l; do case "$l" in CONFIG_IO_STRICT_DEVMEM=y) count=$((count+1));; esac; done < "$K/.config"; echo $count)
echo "WITNESS kernel-dotconfig-io-strict=$o (want 0)"
# also make sure the target fragment change survived
f=$(count=0; while IFS= read -r l; do case "$l" in CONFIG_DEVMEM=y) count=$((count+1));; esac; done < "$CFG"; echo $count)
echo "WITNESS target-fragment-devmem=$f (want >=1)"
echo DEVMEM-ENABLE-DONE
