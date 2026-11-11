/*
 * Galaxy J7 Neo boot shim entry: arm64 Linux Image header so Samsung's
 * S-BOOT treats us like a kernel. Linux boot protocol: MMU and D-cache off,
 * x0 = DTB pointer, entered at EL2 or EL1. XNU wants EL1, so EL2 drops to
 * EL1 first (no hypervisor stays resident).
 */
	.section .text.head, "ax"
	.globl _head
_head:
	b	_start			/* code0 */
	.long	0			/* code1 */
	.quad	0			/* text_offset */
	.quad	_end			/* image_size (linked at 0) */
	.quad	0xa			/* flags: LE, 4K pages, place anywhere */
	.quad	0			/* res2 */
	.quad	0			/* res3 */
	.quad	0			/* res4 */
	.ascii	"ARM\x64"		/* magic */
	.long	0			/* res5 (PE offset) */

	.text
	.globl _start
_start:
	msr	daifset, #0xf
	mov	x19, x0			/* DTB pointer from S-BOOT */
	mrs	x1, CurrentEL
	lsr	x20, x1, #2		/* entry EL, reported on screen */
	cmp	x20, #2
	b.ne	1f
	/* EL2 -> EL1h: AArch64 EL1, no stage 2, no traps, timers usable at EL1. */
	mov	x1, #(1 << 31)
	msr	hcr_el2, x1
	msr	vttbr_el2, xzr
	msr	cptr_el2, xzr
	msr	mdcr_el2, xzr
	mov	x1, #3
	msr	cnthctl_el2, x1
	msr	cntvoff_el2, xzr
	ldr	x1, =0x30d00800		/* SCTLR_EL1 RES1 bits, MMU/caches off, LE */
	msr	sctlr_el1, x1
	adr	x1, 1f
	msr	elr_el2, x1
	mov	x1, #0x3c5		/* DAIF masked, EL1h */
	msr	spsr_el2, x1
	isb
	eret
1:	msr	spsel, #1
	adr	x1, _stack_top
	mov	sp, x1
	adr	x1, vectors
	msr	vbar_el1, x1
	isb
	/* zero .bss */
	adr	x1, _bss_start
	adr	x2, _bss_end
2:	cmp	x1, x2
	b.hs	3f
	str	xzr, [x1], #8
	b	2b
3:	mov	x0, x19
	mov	x1, x20
	bl	shim_main
4:	wfe
	b	4b

	.ltorg

/*
 * Exception vectors. Each slot stashes x29/x30, loads its slot number
 * and jumps to the common path, which saves x0-x28 and calls
 * exc_handler(slot, regs), which shows the state on screen and halts.
 */
.macro vent slot
	.balign	0x80
	stp	x29, x30, [sp, #-16]!
	mov	x29, #\slot
	b	exc_common
.endm

	.balign	0x800
	.globl vectors
vectors:
	vent 0
	vent 1
	vent 2
	vent 3
	vent 4
	vent 5
	vent 6
	vent 7
	vent 8
	vent 9
	vent 10
	vent 11
	vent 12
	vent 13
	vent 14
	vent 15

exc_common:
	sub	sp, sp, #(30 * 8)
	stp	x0, x1, [sp, #0]
	stp	x2, x3, [sp, #16]
	stp	x4, x5, [sp, #32]
	stp	x6, x7, [sp, #48]
	stp	x8, x9, [sp, #64]
	stp	x10, x11, [sp, #80]
	stp	x12, x13, [sp, #96]
	stp	x14, x15, [sp, #112]
	stp	x16, x17, [sp, #128]
	stp	x18, x19, [sp, #144]
	stp	x20, x21, [sp, #160]
	stp	x22, x23, [sp, #176]
	stp	x24, x25, [sp, #192]
	stp	x26, x27, [sp, #208]
	str	x28, [sp, #224]
	mov	x0, x29
	mov	x1, sp
	bl	exc_handler
5:	wfe
	b	5b
