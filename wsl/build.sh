#!/bin/bash
# Local build of the E2631 image inside WSL (Ubuntu 22.04, user `builder`,
# tree at ~/openwrt, this repo at ~/e2631). Same steps CI runs, but the
# network here is the constraint, not the CPU.
#
#   bash ~/e2631/wsl/build.sh
#
# Four traps this avoids, all of them hit in practice on this machine:
#  - a killed half-clone leaves a shallow feed repo whose next `git pull`
#    re-fetches the FULL history (luci: 427k objects, 20 idle minutes);
#  - a hand-cloned feed has no feeds/<name>.index, and `feeds install` then says
#    "Ignoring feed 'luci' - index missing" - the build still succeeds, just
#    without LuCI, silently;
#  - OpenWrt gives curl no transfer watchdog by default, so a mirror that
#    accepts the connection and sends nothing blocks the build forever;
#  - `make world` downloads each source the moment it needs it, so one 5 KB/s
#    mirror serialises the whole build (musl-1.2.6.tar.gz blocked a finished
#    toolchain for 5 minutes at 20 KB/s). Pre-fetching with `make download`
#    at high parallelism is what the download phase is for - the per-connection
#    cap does not add up when only one file is in flight.
set -x
export CURL_OPTIONS="--speed-limit 20000 --speed-time 20"
cd ~/openwrt || exit 1

E2631_GNU_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/gnu ~/e2631/apply.sh ~/openwrt || exit 1
grep -qx "CONFIG_CMDLINE_FORCE=y" target/linux/sanechips/config-6.18 || { echo "APPLY INCOMPLETE: no forced cmdline"; exit 1; }
grep -q "Makefile.e2631" target/linux/sanechips/image/Makefile || { echo "APPLY INCOMPLETE: image hook"; exit 1; }

for f in packages luci; do
  [ -d "feeds/$f/.git" ] || { echo "PHASE clone-$f $(date +%T)"; git clone -q --depth 1 --single-branch "https://github.com/openwrt/$f" "feeds/$f"; }
  [ -f "feeds/$f.index" ] || { echo "PHASE index-$f $(date +%T)"; ./scripts/feeds update "$f" 2>&1 | tail -3; }
done
echo "PHASE feeds-install $(date +%T)"
./scripts/feeds install -a 2>&1 | grep -E "Ignoring|Installing" | tail -8

echo "PHASE seed-config $(date +%T)"
cp ~/e2631/seed/e2631.config .config
make defconfig > /dev/null 2>&1
grep -cE '^CONFIG_PACKAGE_luci' .config
grep -E '^CONFIG_TARGET_DEVICE_sanechips_generic_DEVICE_zte_zxhn-e2631=|^CONFIG_SOFT_FLOAT=|^CONFIG_PACKAGE_luci=|^CONFIG_PACKAGE_luci-proto-ppp=|^CONFIG_PACKAGE_ttyd=|^CONFIG_PACKAGE_luci-app-ttyd=|^CONFIG_PACKAGE_uhttpd=' .config || echo "SEED CHECK FAILED"

echo "PHASE download $(date +%T)"
make -j"$(expr $(nproc) \* 3)" download > dl.log 2>&1
echo "PHASE download rc=$? $(date +%T)  cached=$(ls dl | wc -l) files"
grep -E "^Download failed|Problem : " dl.log | sort | uniq -c | tail -8

echo "PHASE build $(date +%T)"
make -j"$(nproc)" world V=s > world.log 2>&1
rc=$?
echo "PHASE done rc=$rc $(date +%T)"
grep -E "^(make.*\*\*\*|.*Error [0-9])" world.log | tail -5
