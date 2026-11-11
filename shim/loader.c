/*
 * Act as iBoot for xnu on the Galaxy J7 Neo.
 *
 * mkpayload.py already resolved the kernel's chained fixups and built the
 * ADT, so this only has to: find the payload (the boot image ramdisk that
 * S-BOOT announces in /chosen, or else appended to this image), move it
 * out of the way if it lies in the kernel's RAM, copy the segments to
 * phys_base + (vmaddr - virt_base), place the ADT and boot_args behind the
 * kernel, make the core S-BOOT started on logical CPU 0 in the ADT, and
 * jump to the entry point with the MMU and caches off,
 * x0 = boot_args (physical).
 */
#include <stdint.h>
#include "console.h"
#include "fdt.h"
#include "loader.h"

#define BOOT_LINE_LENGTH	608
#define PAGE_16K		0x4000UL

struct payload_seg {
	uint64_t vmaddr, vmsize, file_off, file_size;
};

struct payload {
	char magic[8];
	uint32_t version, nsegs;
	uint64_t virt_base, entry_va, adt_off, adt_size, kernel_end;
	uint64_t phys_base, mem_size;
	char cmdline[BOOT_LINE_LENGTH];
	struct payload_seg segs[];
};

/* pexpert/pexpert/arm64/boot.h, Revision/Version 2 */
struct boot_video {
	uint64_t v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth;
};

struct boot_args {
	uint16_t Revision, Version;
	uint64_t virtBase, physBase, memSize, topOfKernelData;
	struct boot_video Video;
	uint32_t machineType;
	uint64_t deviceTreeP;
	uint32_t deviceTreeLength;
	char CommandLine[BOOT_LINE_LENGTH];
	uint64_t bootFlags, memSizeActual;
};

_Static_assert(__builtin_offsetof(struct payload, segs) == 0x2a8, "payload header layout");
_Static_assert(__builtin_offsetof(struct boot_args, Video) == 40, "boot_args layout");
_Static_assert(__builtin_offsetof(struct boot_args, CommandLine) == 108, "boot_args layout");
_Static_assert(sizeof(struct boot_args) == 736, "boot_args layout");

/* MMU off: everything is Device memory, so copy in aligned 8-byte words. */
static void copy64(uintptr_t dst, uintptr_t src, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	volatile const uint64_t *s = (volatile const uint64_t *)src;
	for (uint64_t i = 0; i < (n + 7) / 8; i++)
		d[i] = s[i];
}

static void zero64(uintptr_t dst, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	for (uint64_t i = 0; i < n / 8; i++)
		d[i] = 0;
}

static int magic_ok(const char *m)
{
	static const char want[] = "SWEETXNU";
	for (int i = 0; i < 8; i++)
		if (m[i] != want[i])
			return 0;
	return 1;
}

typedef void (*xnu_entry_t)(uint64_t boot_args_pa);

extern char _end[];

/* Bank 0 scratch for a payload that S-BOOT put inside the kernel's RAM. */
#define RELOC_BASE		0x50000000UL
#define RELOC_LIMIT		(FB_BASE & ~0xfffffUL)	/* stay below the framebuffer */

static uint64_t payload_size(const struct payload *p)
{
	uint64_t end = p->adt_off + p->adt_size;
	for (uint32_t i = 0; i < p->nsegs; i++)
		if (p->segs[i].file_off + p->segs[i].file_size > end)
			end = p->segs[i].file_off + p->segs[i].file_size;
	return end;
}

/* ---- ADT: make the boot core logical CPU 0 ---- */

struct adt_prop_hdr {
	char name[32];
	uint32_t size;
};

static int name_eq(volatile const char *a, const char *b)
{
	int i = 0;
	for (; i < 32 && b[i]; i++)
		if (a[i] != b[i])
			return 0;
	return i == 32 || a[i] == 0;
}

/* Address of a property value of the node at n, or 0. */
static uintptr_t adt_prop(uintptr_t n, const char *name, uint32_t *size)
{
	uint32_t nprops = *(volatile uint32_t *)n;
	uintptr_t p = n + 8;
	for (uint32_t i = 0; i < nprops; i++) {
		volatile struct adt_prop_hdr *h = (volatile struct adt_prop_hdr *)p;
		uint32_t len = h->size & 0x7fffffff;
		if (name_eq(h->name, name)) {
			*size = len;
			return p + 36;
		}
		p += 36 + ((len + 3) & ~3U);
	}
	return 0;
}

/* Address just past the node at n (properties and all children). */
static uintptr_t adt_skip(uintptr_t n)
{
	uint32_t nprops = *(volatile uint32_t *)n, nchild = *(volatile uint32_t *)(n + 4);
	uintptr_t p = n + 8;
	for (uint32_t i = 0; i < nprops; i++) {
		uint32_t len = ((volatile struct adt_prop_hdr *)p)->size & 0x7fffffff;
		p += 36 + ((len + 3) & ~3U);
	}
	for (uint32_t i = 0; i < nchild; i++)
		p = adt_skip(p);
	return p;
}

static int node_named(uintptr_t n, const char *want)
{
	uint32_t size;
	uintptr_t v = adt_prop(n, "name", &size);
	if (!v)
		return 0;
	volatile const char *s = (volatile const char *)v;
	uint32_t i = 0;
	for (; want[i]; i++)
		if (i >= size || s[i] != want[i])
			return 0;
	return i < size && s[i] == 0;
}

static void swap_u32_prop(uintptr_t a, uintptr_t b, const char *name)
{
	uint32_t sa, sb;
	uintptr_t va = adt_prop(a, name, &sa), vb = adt_prop(b, name, &sb);
	if (va && vb && sa == 4 && sb == 4) {
		uint32_t t = *(volatile uint32_t *)va;
		*(volatile uint32_t *)va = *(volatile uint32_t *)vb;
		*(volatile uint32_t *)vb = t;
	}
}

/*
 * The ADT lists the cores in MPIDR order with cpu0 = MPIDR 0 marked
 * "running". If S-BOOT started on another core, swap that core's reg (and
 * cluster-core-id) with cpu0's, so the boot core is always logical CPU 0.
 * Returns 0 if the boot MPIDR was found.
 */
static int adt_fix_boot_cpu(uintptr_t adt, uint32_t boot_mpidr)
{
	uint32_t nchild = *(volatile uint32_t *)(adt + 4);
	uintptr_t c = 0;
	uintptr_t child = adt + 8;
	uint32_t nprops = *(volatile uint32_t *)adt;
	for (uint32_t i = 0; i < nprops; i++) {
		uint32_t len = ((volatile struct adt_prop_hdr *)child)->size & 0x7fffffff;
		child += 36 + ((len + 3) & ~3U);
	}
	for (uint32_t i = 0; i < nchild; i++, child = adt_skip(child))
		if (node_named(child, "cpus")) {
			c = child;
			break;
		}
	if (!c)
		return -1;
	uint32_t ncpu = *(volatile uint32_t *)(c + 4);
	uintptr_t cpu0 = 0, cur = c + 8;
	uint32_t np = *(volatile uint32_t *)c;
	for (uint32_t i = 0; i < np; i++) {
		uint32_t len = ((volatile struct adt_prop_hdr *)cur)->size & 0x7fffffff;
		cur += 36 + ((len + 3) & ~3U);
	}
	for (uint32_t i = 0; i < ncpu; i++, cur = adt_skip(cur)) {
		uint32_t size;
		uintptr_t reg = adt_prop(cur, "reg", &size);
		if (i == 0)
			cpu0 = cur;
		if (reg && size == 4 && *(volatile uint32_t *)reg == boot_mpidr) {
			if (cur != cpu0) {
				swap_u32_prop(cpu0, cur, "reg");
				swap_u32_prop(cpu0, cur, "cluster-core-id");
				swap_u32_prop(cpu0, cur, "die-cluster-id");
			}
			return 0;
		}
	}
	return -1;
}

static const struct payload *find_payload(uintptr_t dtb, uint64_t *where)
{
	uint64_t rd_start, rd_end;

	if (fdt_chosen_u64(dtb, "linux,initrd-start", &rd_start) &&
	    fdt_chosen_u64(dtb, "linux,initrd-end", &rd_end)) {
		con_hex2("INITRD", "lo=", rd_start, "hi=", rd_end);
		if (!(rd_start & 7) && magic_ok((const char *)rd_start)) {
			*where = 0;
			return (const struct payload *)rd_start;
		}
		con_str("INITRD", "no SWEETXNU payload there");
	} else {
		con_str("INITRD", "none in /chosen");
	}
	/* build.sh --payload-in-kernel: right behind this image, 4K aligned. */
	uintptr_t tail = ((uintptr_t)_end + 0xfff) & ~0xfffUL;
	if (magic_ok((const char *)tail)) {
		con_hex("APPENDED", tail);
		*where = 1;
		return (const struct payload *)tail;
	}
	return 0;
}

const char *loader_boot(uintptr_t dtb, uint32_t boot_mpidr)
{
	uint64_t where;
	const struct payload *p = find_payload(dtb, &where);
	if (!p)
		return "no SWEETXNU payload found";
	if (p->version != 1 || (p->adt_off & 7))
		return "bad payload header";
	uint64_t psize = payload_size(p);
	uintptr_t rd_start = (uintptr_t)p, rd_end = rd_start + psize;
	(void)where;

	uint64_t pa_of_va_base = p->phys_base - p->virt_base;	/* pa = va + this */
	con_hex2("PHYS", "base=", p->phys_base, "size=", p->mem_size);
	con_hex("VIRT", p->virt_base);
	con_hex("ENTRY", p->entry_va);

	/* The payload must not overlap where the kernel goes: move it to bank 0 if it does. */
	if (rd_end > p->phys_base && rd_start < p->phys_base + p->mem_size) {
		if (RELOC_BASE + psize > RELOC_LIMIT || (rd_start < RELOC_BASE + psize && rd_end > RELOC_BASE))
			return "payload in kernel RAM, cannot move it";
		copy64(RELOC_BASE, rd_start, psize);
		rd_start = RELOC_BASE;
		p = (const struct payload *)rd_start;
		con_hex("MOVED TO", rd_start);
	}

	for (uint32_t i = 0; i < p->nsegs; i++) {
		const struct payload_seg *s = &p->segs[i];
		uintptr_t dst = s->vmaddr + pa_of_va_base;
		copy64(dst, rd_start + s->file_off, s->file_size);
		if (s->vmsize > s->file_size)
			zero64(dst + ((s->file_size + 7) & ~7UL), s->vmsize - ((s->file_size + 7) & ~7UL));
	}
	con_hex2("SEGS", "n=", p->nsegs, "end=", p->kernel_end + pa_of_va_base);

	/* ADT, then boot_args, behind the kernel; everything below topOfKernelData is ours. */
	uintptr_t adt_pa = p->kernel_end + pa_of_va_base;
	copy64(adt_pa, rd_start + p->adt_off, p->adt_size);
	if (adt_fix_boot_cpu(adt_pa, boot_mpidr))
		return "boot MPIDR not in the ADT /cpus";
	con_hex("BOOTCPU", boot_mpidr);
	uintptr_t ba_pa = (adt_pa + p->adt_size + PAGE_16K - 1) & ~(PAGE_16K - 1);
	uintptr_t top = ba_pa + PAGE_16K;

	zero64(ba_pa, PAGE_16K);
	volatile struct boot_args *ba = (volatile struct boot_args *)ba_pa;
	ba->Revision = 2;
	ba->Version = 2;
	ba->virtBase = p->virt_base;
	ba->physBase = p->phys_base;
	ba->memSize = p->mem_size;
	ba->topOfKernelData = top;
	ba->Video.v_baseAddr = FB_BASE;
	ba->Video.v_display = 1;
	ba->Video.v_rowBytes = FB_STRIDE;
	ba->Video.v_width = FB_W;
	ba->Video.v_height = FB_H;
	ba->Video.v_depth = 32;
	ba->deviceTreeP = adt_pa - pa_of_va_base;	/* xnu reads it with the MMU on: a VA */
	ba->deviceTreeLength = (uint32_t)p->adt_size;
	for (int i = 0; i < BOOT_LINE_LENGTH; i++)
		ba->CommandLine[i] = p->cmdline[i];
	ba->memSizeActual = p->mem_size;
	con_hex2("BOOTARG", "pa=", ba_pa, "top=", top);

	uintptr_t entry_pa = p->entry_va + pa_of_va_base;
	con_hex("JUMP", entry_pa);
	con_str("XNU", "jumping (fbcon clears screen)");

	/* Everything was written with the MMU and caches off; drop any stale I-cache lines too. */
	__asm__ volatile("dsb sy; ic iallu; dsb sy; isb" ::: "memory");
	((xnu_entry_t)entry_pa)(ba_pa);
	return "xnu returned";
}
