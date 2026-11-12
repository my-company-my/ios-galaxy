/*
 * Restart without the power button (the user's J7 Neo has a broken one):
 * hold Volume up for TWRP (recovery) or Volume down for Download mode.
 *
 * The restart reason goes in the PMU INFORM3 register that S-BOOT reads
 * (mainline Linux exynos7870.dtsi: syscon-reboot-mode at PMU 0x10480000 +
 * 0x80c, download 0x12345671, recovery 0x12345674), then PSCI
 * SYSTEM_RESET through SMC; if the firmware returns, PMU SWRESET (what
 * Samsung's own kernel writes). Volume keys: gpa2-0 / gpa2-1 of the ALIVE
 * pin controller, active low, read from the DAT register like the kernel's
 * bsd/dev/sweet_keys.c (S-BOOT leaves the pins in EINT mode).
 *
 * Only armed on an Exynos 7870 device tree: QEMU virt has none of these
 * registers. The QEMU test build points the three addresses into RAM
 * (-DESC_FORCE -DESC_GPA2_DAT=... ; tools/qemu-j7.py --escape).
 */
#include <stdint.h>
#include "console.h"
#include "escape.h"
#include "fdt.h"

#ifndef ESC_GPA2_DAT
#define ESC_GPA2_DAT	0x139f0084UL	/* ALIVE 0x139f0000 + GPA2 bank 0x80 + DAT 0x4 */
#endif
#ifndef ESC_INFORM3
#define ESC_INFORM3	0x1048080cUL	/* PMU + 0x80c */
#endif
#ifndef ESC_SWRESET
#define ESC_SWRESET	0x10480400UL	/* PMU + 0x400 */
#endif

#define KEY_VOLUP	1		/* gpa2-0 */
#define KEY_VOLDOWN	2		/* gpa2-1 */
#define MODE_DOWNLOAD	0x12345671U
#define MODE_RECOVERY	0x12345674U
#define PSCI_SYSTEM_RESET 0x84000009UL
#define HOLD_MS		300		/* a key must stay down this long: no restart from a brush */

static int armed;

static uint64_t now(void)
{
	uint64_t t;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t));
	return t;
}

static void delay_ms(unsigned ms)
{
	uint64_t f;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
	if (!f)
		f = 26000000;	/* S-BOOT leaves CNTFRQ_EL0 = 0; the timer runs at 26 MHz */
	uint64_t end = now() + ms * (f / 1000);
	while (now() < end)
		;
}

static unsigned keys(void)
{
	uint32_t dat = *(volatile uint32_t *)ESC_GPA2_DAT;
	return ((dat & 1) ? 0 : KEY_VOLUP) | ((dat & 2) ? 0 : KEY_VOLDOWN);
}

/* The key held without change for ms milliseconds, or 0. */
static unsigned held(unsigned ms)
{
	unsigned k = keys();
	if (!k)
		return 0;
	for (unsigned t = 0; t < ms; t += 10) {
		delay_ms(10);
		if (keys() != k)
			return 0;
	}
	return k;
}

int esc_init(uintptr_t dtb)
{
#ifdef ESC_FORCE
	(void)dtb;
	armed = 1;
#else
	armed = fdt_root_compatible(dtb, "samsung,exynos7870");
#endif
	return armed;
}

void __attribute__((noreturn)) esc_restart(int recovery)
{
	con_skip();
	if (recovery)
		con_str("RESTART", "into TWRP (recovery)");
	else
		con_str("RESTART", "into Download mode");
	*(volatile uint32_t *)ESC_INFORM3 = recovery ? MODE_RECOVERY : MODE_DOWNLOAD;
	__asm__ volatile("dsb sy" ::: "memory");
	register uint64_t x0 __asm__("x0") = PSCI_SYSTEM_RESET;
	__asm__ volatile("smc #0" : "+r"(x0) : :
			 "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9",
			 "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "memory");
	/* The firmware returned: PMU software reset. */
	*(volatile uint32_t *)ESC_SWRESET = 1;
	__asm__ volatile("dsb sy" ::: "memory");
	for (;;)
		__asm__ volatile("wfe");
}

void esc_check(void)
{
	if (!armed)
		return;
	unsigned k = held(HOLD_MS);
	if (k == KEY_VOLUP)
		esc_restart(1);
	if (k == KEY_VOLDOWN)
		esc_restart(0);
	/* both keys, or none: keep going */
}

void __attribute__((noreturn)) esc_wait(void)
{
	if (!armed) {
		for (;;)
			__asm__ volatile("wfe");
	}
	con_str("KEYS", "hold Vol+ = TWRP, Vol- = Download");
	for (;;) {
		esc_check();
		delay_ms(20);
	}
}
