# wsl/ - the build path, the patch generators, and the evidence tools

Everything here runs inside the WSL build box (`~/openwrt` tree, this repo at
`~/e2631`). `bash -n` for all of them is gated by `lint-kit.sh`.

Grouped by what they are for, because the file count is the price of recording
how each conclusion was reached:

## Build path (run these in order)

| script | what it does |
|---|---|
| `sync.sh` | copy the workspace repo into `~/e2631` so the build sees it |
| `apply.sh` (repo root) | overlay onto the tree - run through `build.sh`, not by hand |
| `build.sh` | full local `make world`, with the download workarounds in README.md |
| `collect.sh <out-dir>` | lay the result out the way the CI artifact does, for `tools/mkfactory.mjs` / release screening |
| `status.sh`, `probe.sh` | one-line "what phase is the build in, is it still running" |
| `kick-build.sh`, `killbuild.sh` | launch detached / stop whatever is running (patterns bracketed so the killer cannot kill itself) |
| `segdl.sh`, `parget.sh` | segmented parallel GET for distfiles |

## Patch generators (never hand-write a patch)

| script | generates |
|---|---|
| `gen-efuse-patch.sh` | mt76 `002-mt7915-use-caldata-file-before-efuse.patch` - lands the caldata file before the efuse round-trips |
| `gen-retrain-patch.sh` | kernel `031-pci-gate-link-retrain-speed-lift-by-vendor-device.patch` - re-gates the 2.5 GT/s speed lift by Vendor:Device |
| `gen-fwtimeout-patch.sh` | `003-mt7915-wait-longer-for-fw-state.patch` (1 s -> 8 s) - **deferred, and falsified**: the widened wait still hung on a cold bind, so it is not in the build |

Each generator writes the patch from the source the build actually uses and then
proves `APPLIED == GENERATED`; a hand-written patch in this tree failed to apply
once (`malformed patch at line 37`).

## Witnesses (proof the fix is in the artifact, not just the source)

`check-patch31.sh` (dry-run a kernel patch before spending a build), `land-patch.sh`,
`verify-efusefix.sh` / `2` / `3` (three iterations of the same witness - the function
is inlined, so the final one keys off the caller's relocations),
`verify-gen1-kernel.sh` (disassemble the booted kernel to see `bl pci_match_id`),
`verify-fwt-ko.sh` + `stage-fwt-ko.sh` + `build-fwtimeout-ko.sh` (build only the kmod),
`build-regprobe.sh` (the `/dev/mem` replacement - see below),
`mt7915-readl-gap.sh`, `which-mt7915-src.sh` (the kernel tree and the feed both carry
mt7915; only one builds the .ko), `check-apply.sh`, `debug-apply.sh`, `show-eeprom-load.sh`,
`final-root-check.sh`, `final-root-check2.sh`, `lint-kit.sh`, `sh-lint.sh`.

## Probes that answered a question and are kept so the answer can be re-checked

`mps-static.sh`, `mps-selftest.sh`, `test-boardspeed.sh` (config-space decode, offline),
`dwc-linkspeed.sh` (our host controller driver does not read `max-link-speed`),
`iolock-coverage.sh`, `check-iolock.sh` (the L2 cache IO-lock patch vs mt7915's reads),
`retrain-quirk-check.sh` (found the un-gated `pcie_failed_link_retrain()`),
`l2c-auxctl-decode.sh`, `read-mt7915-eeprom.sh`,
`mtk-disasm.sh`, `mtk-disasm-init.sh`, `mtk-fw-symbols.sh`, `mtk-init-sequence.sh`,
`vendor-ko-family.sh` (the stock `mt7916.ko` is MTK's proprietary driver, not mt76),
`vendor-dtb-wdt.sh`, `wdt-check.sh`, `twd-wdt-check.sh`, `twd-driver-name.sh`
(no watchdog can self-recover from an IRQs-off hang here),
`failsafe-check.sh`, `failsafe-route.sh` (failsafe is the way back in without serial TX),
`pull-log.sh` (copy a WSL log into the workspace so it can be read).

`enable-devmem.sh` is kept as the record of a dead end, with the caveat that the reason
is still unknown: the shipped kernel config (`out/gen1/config-6.18:2314`) reads
`# CONFIG_DEVMEM is not set` while both fragments (`generic/config-6.18:1494`,
`sanechips/config-6.18:147`) read `CONFIG_DEVMEM=y` and nothing anywhere asks for n -
`drivers/char/Kconfig:311` is a plain "bool / default y". So the request is dropped
somewhere in kconfig resolution; do not spend a build guessing. Read the MT7916's
`MT_TOP_MISC` with the module `build-regprobe.sh` produces instead.
