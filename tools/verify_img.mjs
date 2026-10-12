// Static boot-readiness check for the E2631 image.
//
// A package can pass every CRC the bootloader looks at and still not boot: wrong
// root= device, a driver that is a module when the root needs it built in, a USB
// or watchdog driver that hangs this SoC family. Those are the failures that
// leave the box in a slot it cannot fall back from, so they are checked here,
// before anything is written.
//
//   node tools/verify_img.mjs <dir>
//     <dir>/payload/kernel          uImage with the 32-byte ZTE slot marker
//     <dir>/payload/root            squashfs root filesystem
//     <dir>/e2631.dtb               the board .dtb as the kernel sees it
//     <dir>/config-*                the built kernel .config
//
// Exit code is non-zero if anything that can stop a boot is wrong.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const dir = process.argv[2];
if (!dir || !fs.existsSync(dir)) { console.error('usage: verify_img.mjs <artifact dir>'); process.exit(2); }

const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) =>
  e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
const files = walk(dir).map((f) => f.split(path.sep).join('/'));   // match on / regardless of host OS
const find = (re) => files.find((f) => re.test(f));

let fails = 0, warns = 0;
const ok = (name, cond, detail = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? '  ' + detail : ''}`);
  if (!cond) fails++;
};
const warn = (name, cond, detail = '') => {
  console.log(`${cond ? 'PASS' : 'WARN'}  ${name}${detail ? '  ' + detail : ''}`);
  if (!cond) warns++;
};
const hx = (n) => '0x' + (n >>> 0).toString(16);
// dtc keeps the terminating NUL *inside* the property value (measured on the
// H3600 dtb: a label is stored as 6c 61 6e 31 00), so every string that gets
// compared has to be cut at the first NUL. Forgetting that makes a comparison
// silently false - and a false pass here is worse than a failure.
const sval = (b) => (b ? b.toString('latin1') : '').replace(/\0[\s\S]*$/, '');
// A compatible property is a list of NUL-terminated strings: cutting it at the
// first NUL would hide every later match, so those are joined with spaces.
const cval = (b) => (b ? b.toString('latin1') : '').replace(/\0+/g, ' ').trim();

/* -------------------------------- flat device tree ------------------------ */
// Enough of the format to read node names, properties and the #address/#size
// cells of a reg list; the checks below work on the tree the kernel is handed.
function fdtParse(buf) {
  if (buf.readUInt32BE(0) !== 0xd00dfeed) throw new Error('not a dtb (magic)');
  const total = buf.readUInt32BE(4), offStruct = buf.readUInt32BE(8), offStr = buf.readUInt32BE(12);
  if (total > buf.length) throw new Error(`dtb totalsize ${total} > file ${buf.length}`);
  const str = (o) => {
    let s = '', i = offStr + o;
    while (i < buf.length && buf[i]) s += String.fromCharCode(buf[i++]);
    return s;
  };
  let p = offStruct, end = offStruct + buf.readUInt32BE(36);
  // The stream opens with a BEGIN_NODE for the real root: that node is the
  // root, not a child of one. Wrapping it hid model, memory and cpus from every
  // lookup below and each of those checks then failed as "not found".
  let root = null;
  const stack = [];
  const be32 = (o) => buf.readUInt32BE(o);
  while (p < end) {
    const t = be32(p); p += 4;
    if (t === 4) continue;                                   // NOP
    if (t === 9) break;                                      // END
    if (t === 1) {                                           // BEGIN_NODE
      let n = '';
      while (buf[p]) n += String.fromCharCode(buf[p++]);
      p = (p + 4) & ~3;                                    // past the NUL, then align
      const node = { name: n, props: {}, children: [] };
      if (root) stack[stack.length - 1].children.push(node);
      else root = node;
      stack.push(node);
    } else if (t === 2) {                                    // END_NODE
      stack.pop();
    } else if (t === 3) {                                    // PROP
      const len = be32(p), nameOff = be32(p + 4);
      const data = buf.subarray(p + 8, p + 8 + len);
      p = (p + 8 + len + 3) & ~3;
      stack[stack.length - 1].props[str(nameOff)] = data;
    } else throw new Error(`unknown fdt token ${t} at ${p - 4}`);
  }
  return root;
}
const fdtFind = (node, name) => node.children.find((c) => c.name === name || c.name.split('@')[0] === name);
const cells = (node) => ({
  a: node.props['#address-cells'] ? node.props['#address-cells'].readUInt32BE(0) : 1,
  s: node.props['#size-cells'] ? node.props['#size-cells'].readUInt32BE(0) : 1,
});
const regList = (node, ac = 1, sc = 1) => {
  const r = node.props.reg;
  if (!r) return null;
  const out = [];
  for (let i = 0; i + ac * 4 + sc * 4 <= r.length; i += (ac + sc) * 4) {
    let addr = 0, size = 0;
    for (let k = 0; k < ac; k++) addr = addr * 0x100000000 + r.readUInt32BE(i + k * 4);
    for (let k = 0; k < sc; k++) size = size * 0x100000000 + r.readUInt32BE(i + ac * 4 + k * 4);
    out.push({ addr: Number(addr), size: Number(size) });
  }
  return out;
};

/* ------------------------------ the kernel image -------------------------- */
// The CI unpacks the sysupgrade tar next to the kernel .config and the board
// .dtb; a locally unpacked copy has the members under sysupgrade-<profile>/, so
// match on the file name with the payload/ form preferred.
const pick = (exact, loose) => find(exact) || files.find((f) => loose.test(path.basename(f)));
const kernelFile = pick(/payload\/kernel$/, /^kernel$/);
const rootFile = pick(/payload\/root$/, /^root$/);
const dtbFile = pick(/e2631\.dtb$/, /dtb$/);
const confFile = pick(/(^|\/)config-[0-9]/, /^config-[0-9]/);
for (const [what, f] of [['kernel', kernelFile], ['root', rootFile]])
  if (!f) { console.error(`missing ${what} in ${dir}`); process.exit(1); }
// The standalone .dtb and the kernel .config came with a later collect step; an
// older artifact still carries the dtb appended to the kernel image.
const haveDtb = !!dtbFile, haveConf = !!confFile;
if (!haveDtb) console.log('NOTE   no standalone .dtb here: the one appended to the kernel is used');
if (!haveConf) console.log('NOTE   no kernel .config here: the config-side checks are skipped, not passed');
const okC = (name, cond, detail) => { if (haveConf) ok(name, cond, detail); };

const img = fs.readFileSync(kernelFile);
const MARKER = Buffer.from('33333333cccccccc88888888ddddddddffffffffffffffffffffffffffffffff', 'hex');
ok('kernel starts with the 32-byte ZTE slot marker', img.subarray(0, 32).equals(MARKER));
const u = img.subarray(32);
ok('uImage magic right after the marker', u.readUInt32BE(0) === 0x27051956, hx(u.readUInt32BE(0)));
const ihSize = u.readUInt32BE(12), ihLoad = u.readUInt32BE(16), ihEp = u.readUInt32BE(20);
ok('uImage data CRC (ih_dcrc)', (zlib.crc32(u.subarray(64, 64 + ihSize)) >>> 0) === u.readUInt32BE(24),
  `stored ${hx(u.readUInt32BE(24))}`);
ok('load == entry == 0x40008000 (both vendor slots use this)', ihLoad === 0x40008000 && ihEp === 0x40008000,
  `${hx(ihLoad)} / ${hx(ihEp)}`);
ok('uImage: Linux on ARM, type kernel, comp none', u[28] === 5 && u[29] === 2 && u[30] === 2 && u[31] === 0,
  `os=${u[28]} arch=${u[29]} type=${u[30]} comp=${u[31]}`);
ok('image name names this build', /Linux|OpenWrt/i.test(u.subarray(32, 64).toString('latin1')),
  JSON.stringify(u.subarray(32, 64).toString('latin1').replace(/\0.*$/, '')));
const tail = u.subarray(64, 64 + ihSize);

// zImage with an appended .dtb: the header magic is stored little endian at
// +0x24, and the .dtb is the last thing in the image with its BE declared size
// covering exactly that tail (checked against the H3600 kernel in _scratch2).
ok('zImage self-extracting header magic (LE 0x016f2818 at +0x24)',
  tail.readUInt32LE(0x24) === 0x016f2818, hx(tail.readUInt32LE(0x24)));
let dtbOff = -1;
for (let i = Math.max(0, tail.length - 0x80000); i + 8 <= tail.length; i += 4)
  if (tail.readUInt32BE(i) === 0xd00dfeed && i + tail.readUInt32BE(i + 4) === tail.length) { dtbOff = i; break; }
ok('a .dtb is appended and ends the kernel image', dtbOff >= 0,
  dtbOff >= 0 ? `at +${hx(dtbOff)}, ${(tail.length - dtbOff).toString(16)} bytes` : 'not found');
let dtbBuf = null;
if (dtbOff >= 0) {
  dtbBuf = tail.subarray(dtbOff);
  try {
    if (haveDtb) {
      const e = fdtParse(dtbBuf), file = fdtParse(fs.readFileSync(dtbFile));
      ok('the dtb in the kernel equals the one built for this board',
        sval(e.props.model) === sval(file.props.model));
    }
  } catch (err) { ok('the dtb inside the kernel parses', false, err.message); }
}
if (haveDtb) dtbBuf = fs.readFileSync(dtbFile);
if (!dtbBuf) { console.error('FAIL  no device tree to check (neither .dtb nor an appended one)'); process.exit(1); }

/* -------------------------------- squashfs -------------------------------- */
const sq = fs.readFileSync(rootFile);
ok('rootfs is a squashfs image', sq.subarray(0, 4).toString('latin1') === 'hsqs',
  `magic=${sq.subarray(0, 4).toString('latin1')}`);
// Field offsets measured against the H3600 root in _scratch2 (a real OpenWrt
// squashfs): +12 is the block size (0x40000) and +40 the total used size
// (0x490faa of a 0x491000 file).
const sqUsed = sq.readUInt32LE(40), sqBlock = sq.readUInt32LE(12);
ok('squashfs reports a size inside the file and a sane block size',
  sqUsed > 96 && sqUsed <= sq.length && sqBlock >= 4096 && sqBlock <= 0x100000,
  `used=${hx(sqUsed)} file=${hx(sq.length)} block=${hx(sqBlock)}`);

/* ------------------------------ the board dtb ----------------------------- */
const dtb = fdtParse(dtbBuf);
const conf = haveConf ? fs.readFileSync(confFile, 'latin1') : '';
const kv = (name) => {
  const m = new RegExp(`^CONFIG_${name}=(.*)$`, 'm').exec(conf);
  return m ? m[1].replace(/^"|"$/g, '') : (/^# CONFIG_ is not set$/m, undefined);
};
const isNotSet = (name) => conf.includes(`# CONFIG_${name} is not set`) || kv(name) === undefined;

ok('dtb model and compatible', /E2631/i.test(sval(dtb.props.model)), cval(dtb.props.compatible));
const mem = fdtFind(dtb, 'memory');
const mreg = mem && regList(mem)[0];
ok('memory is the 256 MiB this board has, at 0x40000000',
  mreg && mreg.addr === 0x40000000 && mreg.size === 0x10000000,
  mreg ? `${hx(mreg.addr)} + ${hx(mreg.size)}` : 'no memory node');

// The partition list is what root= has to agree with.
const flash = (() => {
  const walk2 = (n) => {
    if (n.props.compatible && /spi-nand/.test(cval(n.props.compatible))) return n;
    for (const c of n.children) { const r = walk2(c); if (r) return r; }
    return null;
  };
  return walk2(dtb);
})();
const partsNode = flash && fdtFind(flash, 'partitions');
const parts = partsNode ? partsNode.children.filter((c) => c.props.reg) : [];
const table = [];
{
  const { a, s } = cells(partsNode || dtb);
  for (const p of parts) table.push({ label: sval(p.props.label), ...regList(p, a, s)[0] });
}
console.log('  partition order as the kernel will create it:');
table.forEach((t, i) => console.log(`    mtd${i}  ${t.label.padEnd(14)} ${hx(t.addr)} + ${hx(t.size)}  end ${hx(t.addr + t.size)}`));

const idxOf = (label) => table.findIndex((t) => t.label === label);
const SLOT1 = 0x2300000, SPAN = 0x1c00000;
const iRoot = idxOf('rootfs'), iData = idxOf('rootfs_data'), iSlot1 = idxOf('slot1');
ok('there is a partition labelled rootfs', iRoot >= 0, `mtd${iRoot}`);
ok('there is one labelled rootfs_data (the overlay)', iData >= 0, `mtd${iData}`);
ok('slot1 spans the whole 28 MiB slot', iSlot1 >= 0 && table[iSlot1].addr === SLOT1 && table[iSlot1].size === SPAN);
ok('rootfs is where our package puts it (slot1 + 0x800000)',
  iRoot >= 0 && table[iRoot].addr === SLOT1 + 0x800000 && table[iRoot].size === 0x800000,
  iRoot >= 0 ? `${hx(table[iRoot].addr)} + ${hx(table[iRoot].size)}` : '-');
ok('rootfs_data starts after the version header block and ends at the slot end',
  iData >= 0 && table[iData].addr === SLOT1 + 0x1020000 &&
  table[iData].addr + table[iData].size === SLOT1 + SPAN,
  iData >= 0 ? `${hx(table[iData].addr)} + ${hx(table[iData].size)}` : '-');

// The command line baked into the kernel is the only root= the vendor bootargs
// cannot override, so it must name the mtdblock this very table produces.
const cmdline = (kv('CMDLINE') || '').replace(/\\\"/g, '"');
okC('CONFIG_CMDLINE_FORCE is on', kv('CMDLINE_FORCE') === 'y', 'the vendor bootargs would win otherwise');
const rm = /root=\/dev\/mtdblock(\d+)/.exec(cmdline);
okC('the built-in command line roots at the rootfs partition',
  rm && Number(rm[1]) === iRoot, `cmdline says mtdblock${rm ? rm[1] : '-'}, table says mtd${iRoot}`);
okC('the built-in command line asks for squashfs and waits', /rootfstype=squashfs/.test(cmdline) && /rootwait/.test(cmdline),
  cmdline);
// With the master registered as mtd0 the numbering above shifts by one.
okC('CONFIG_MTD_PARTITIONED_MASTER stays off', isNotSet('MTD_PARTITIONED_MASTER'));

/* --------------------- drivers the boot itself depends on ------------------ */
const needBuiltin = [
  ['MTD_SPI_NAND', 'the flash'],
  ['BLOCK', '/dev/ block devices at all'],
  ['MTD_BLOCK', '/dev/mtdblock*'],
  ['MTD_OF_PARTS', 'the partition table above'],
  ['DEVTMPFS', '/dev/mtdblock7 to exist when the root is mounted'],
  ['DEVTMPFS_MOUNT', 'the kernel mounting /dev before it opens the root'],
  ['SQUASHFS', 'the read-only root'],
  ['JFFS2_FS', 'the overlay'],
  // Not fatal to mounting the root, but fatal to seeing why: with the console
  // driver as a module there is no early print, no /dev/console before init and
  // no serial shell to work with if anything else goes wrong.
  ['SERIAL_AMBA_PL011_CONSOLE', 'the serial console'],
];
for (const [sym, why] of needBuiltin)
  okC(`CONFIG_${sym}=y (needed for ${why})`, kv(sym) === 'y', `is ${kv(sym) || 'unset'}`);
// The root filesystem has to be readable before /init runs, so its decompressor
// cannot be a module. OpenWrt picks mkfs' compression from this same config, so
// "at least one, built in" is the property that matters.
const decomps = ['ZLIB', 'LZO', 'XZ', 'LZ4', 'ZSTD'].filter((a) => kv(`SQUASHFS_${a}`) === 'y');
okC('the kernel builds in a squashfs decompressor', decomps.length > 0, decomps.join(', '));

// The user's own constraint, checked where it matters: this board family reboots
// when a controller that is not populated gets probed. Both are gated by the
// device tree, so the tree is what has to say "disabled".
const enabled = [];
const scan = (n, pathName) => {
  const c = cval(n.props.compatible), st = sval(n.props.status);
  const p = `${pathName}/${n.name}`;
  if (st === 'okay' && /(watchdog|wdt|dwc3|usb-[0-9a-f]|xhci|ehci|ohci)/i.test(c)) enabled.push(`${p} [${c}]`);
  n.children.forEach((k) => scan(k, p));
};
scan(dtb, '');
ok('no watchdog or USB controller node is enabled in the dtb', enabled.length === 0, enabled.join(', '));
const usbOn = ['USB_CORE', 'USB_EHCI_HCD', 'USB_OHCI_HCD', 'USB_XHCI_HCD',
  'USB_DWC3', 'USB_DWC3_OF_SIMPLE', 'USB_XHCI_PLATFORM'].filter((s) => kv(s) === 'y');
okC('no USB host stack built into the kernel', usbOn.length === 0, usbOn.join(', '));

// Without the platform symbol there is no platsmp and no zte,zx279128s-smp
// enable-method match, which is the difference between one CPU and two.
okC('CONFIG_SOC_ZX279128S=y (this SoC platform and its CPU hotplug)',
  kv('SOC_ZX279128S') === 'y', `is ${kv('SOC_ZX279128S') || 'unset'}`);

okC('CONFIG_VFP stays off (this SoC has none)', isNotSet('VFP'), kv('VFP') || 'not set');
okC('CONFIG_SMP is on (dual Cortex-A9)', kv('SMP') === 'y', `is ${kv('SMP') || 'unset'}`);
const cpus = dtb.children.find((c) => c.name.startsWith('cpus'));
const meth = (n) => (n ? sval(n.props['enable-method']) : '');
const method = meth(cpus) || meth(cpus && cpus.children[0]);
// Not fatal: with no match the kernel boots with one CPU and says so, but the
// second core is the reason the platform file exists.
warn('cpu enable-method matches the string the compiled platsmp registers',
  method === 'zte,zx279128s-smp', method || 'none');

/* ----------------------------- the package list ---------------------------- */
// The root filesystem is compressed, so the installed packages cannot be listed
// from it; the build's .manifest says what went in. A missing procd or fstools
// boots to a kernel that hangs at /init, and a missing e2631-fwslot would mean
// no way back to the stock slot from OpenWrt.
{
  const mf = files.find((f) => /\.manifest$/.test(f));
  if (!mf) console.log('NOTE   no .manifest in this artifact: package list NOT checked');
  else {
    const pkgs = new Set(fs.readFileSync(mf, 'utf8').split('\n')
      .map((l) => l.trim().replace(/^(?:add|install)\s+/, '').split(' - ')[0].trim())
      .filter(Boolean));
    console.log(`\nmanifest ${path.basename(mf)}: ${pkgs.size} packages`);
    const need = [
      ['base-files', '/etc, /lib/upgrade, board.d'],
      ['busybox', '/bin/sh and the applets'],
      ['procd', 'pid 1'],
      ['fstools', 'mount_root and the jffs2 overlay'],
      ['netifd', 'LAN and WAN'],
      ['uhttpd', 'the web interface'],
      ['e2631-fwslot', 'switching back to the stock slot'],
    ];
    for (const [p, why] of need) ok(`${p} is installed (${why})`, pkgs.has(p), pkgs.has(p) ? '' : 'not in the manifest');
  }
}

console.log(`\n${fails === 0 ? 'BOOT-READY: no static blocker found' : 'BLOCKERS: ' + fails}${warns ? ` (warnings: ${warns})` : ''}`);
process.exit(fails ? 1 : 0);
