// Take a finished build's images and turn them into a flashable E2631 factory
// package, then verify it independently. Everything stays in this workspace;
// the official template package never leaves the machine.
//
//   node build/host/release.mjs --dir out/<build>        # local build (the normal path)
//   node build/host/release.mjs --run <runId>            # only if you did use Actions
//   [--template <official.bin>] [--out <file>]
//
// Run it from the workspace root: inputs that are not part of the repo (out/,
// 升级包/, the base tree clones) are resolved against the current directory, while
// the repo's own scripts are found through this file's location.
//
// Steps: fetch payload -> find kernel + rootfs -> mkfactory pack ->
//        verify_pkg (independent re-derivation) -> print sha256 and slot budget.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));	// <repo>/host
const REPO = path.join(HERE, '..');
const arg = (n, d) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : d; };
const run = arg('--run');
const TEMPLATE = arg('--template', '升级包/zxhne2631_hv100_fv1008b88000_firmware-20260916183918.bin');
const ROOTFS_AT = arg('--rootfs-at', '0x400000');
const HEADER_AT = arg('--header-at', '0x1400000');
const OUT = arg('--out', 'out/e2631-openwrt-factory.bin');
const DTS = path.join(REPO, 'overlay/target/linux/sanechips/dts/zx279128s-zte-zxhn-e2631.dts');
const LOCAL = arg('--dir');	// a directory already holding kernel/root, to test this script
if (!run && !LOCAL) { console.error('usage: release.mjs --run <runId> [--template f] [--out f] | --dir <dir>'); process.exit(2); }
fs.mkdirSync('out', { recursive: true });

const token = execFileSync('git', ['credential', 'fill'], {
  input: 'protocol=https\nhost=github.com\n\n', encoding: 'utf8',
}).split('\n').find((l) => l.startsWith('password='))?.slice(9);
if (!token && !LOCAL) { console.error('no github credential from git credential fill'); process.exit(1); }
// Which repository this is, straight from the origin remote: the project was renamed once
// already, and a hardcoded slug would silently point release.mjs at the wrong repo.
const SLUG = (() => {
  const url = execFileSync('git', ['-C', REPO, 'remote', 'get-url', 'origin'], { encoding: 'utf8' }).trim();
  const m = /github\.com[:/]([\w.-]+\/[\w.-]+?)(?:\.git)?$/.exec(url);
  if (!m) { console.error(`cannot read the GitHub slug from origin (${url})`); process.exit(1); }
  return m[1];
})();
const API = `https://api.github.com/repos/${SLUG}`;
const get = async (url, binary) => {
  const r = await fetch(url, { headers: { Authorization: `token ${token}`, Accept: 'application/vnd.github+json' }, redirect: 'follow' });
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  return binary ? Buffer.from(await r.arrayBuffer()) : r.json();
};

let dir = LOCAL;
if (!dir) {
  const arts = (await get(`${API}/actions/runs/${run}/artifacts`)).artifacts;
  if (!arts?.length) throw new Error('the run produced no artifacts');
  const a = arts.find((x) => x.name === 'e2631-images') || arts[0];
  console.log(`artifact: ${a.name}  ${a.size_in_bytes} B  (expired=${a.expired})`);
  const zip = path.join('out', `${a.name}-${run}.zip`);
  // The field is archive_download_url; download_url only exists on the
  // workflow-run object. The endpoint 302s to a signed blob URL, so fetch has
  // to follow it and the body has to be read as bytes, not parsed as JSON.
  const url = a.archive_download_url || a.download_url;
  if (!url) throw new Error(`artifact ${a.name} carries no download url: ${JSON.stringify(Object.keys(a))}`);
  fs.writeFileSync(zip, await get(url, true));
  dir = path.join('out', `artifacts-${run}`);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  execFileSync('unzip', ['-q', '-o', zip, '-d', dir]);
}

const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
let files = walk(dir);
// The sysupgrade file is itself a tar with kernel and root inside, so an
// artifact that only got that far is still enough.
if (!files.some((f) => path.basename(f) === 'kernel') && !files.some((f) => path.basename(f) === 'root')) {
  const sx = files.find((f) => /sysupgrade.*\.bin$/.test(f));
  if (sx) {
    fs.mkdirSync(path.join(dir, 'payload'), { recursive: true });
    execFileSync('tar', ['-xf', sx, '-C', path.join(dir, 'payload')]);
    console.log(`unpacked ${path.basename(sx)} locally`);
    files = walk(dir);
  }
}
// The CI step unpacks the sysupgrade tar, so the payload members are the
// stable names kernel/root; the old build_dir names stay as a fallback.
const kernel = files.find((f) => path.basename(f) === 'kernel') ||
  files.find((f) => /(?:^|\/)[^/]*kernel\b[^/]*$/.test(f) && !/sysupgrade|factory|\.tar|\.manifest|\.buildinfo/.test(f));
const rootfs = files.find((f) => path.basename(f) === 'root') ||
  files.find((f) => /rootfs.*\.bin$/.test(f) && !/sysupgrade|factory/.test(f));
if (!kernel || !rootfs) throw new Error(`could not find kernel/rootfs in:\n  ${files.join('\n  ')}`);
const kb = fs.readFileSync(kernel), rb = fs.readFileSync(rootfs);
console.log(`kernel : ${kernel}  ${kb.length} B  first32=${kb.subarray(0, 32).toString('hex').slice(0, 24)}…`);
console.log(`rootfs : ${rootfs}  ${rb.length} B  magic=${rb.subarray(0, 4).toString('latin1')}`);
const HAT = parseInt(HEADER_AT, 16);
if (kb.length + 32 > parseInt(ROOTFS_AT, 16))
  throw new Error(`kernel ${kb.length} B does not fit below the rootfs offset ${ROOTFS_AT}`);
if (rb.length > HAT - parseInt(ROOTFS_AT, 16))
  throw new Error(`rootfs ${rb.length} B does not fit the 0x${(HAT - parseInt(ROOTFS_AT, 16)).toString(16)} between ${ROOTFS_AT} and the header block at ${HEADER_AT}`);
if (HAT + 0x20000 > 0x1c00000)
  throw new Error('the padded layout does not fit a 28 MiB slot');
// The four official E2631 packages put their rootfs right behind a kernel
// extent of 0x380000 (4B4) or 0x340000 (6B5/7B5/8B8) - which is exactly
// ceil(declared kernel size / 128k), the rule cspboot actually uses to find the
// rootfs (it was seen ignoring the header's own rootfs offset on the serial
// console). We therefore declare the padded 4 MiB region as the kernel extent,
// which pins the rootfs at slot + 0x400000 where the board DTS says it lives.
// 0x380000 is still the largest kernel extent the bootloader has ever been seen
// to *really* carry, so keep the actual kernel below that; the padding in
// between only makes cspboot read more zeroes into its staging buffer.
if (kb.length + 32 > 0x380000)
  console.log(`\nWARNING: kernel extent 0x${(kb.length + 32).toString(16)} is larger than the ` +
    'largest official one (0x380000).\ncspboot has only ever been observed to load up to that; ' +
    'a bigger kernel is unproven.\n');

execFileSync(process.execPath, [path.join(REPO, 'tools/mkfactory.mjs'), 'pack', '--template', TEMPLATE,
  '--kernel', kernel, '--rootfs', rootfs, '--rootfs-at', ROOTFS_AT,
  '--header-at', HEADER_AT, '--out', OUT], { stdio: 'inherit' });

console.log('\n--- independent verification of the package ---');
try {
  execFileSync(process.execPath, [path.join(HERE, 'verify_pkg.mjs'), OUT, '--dts', DTS, '--template', TEMPLATE], { stdio: 'inherit' });
} catch {
  console.error('\nverify_pkg rejected the package - do not flash it');
  process.exit(1);
}
const crypto = await import('node:crypto');
// Passing the bootloader's CRC gates only says the bytes are accepted. Whether
// the system then runs is a separate question, and a hang after flash may not
// fall back by itself, so the same artifact is also checked for the things that
// stop a boot: root= vs the partition order, built-in flash/squashfs drivers,
// the command line that has to beat the vendor bootargs, USB and watchdog nodes.
const has = (pred) => files.some((f) => pred(path.basename(f)));
const missing = [['e2631.dtb', (b) => b === 'e2631.dtb'],
  ['config-<kernel version>', (b) => /^config-[0-9]/.test(b)]]
  .filter(([, p]) => !has(p)).map(([n]) => n);
if (missing.length) {
  console.error(`\nthis artifact has no ${missing.join(' or ')}: boot readiness cannot be checked.`);
  console.error('Stopping here on purpose - "the package passes the bootloader CRCs" is not the');
  console.error('definition of done, and a slot that hangs at startup does not fall back itself.');
  process.exit(1);
}
console.log('\n--- boot readiness (dtb + kernel .config + payload) ---');
// A local clone of the base tree gives the config checks a second witness: the
// .config in an artifact is whichever build phase wrote it last.
const TREE = ['owrt-up', 'openwrt', '_base/owrt'].find((t) => fs.existsSync(path.join(t, 'target/linux/generic')));
if (TREE) console.log(`config fragments from: ${TREE}`);
try {
  execFileSync(process.execPath, [path.join(REPO, 'tools/verify_img.mjs'), dir, ...(TREE ? ['--tree', TREE, '--target', 'sanechips'] : [])], { stdio: 'inherit' });
} catch {
  console.error('\nverify_img found something that can stop the boot - do not flash it');
  process.exit(1);
}

const buf = fs.readFileSync(OUT);
console.log(`\nready to flash: ${OUT}`);
console.log(`  size   ${buf.length} B (${(buf.length / 1048576).toFixed(2)} MiB, slot is 28 MiB)`);
console.log(`  sha256 ${crypto.createHash('sha256').update(buf).digest('hex')}`);
// Put the cross-built slot tool where host/stage.mjs looks for it by default:
// it is what writes the first image from the vendor side.
const tool = files.find((f) => path.basename(f) === 'e2631-fwslot');
if (tool) {
  fs.copyFileSync(tool, 'out/e2631-fwslot');
  console.log(`  tool   out/e2631-fwslot  ${fs.statSync('out/e2631-fwslot').size} B, static`);
} else {
  console.log('  tool   not in this artifact (run predates the collect change)');
}
console.log('\nnext:  node build/host/stage.mjs put         # deliver both, then "info" + "check" (no write)' +
  '\n       node build/host/stage.mjs flash --yes   # write the INACTIVE slot; needs your go-ahead');
