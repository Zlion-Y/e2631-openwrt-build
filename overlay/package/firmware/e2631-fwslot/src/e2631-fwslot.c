// SPDX-License-Identifier: GPL-2.0-only
/*
 * e2631-fwslot - select and flash the ZTE ZXHN E2631 firmware slots from Linux.
 *
 * E2631 keeps two whole-system firmware slots in SPI NAND:
 *   slot 0 @ 0x00700000 .. 0x02300000   (28 MiB)
 *   slot 1 @ 0x02300000 .. 0x03F00000   (28 MiB)
 * and the vendor bootloader (cspboot) starts the valid slot with the higher
 * version-header serial; equal serials start slot 0.  Only CRC1 of the header
 * is checked by the bootloader, and CRC1 covers [0x00:0xa4] - which is before
 * the serial - so changing the serial never invalidates it.
 *
 * Images use the vendor upgrade package format, so one file installs from the
 * vendor web page or from OpenWrt sysupgrade, and the two systems can swap in
 * place.  Unlike the SR1010, an E2631 package carries no bootloader
 * (header +0x8c == 0) and its kernel extent is a plaintext uImage; only the
 * stock rootfs is AES-128-ECB at rest, and that decryption lives in the vendor
 * kernel's MTD read path, so a mainline kernel reads plain bytes.
 *
 * "switch" checks the other slot against the CRCs recorded in its header and
 * then rewrites only that header with a higher serial, so the next boot
 * selects it.  This is the way back to the vendor system without touching a
 * byte of its firmware body.
 *
 * Read/modify tool for the two firmware-slot partitions of this board only.
 * It never touches bootloader, tag, wifi or config partitions.
 */
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <mtd/mtd-user.h>

#define VER_HDR_SIZE	0x200
#define OUTER_HDR_SIZE	0x14
#define KERNEL_MAGIC_SIZE 32	/* 33333333 cccccccc 88888888 dddddddd + 16 x ff */
#define UBOOT_SIZE	0	/* E2631 upgrade packages carry no bootloader */

/* Version header fields, relative to the start of the 512-byte header. */
#define H_KEY1		0x08
#define H_KEY2		0x0c
#define H_VERSION	0x10
#define H_FW_SIZE	0x30	/* body size; also where the header lands when
				 * the body is block aligned, which stock is.
				 */
#define H_KERNEL_SIZE	0x34
#define H_KERNEL_FILEOFS 0x38
#define H_KERNEL_CRC	0x3c
#define H_FS_SIZE	0x40
#define H_FS_FILEOFS	0x44
#define H_FS_CRC	0x48
#define H_SLOT0		0x4c
#define H_SLOT0_SPAN	0x50
#define H_SLOT1		0x5c
#define H_SLOT1_SPAN	0x60
#define H_PRODUCT	0x6c
#define H_BOOT_INCLUDED 0x8c
#define H_UBOOT_CRC	0x98
#define H_CRC		0xa4	/* CRC32 over [0x00:0xa4] - checked by cspboot */
#define H_BUILD		0xa8
#define H_INTEGRITY	0xb8
#define H_INNER_MAGIC	0xf4
#define H_HWVER		0x110
#define H_SLottAB	0x1e0
#define H_SLOT_START	0x1f0
#define H_SERIAL	0x1f4
#define H_NEW		0x1f8
#define H_CRC2		0x1fc	/* CRC32 over [0x00:0x1fc] - covers the serial */

#define PRODUCT		"ZXHN E2631 V1.0.0"

/* The two firmware slots, by absolute offset in the whole flash. */
static const uint32_t slot_start[2] = { 0x00700000, 0x02300000 };
static const uint32_t slot_span = 0x01C00000;

/* Partition labels this tool expects in the board device tree. Looking up by
 * name rather than by /sys/.../offset keeps working on kernels that do not
 * export the partition offset.
 */
static const char *slot_label[2] = { "slot0", "slot1" };

static const uint8_t outer_magic[16] = {
	0x99,0x99,0x99,0x99, 0x44,0x44,0x44,0x44,
	0x55,0x55,0x55,0x55, 0xaa,0xaa,0xaa,0xaa,
};
static const uint8_t inner_magic[16] = {
	0x33,0x33,0x33,0x33, 0x66,0x66,0x66,0x66,
	0x99,0x99,0x99,0x99, 0xcc,0xcc,0xcc,0xcc,
};

static uint32_t crc_table[256];

static void crc_init(void)
{
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (int k = 0; k < 8; k++)
			c = (c & 1) ? 0xedb88320u ^ (c >> 1) : c >> 1;
		crc_table[i] = c;
	}
}

static uint32_t crc32_update(uint32_t c, const void *buf, size_t len)
{
	const uint8_t *p = buf;

	while (len--)
		c = crc_table[(c ^ *p++) & 0xff] ^ (c >> 8);
	return c;
}

static uint32_t crc32(const void *buf, size_t len)
{
	return crc32_update(0xffffffffu, buf, len) ^ 0xffffffffu;
}

static uint32_t rd32(const uint8_t *p, size_t ofs)
{
	return p[ofs] | p[ofs + 1] << 8 | p[ofs + 2] << 16 |
	       (uint32_t)p[ofs + 3] << 24;
}

static void wr32(uint8_t *p, size_t ofs, uint32_t v)
{
	p[ofs] = v; p[ofs + 1] = v >> 8;
	p[ofs + 2] = v >> 16; p[ofs + 3] = v >> 24;
}

static void die(const char *msg)
{
	fprintf(stderr, "e2631-fwslot: %s: %s\n", msg, strerror(errno));
	exit(1);
}

static long mtd_sysfs_u(int index, const char *attr)
{
	char path[64], buf[32];
	int fd, n;

	snprintf(path, sizeof(path), "/sys/class/mtd/mtd%d/%s", index, attr);
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return -1;
	buf[n] = 0;
	return strtol(buf, NULL, 0);
}

static void mtd_sysfs_s(int index, const char *attr, char *out, size_t len)
{
	char path[64], buf[128];
	int fd, n;

	out[0] = 0;
	snprintf(path, sizeof(path), "/sys/class/mtd/mtd%d/%s", index, attr);
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return;
	buf[n] = 0;
	if (n && buf[n - 1] == '\n')
		buf[n - 1] = 0;
	snprintf(out, len, "%s", buf);
}

/* Find the MTD partition carrying the given label. */
static int mtd_find_by_label(const char *label)
{
	DIR *d = opendir("/sys/class/mtd");
	struct dirent *e;
	int found = -1;
	char name[64];

	if (!d)
		die("open /sys/class/mtd");
	while ((e = readdir(d))) {
		int idx;

		if (sscanf(e->d_name, "mtd%d", &idx) != 1 || strchr(e->d_name, 'r'))
			continue;
		mtd_sysfs_s(idx, "name", name, sizeof(name));
		if (!strcmp(name, label)) {
			found = idx;
			break;
		}
	}
	closedir(d);
	return found;
}

/* Fallback: locate a partition by its absolute flash offset, if the kernel
 * exports it. Returns -1 when the attribute is unavailable.
 */
static int mtd_find_by_offset(uint32_t offset)
{
	DIR *d = opendir("/sys/class/mtd");
	struct dirent *e;
	int found = -1;

	if (!d)
		return -1;
	while ((e = readdir(d))) {
		int idx;

		if (sscanf(e->d_name, "mtd%d", &idx) != 1 || strchr(e->d_name, 'r'))
			continue;
		if (mtd_sysfs_u(idx, "offset") == (long)offset) {
			found = idx;
			break;
		}
	}
	closedir(d);
	return found;
}

static int slot_mtd(int slot)
{
	int idx = mtd_find_by_label(slot_label[slot]);

	if (idx < 0)
		idx = mtd_find_by_offset(slot_start[slot]);
	return idx;
}

struct mtd {
	int fd;
	struct mtd_info_user info;
};

static void mtd_open(struct mtd *m, int index, bool writable)
{
	char path[32];

	snprintf(path, sizeof(path), "/dev/mtd%d", index);
	m->fd = open(path, writable ? O_RDWR : O_RDONLY);
	if (m->fd < 0)
		die(path);
	if (ioctl(m->fd, MEMGETINFO, &m->info) < 0)
		die("MEMGETINFO");
}

static bool mtd_bad(struct mtd *m, uint64_t ofs)
{
	long long o = ofs;

	return ioctl(m->fd, MEMGETBADBLOCK, &o) > 0;
}

/*
 * Both cspboot and the kernel locate the payload by skipping the blocks the
 * bad block table lists, so a block that cannot be written has to be listed
 * there, or everything behind it would be read from the wrong place.
 */
static void mtd_mark_bad(struct mtd *m, uint64_t ofs)
{
	long long o = ofs;

	if (ioctl(m->fd, MEMSETBADBLOCK, &o) < 0)
		perror("  could not mark the block bad");
}

static int mtd_erase(struct mtd *m, uint64_t ofs)
{
	struct erase_info_user e = { .start = ofs, .length = m->info.erasesize };

	ioctl(m->fd, MEMUNLOCK, &e);
	return ioctl(m->fd, MEMERASE, &e);
}

static void mtd_read(struct mtd *m, uint64_t ofs, void *buf, size_t len)
{
	if (lseek(m->fd, ofs, SEEK_SET) < 0 || read(m->fd, buf, len) != (ssize_t)len)
		die("mtd read");
}

/* Find this slot's version header by scanning erase blocks. Only what cspboot
 * goes by: the inner magic, then CRC1.
 */
static long slot_scan(struct mtd *m, uint32_t *serial)
{
	uint8_t hdr[VER_HDR_SIZE];
	uint32_t bs = m->info.erasesize;

	for (uint64_t ofs = 0; ofs + VER_HDR_SIZE <= m->info.size; ofs += bs) {
		if (mtd_bad(m, ofs))
			continue;
		mtd_read(m, ofs, hdr, sizeof(hdr));
		if (memcmp(hdr + H_INNER_MAGIC, inner_magic, 16))
			continue;
		if (crc32(hdr, H_CRC) != rd32(hdr, H_CRC))
			continue;
		if (serial)
			*serial = rd32(hdr, H_SERIAL);
		return ofs;
	}
	return -1;
}

static uint32_t max_serial(void)
{
	uint32_t best = 0;

	for (int s = 0; s < 2; s++) {
		int idx = slot_mtd(s);
		struct mtd m;
		uint32_t serial;

		if (idx < 0)
			continue;
		mtd_open(&m, idx, false);
		if (slot_scan(&m, &serial) >= 0 && serial > best)
			best = serial;
		close(m.fd);
	}
	return best;
}

/*
 * cspboot puts the slot it booted into the kernel command line, as the trailing
 * seven fields after the literal "U-Boot":
 *   console=... mem=256M; U-Boot V1.0.0 20250325110003 0x700000 0x0 0xaf 0xa3
 * The fourth is the flash base address of the running slot.
 */
static long running_slot_offset(void)
{
	char buf[4096], tag[32], ver[32], date[64];
	unsigned long base = 0, x0 = 0, x1 = 0, x2 = 0;
	FILE *f = fopen("/proc/cmdline", "r");
	char *p;
	int n;

	if (!f)
		return -1;
	n = fread(buf, 1, sizeof(buf) - 1, f);
	fclose(f);
	if (n <= 0)
		return -1;
	buf[n] = 0;
	p = strstr(buf, "U-Boot");
	if (!p)
		return -1;
	if (sscanf(p, "%31s %31s %63s %lx %lx %lx %lx", tag, ver, date,
		   &base, &x0, &x1, &x2) < 4)
		return -1;
	return (long)base;
}

static int slot_index(long offset)
{
	return offset == (long)slot_start[0] ? 0 :
	       offset == (long)slot_start[1] ? 1 : -1;
}

struct region {
	const char *fail;
	uint64_t start, len;
	uint32_t want, crc;
};

static void region_feed(struct region *r, uint64_t pos, const uint8_t *buf,
			size_t n)
{
	uint64_t lo = pos > r->start ? pos : r->start;
	uint64_t end = r->start + r->len;
	uint64_t hi = pos + n < end ? pos + n : end;

	if (lo < hi)
		r->crc = crc32_update(r->crc, buf + (lo - pos), hi - lo);
}

/*
 * Check a slot the way the header describes it: header CRCs, then the kernel
 * and root filesystem regions, read in good blocks from the start of the slot.
 * The package records file offsets; the slot only knows the distance between
 * them, so the rootfs sits at kstart + (foff - koff).
 */
static const char *slot_verify(struct mtd *m, const uint8_t *hdr)
{
	uint32_t bs = m->info.erasesize;
	uint64_t body_len = rd32(hdr, H_FW_SIZE);
	uint32_t koff = rd32(hdr, H_KERNEL_FILEOFS);
	uint32_t foff = rd32(hdr, H_FS_FILEOFS);
	uint64_t kstart = UBOOT_SIZE + KERNEL_MAGIC_SIZE;
	uint64_t pos = 0, ofs = 0;
	const char *bad = NULL;
	struct region r[2];
	uint8_t *buf;

	if (crc32(hdr, H_CRC) != rd32(hdr, H_CRC) ||
	    crc32(hdr, H_CRC2) != rd32(hdr, H_CRC2))
		return "version header CRC mismatch";
	if (foff < koff)
		return "bad firmware layout";
	if (rd32(hdr, H_BOOT_INCLUDED) != 0)
		return "package claims to update the bootloader";

	r[0] = (struct region){ "kernel CRC mismatch", kstart,
			       rd32(hdr, H_KERNEL_SIZE),
			       rd32(hdr, H_KERNEL_CRC), 0xffffffffu };
	r[1] = (struct region){ "root filesystem CRC mismatch",
			       kstart + (foff - koff), rd32(hdr, H_FS_SIZE),
			       rd32(hdr, H_FS_CRC), 0xffffffffu };
	if (body_len > m->info.size)
		return "bad firmware layout";
	for (int i = 0; i < 2; i++)
		if (r[i].start + r[i].len > body_len)
			return "bad firmware layout";

	buf = malloc(bs);
	if (!buf)
		return "out of memory";
	while (pos < body_len) {
		size_t n = body_len - pos < bs ? body_len - pos : bs;

		if (ofs + bs > m->info.size) {
			bad = "payload runs past the end of the slot";
			break;
		}
		if (mtd_bad(m, ofs)) {
			ofs += bs;
			continue;
		}
		if (pread(m->fd, buf, n, ofs) != (ssize_t)n) {
			bad = "read error";
			break;
		}
		for (int i = 0; i < 2; i++)
			region_feed(&r[i], pos, buf, n);
		pos += n;
		ofs += bs;
	}
	free(buf);
	if (bad)
		return bad;
	for (int i = 0; i < 2; i++)
		if ((r[i].crc ^ 0xffffffffu) != r[i].want)
			return r[i].fail;
	return NULL;
}

struct package {
	uint8_t *data;
	size_t size;
	const uint8_t *hdr;
	const uint8_t *body;
	uint32_t body_len;
};

static void package_load(struct package *p, const char *path)
{
	FILE *f = fopen(path, "rb");
	long size;
	uint32_t hdr_ofs, body_ofs;

	if (!f)
		die(path);
	fseek(f, 0, SEEK_END);
	size = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (size < OUTER_HDR_SIZE + VER_HDR_SIZE)
		errno = EINVAL, die("package too small");
	p->data = malloc(size);
	if (!p->data || fread(p->data, 1, size, f) != (size_t)size)
		die("read package");
	fclose(f);
	p->size = size;

	if (memcmp(p->data, outer_magic, 16))
		errno = EINVAL, die("not an E2631 upgrade package (outer magic)");
	hdr_ofs = 0x14 + rd32(p->data, 0x10);
	body_ofs = hdr_ofs + VER_HDR_SIZE;
	if (body_ofs > p->size)
		errno = EINVAL, die("truncated header");
	p->hdr = p->data + hdr_ofs;
	p->body = p->data + body_ofs;
	p->body_len = p->size - body_ofs;

	if (memcmp(p->hdr + H_INNER_MAGIC, inner_magic, 16))
		errno = EINVAL, die("bad version header magic");
	if (crc32(p->hdr, H_CRC) != rd32(p->hdr, H_CRC) ||
	    crc32(p->hdr, H_CRC2) != rd32(p->hdr, H_CRC2))
		errno = EINVAL, die("header CRC mismatch");
	if (strncmp((const char *)p->hdr + H_PRODUCT, PRODUCT, sizeof(PRODUCT) - 1))
		errno = EINVAL, die("package is not for this product");
	if (rd32(p->hdr, H_BOOT_INCLUDED))
		errno = EINVAL, die("package wants to update the bootloader");
	if (rd32(p->hdr, H_FW_SIZE) != p->body_len)
		errno = EINVAL, die("body size mismatch");
	if (rd32(p->hdr, H_SLOT0) != slot_start[0] ||
	    rd32(p->hdr, H_SLOT1) != slot_start[1])
		errno = EINVAL, die("package declares different slot addresses");

	uint32_t koff = rd32(p->hdr, H_KERNEL_FILEOFS);
	uint32_t ksz = rd32(p->hdr, H_KERNEL_SIZE);
	uint32_t foff = rd32(p->hdr, H_FS_FILEOFS);
	uint32_t fsz = rd32(p->hdr, H_FS_SIZE);

	if ((uint64_t)koff + ksz > p->size || (uint64_t)foff + fsz > p->size)
		errno = EINVAL, die("region outside package");
	if (crc32(p->data + koff, ksz) != rd32(p->hdr, H_KERNEL_CRC))
		errno = EINVAL, die("kernel CRC mismatch");
	if (crc32(p->data + foff, fsz) != rd32(p->hdr, H_FS_CRC))
		errno = EINVAL, die("rootfs CRC mismatch");
}

static uint64_t write_block(struct mtd *m, uint64_t ofs, const uint8_t *buf)
{
	uint32_t bs = m->info.erasesize;

	while (ofs < m->info.size) {
		if (mtd_bad(m, ofs)) {
			fprintf(stderr, "  skip bad block at %#llx\n",
				(unsigned long long)ofs);
			ofs += bs;
			continue;
		}
		if (lseek(m->fd, ofs, SEEK_SET) < 0 ||
		    write(m->fd, buf, bs) != (ssize_t)bs) {
			fprintf(stderr, "  write failed at %#llx, marking the block bad\n",
				(unsigned long long)ofs);
			mtd_mark_bad(m, ofs);
			ofs += bs;
			continue;
		}
		return ofs + bs;
	}
	errno = ENOSPC;
	die("ran out of good blocks");
	return 0;
}

/*
 * Erase every good block of the slot, as the vendor flasher does. A header an
 * older firmware left behind would otherwise still look valid to cspboot and
 * take precedence over the new one.
 */
static void erase_slot(struct mtd *m)
{
	uint32_t bs = m->info.erasesize;

	for (uint64_t ofs = 0; ofs < m->info.size; ofs += bs) {
		if (mtd_bad(m, ofs))
			continue;
		if (mtd_erase(m, ofs) < 0)
			fprintf(stderr, "  erase failed at %#llx\n",
				(unsigned long long)ofs);
	}
}

/* Rewrite one slot header with a new serial: erase the block, write it whole.
 * NAND can only turn bits off, so an in-place write would land as the AND of
 * old and new - which is exactly how the vendor's own switch command breaks.
 */
static int retitle_slot(int slot, uint32_t serial)
{
	int idx = slot_mtd(slot);
	struct mtd m;
	long hpos;
	uint32_t got;
	uint8_t hdr[VER_HDR_SIZE];
	const char *why;

	if (idx < 0)
		errno = ENODEV, die("slot partition not found");
	mtd_open(&m, idx, true);
	hpos = slot_scan(&m, &got);
	if (hpos < 0) {
		fprintf(stderr, "e2631-fwslot: slot %d holds no valid firmware header\n", slot);
		close(m.fd);
		return 1;
	}
	mtd_read(&m, hpos, hdr, sizeof(hdr));

	/* cspboot does not fall back: never point it at a broken slot. */
	why = slot_verify(&m, hdr);
	if (why) {
		fprintf(stderr, "e2631-fwslot: slot %d is damaged (%s), not switching\n",
			slot, why);
		close(m.fd);
		return 1;
	}

	wr32(hdr, H_SERIAL, serial);
	/* H_CRC covers [0:0xa4] and is unaffected; H_CRC2 covers the serial. */
	wr32(hdr, H_CRC2, crc32(hdr, H_CRC2));

	{
		uint8_t *blk = calloc(m.info.erasesize, 1);

		if (!blk)
			die("out of memory");
		memset(blk, 0xff, m.info.erasesize);
		memcpy(blk, hdr, VER_HDR_SIZE);
		if (mtd_erase(&m, hpos) < 0)
			die("erase header block");
		if (lseek(m.fd, hpos, SEEK_SET) < 0 ||
		    write(m.fd, blk, m.info.erasesize) != (ssize_t)m.info.erasesize)
			die("write header");
		free(blk);
	}
	close(m.fd);
	printf("ok: slot %d header at %#lx now serial %u\n", slot,
	       (unsigned long)hpos, serial);
	return 0;
}

static int cmd_check(const char *path)
{
	struct package p;

	package_load(&p, path);
	free(p.data);
	printf("ok: valid E2631 package for %s\n", PRODUCT);
	return 0;
}

static int cmd_flash(const char *path)
{
	struct package p;
	int target_slot, idx;
	struct mtd m;
	uint8_t hdr[VER_HDR_SIZE];
	uint32_t bs, serial;
	uint64_t ofs, left;
	const uint8_t *src;
	int running;
	uint8_t *blk;

	package_load(&p, path);

	running = slot_index(running_slot_offset());
	if (running < 0)
		errno = ENODEV, die("cannot tell which slot is running from /proc/cmdline");
	target_slot = running ^ 1;

	idx = slot_mtd(target_slot);
	if (idx < 0)
		errno = ENODEV, die("target slot partition not found");
	mtd_open(&m, idx, true);
	bs = m.info.erasesize;
	if (p.body_len > m.info.size - bs)
		errno = ENOSPC, die("package larger than the slot");

	blk = malloc(bs);
	if (!blk)
		die("out of memory");

	serial = max_serial() + 1;
	memcpy(hdr, p.hdr, VER_HDR_SIZE);
	wr32(hdr, H_SLOT_START, slot_start[target_slot]);
	wr32(hdr, H_SERIAL, serial);
	wr32(hdr, H_NEW, 1);
	wr32(hdr, H_CRC2, crc32(hdr, H_CRC2));

	fprintf(stderr, "flashing slot %d (mtd%d), serial %u, body %#x\n",
		target_slot, idx, serial, p.body_len);

	erase_slot(&m);

	ofs = 0;
	left = p.body_len;
	src = p.body;
	while (left) {
		const uint8_t *chunk = src;
		size_t n = left < bs ? left : bs;

		if (n < bs) {
			memset(blk, 0xff, bs);
			memcpy(blk, src, n);
			chunk = blk;
		}
		ofs = write_block(&m, ofs, chunk);
		left -= n;
		src += bs;
	}

	/* The version header goes in the next good block after the body. */
	memset(blk, 0xff, bs);
	memcpy(blk, hdr, VER_HDR_SIZE);
	ofs = write_block(&m, ofs, blk);

	if (slot_scan(&m, &serial) < 0)
		errno = EIO, die("header verify failed after flash");

	free(blk);
	close(m.fd);
	free(p.data);
	printf("ok: slot %d now holds serial %u; reboot to run it\n",
	       target_slot, serial);
	return 0;
}

static int cmd_switch(void)
{
	int running = slot_index(running_slot_offset());

	if (running < 0)
		errno = ENODEV, die("cannot tell which slot is running from /proc/cmdline");
	return retitle_slot(running ^ 1, max_serial() + 1);
}

static int cmd_boot(int slot)
{
	if (slot < 0 || slot > 1)
		die("bad slot number");
	return retitle_slot(slot, max_serial() + 1);
}

struct slot_info {
	int mtd;
	bool valid;
	long hpos;
	uint8_t hdr[VER_HDR_SIZE];
	const char *broken;
};

static void slot_info_read(int s, struct slot_info *si)
{
	struct mtd m;
	uint32_t serial;

	memset(si, 0, sizeof(*si));
	si->mtd = slot_mtd(s);
	if (si->mtd < 0)
		return;
	mtd_open(&m, si->mtd, false);
	si->hpos = slot_scan(&m, &serial);
	if (si->hpos >= 0) {
		si->valid = true;
		mtd_read(&m, si->hpos, si->hdr, sizeof(si->hdr));
		si->broken = slot_verify(&m, si->hdr);
	}
	close(m.fd);
}

static int next_slot(const struct slot_info *si)
{
	int best = -1;

	for (int s = 0; s < 2; s++) {
		if (!si[s].valid || si[s].broken)
			continue;
		if (best < 0 || rd32(si[s].hdr, H_SERIAL) > rd32(si[best].hdr, H_SERIAL))
			best = s;
	}
	return best;
}

static void json_str(const uint8_t *s, size_t max)
{
	putchar('"');
	for (size_t i = 0; i < max && s[i]; i++) {
		if (s[i] == '"' || s[i] == '\\')
			printf("\\%c", s[i]);
		else if (s[i] < 0x20 || s[i] >= 0x7f)
			printf("\\u%04x", s[i]);
		else
			putchar(s[i]);
	}
	putchar('"');
}

static int cmd_info(bool json)
{
	int running = slot_index(running_slot_offset());
	struct slot_info si[2];
	int next;

	for (int s = 0; s < 2; s++)
		slot_info_read(s, &si[s]);
	next = next_slot(si);

	if (json) {
		printf("{\"running\":%d,\"next\":%d,\"slots\":[", running, next);
		for (int s = 0; s < 2; s++) {
			printf("%s{\"slot\":%d,\"mtd\":%d,\"valid\":%s,\"intact\":%s",
			       s ? "," : "", s, si[s].mtd,
			       si[s].valid ? "true" : "false",
			       si[s].valid && !si[s].broken ? "true" : "false");
			if (si[s].valid) {
				printf(",\"serial\":%u,\"header_at\":\"0x%lx\",\"version\":",
				       rd32(si[s].hdr, H_SERIAL),
				       (unsigned long)si[s].hpos);
				json_str(si[s].hdr + H_VERSION, 32);
				printf(",\"build\":");
				json_str(si[s].hdr + H_BUILD, 16);
				printf(",\"product\":");
				json_str(si[s].hdr + H_PRODUCT, 52);
				if (si[s].broken) {
					printf(",\"damage\":");
					json_str((const uint8_t *)si[s].broken,
						 strlen(si[s].broken));
				}
			}
			printf("}");
		}
		printf("]}\n");
		return 0;
	}

	printf("running slot: %d\n", running);
	for (int s = 0; s < 2; s++) {
		printf("slot %d: base %#x span %#x mtd%d", s, slot_start[s],
		       slot_span, si[s].mtd);
		if (si[s].mtd < 0) {
			printf(" (missing partition)\n");
			continue;
		}
		if (!si[s].valid) {
			printf(" (no valid version header)\n");
			continue;
		}
		printf(" header@%#lx serial=%u version=\"%.32s\"%s%s%s\n",
		       (unsigned long)si[s].hpos, rd32(si[s].hdr, H_SERIAL),
		       (const char *)si[s].hdr + H_VERSION,
		       s == running ? " [running]" : "",
		       s == next ? " [next boot]" : "",
		       si[s].broken ? "" : "");
		if (si[s].broken)
			printf("       damaged: %s (cspboot will not be pointed here)\n",
			       si[s].broken);
	}
	return 0;
}

int main(int argc, char **argv)
{
	crc_init();
	if (argc == 3 && !strcmp(argv[1], "flash"))
		return cmd_flash(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "check"))
		return cmd_check(argv[2]);
	if (argc == 2 && !strcmp(argv[1], "switch"))
		return cmd_switch();
	if (argc == 3 && !strcmp(argv[1], "boot"))
		return cmd_boot(atoi(argv[2]));
	if (argc == 2 && !strcmp(argv[1], "info"))
		return cmd_info(false);
	if (argc == 3 && !strcmp(argv[1], "info") && !strcmp(argv[2], "-j"))
		return cmd_info(true);

	fprintf(stderr,
		"usage: e2631-fwslot check <package.bin>  verify a package without writing\n"
		"       e2631-fwslot flash <package.bin>  write package to the inactive slot\n"
		"       e2631-fwslot switch              verify the other slot and make it the next boot\n"
		"       e2631-fwslot boot <0|1>          same, naming the slot explicitly\n"
		"       e2631-fwslot info [-j]           show both slots, -j as JSON\n"
		"\n"
		"slot 0 is the vendor system on this board layout; from OpenWrt,\n"
		"'switch' reboots into it without rewriting a byte of its body.\n");
	return 1;
}
