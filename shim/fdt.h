#pragma once
#include <stdint.h>

/* Read a u32/u64 (cell-size agnostic) property of /chosen. Returns 0 if absent. */
int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out);

/* 1 if the root node's "compatible" list has want (e.g. "samsung,exynos7870"). */
int fdt_root_compatible(uintptr_t fdt, const char *want);
