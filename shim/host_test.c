/* Render the console layout on the host: ./out/host_test && view out/host.ppm */
#include <stdio.h>
#include "console.h"

static uint32_t host_fb[FB_H * FB_STRIDE / 4];

int main(void)
{
	con_fb = host_fb;
	con_clear(RED);
	con_str("SHIM", "j7neo: xnu loader");
	con_skip();
	con_hex2("CPU", "el=", 1, "mpidr=", 0x80000000);
	con_hex2("MIDR", "", 0x410fd034, "frq=", 0);
	con_hex("MMFR0", 0x0000000000001122ULL);
	con_str("NOTE", "no LSE atomics: kernel emulates");
	con_hex2("INITRD", "lo=", 0x41000000, "hi=", 0x42400000);
	con_clear(BLUE);
	con_str("PANIC", "SYNC");
	con_hex("ESR", 0x96000010);
	con_skip();
	con_str("HALT", "stopped");
	con_str("KEYS", "hold Vol+ = TWRP, Vol- = Download");
	FILE *f = fopen("out/host.ppm", "wb");
	fprintf(f, "P6 %d %d 255\n", FB_W, FB_H);
	for (int i = 0; i < FB_W * FB_H; i++) {
		unsigned char px[3] = { host_fb[i] >> 16, host_fb[i] >> 8, host_fb[i] };
		fwrite(px, 1, 3, f);
	}
	fclose(f);
	return 0;
}
