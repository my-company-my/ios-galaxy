/*
 * Galaxy J7 Neo boot shim: S-BOOT boots this as "the kernel" of an Android
 * boot image. It checks the CPU, finds the SWEETXNU payload (in the boot
 * image ramdisk, or appended to this image) and boots XNU like iBoot
 * would (loader.c). Anything unexpected stays on screen. Without the power
 * button (escape.c): hold Volume up while it starts or while it shows a
 * message to restart into TWRP, Volume down for Download mode.
 */
#include <stdint.h>
#include "console.h"
#include "escape.h"
#include "loader.h"

#define rsr(r) ({ uint64_t _v; __asm__ volatile("mrs %0, " r : "=r"(_v)); _v; })

static const char *stage;	/* set at runtime: no absolute pointers in data */

static void __attribute__((noreturn)) halt(void)
{
	con_skip();
	con_str("HALT", "stopped");
	esc_wait();
}

void exc_handler(uint64_t slot, uint64_t *regs)
{
	con_clear(BLUE);
	/* Characters, not a table of string pointers: no absolute relocations. */
	static const char kinds[4][8] = { "SYNC", "IRQ", "FIQ", "SERROR" };
	con_str("PANIC", kinds[slot & 3]);
	con_hex2("SLOT", "n=", slot, "cpu=", rsr("mpidr_el1"));
	con_str("STAGE", stage);
	con_hex("ESR", rsr("esr_el1"));
	con_hex("ELR", rsr("elr_el1"));
	con_hex("FAR", rsr("far_el1"));
	con_hex("SPSR", rsr("spsr_el1"));
	con_hex("X0", regs[0]);
	con_hex("X1", regs[1]);
	con_hex("X30", regs[29]);	/* stashed lr is just above the frame */
	halt();
}

void shim_main(uint64_t dtb, uint64_t entry_el)
{
	uint64_t mmfr0 = rsr("id_aa64mmfr0_el1");
	uint64_t pfr0 = rsr("id_aa64pfr0_el1");
	uint64_t isar0 = rsr("id_aa64isar0_el1");

	stage = "checks";
	con_clear(RED);
	con_str("SHIM", "j7neo: xnu loader");
	if (esc_init(dtb))
		con_str("KEYS", "hold Vol+ = TWRP, Vol- = Download");
	esc_check();
	con_skip();
	con_hex2("CPU", "el=", (uint32_t)entry_el, "mpidr=", (uint32_t)rsr("mpidr_el1"));
	con_hex2("MIDR", "", (uint32_t)rsr("midr_el1"), "frq=", (uint32_t)rsr("cntfrq_el0"));
	con_hex("MMFR0", mmfr0);
	con_hex("ISAR0", isar0);
	con_hex("PFR0", pfr0);
	/* XNU for this phone uses the 4K granule (TGran4 [31:28] == 0: supported). */
	if (((mmfr0 >> 28) & 0xf) != 0) {
		con_str("ERROR", "no 4K translation granule");
		halt();
	}
	/* AES/SHA1/SHA2 (ISAR0 [7:4], [11:8], [15:12]): iOS needs the crypto extensions. */
	if (((isar0 >> 4) & 0xf) == 0 || ((isar0 >> 8) & 0xf) == 0 || ((isar0 >> 12) & 0xf) == 0) {
		con_str("ERROR", "no ARMv8 crypto extensions");
		halt();
	}
	if (((isar0 >> 20) & 0xf) == 0)
		con_str("NOTE", "no LSE atomics: kernel emulates");
	con_skip();

	stage = "loader";
	const char *why = loader_boot(dtb, rsr("mpidr_el1") & 0xffffff);
	con_str("LOADER", why);
	halt();
}
