#pragma once
#include <stdint.h>

/* Restart into TWRP (hold Vol+) or Download mode (hold Vol-): escape.c. */
int esc_init(uintptr_t dtb);			/* armed on an Exynos 7870 DT; returns armed */
void esc_check(void);				/* restart now if a volume key is held */
void __attribute__((noreturn)) esc_restart(int recovery);
void __attribute__((noreturn)) esc_wait(void);	/* halt, still watching the keys */
