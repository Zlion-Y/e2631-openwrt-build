#!/bin/bash
echo "=== overlay side ==="
ls -l /mnt/d/AI/Qoder/E2631-OpenWRT/build/overlay/package/kernel/mt76/patches/ 2>&1
echo
echo "=== tree side ==="
ls -l ~/openwrt/package/kernel/mt76/patches/ 2>&1
echo
echo "=== what does apply.sh do at the end (rc=1 source)? ==="
tail -22 ~/e2631/apply.sh
echo
echo "=== apply.sh fresh run, only its own stdout/stderr ==="
cd ~/e2631 && bash apply.sh 2>&1 | tail -22
echo "apply rc=${PIPESTATUS[0]}"
echo
echo "=== tree patches after that ==="
ls -l ~/openwrt/package/kernel/mt76/patches/
echo
echo "=== the patch that is already in the tree (PR 25469?) ==="
head -45 ~/openwrt/package/kernel/mt76/patches/001-wifi-mt76-serialize-register-reads-with-outer-cache.patch
