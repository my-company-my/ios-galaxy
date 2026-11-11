#pragma once
#include <stdint.h>

/*
 * Boot the SWEETXNU payload (S-BOOT ramdisk or appended to the shim);
 * returns only on error. boot_mpidr: MPIDR_EL1 Aff2:Aff1:Aff0 of this core.
 */
const char *loader_boot(uintptr_t dtb, uint32_t boot_mpidr);
