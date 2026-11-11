#pragma once
#include <stdint.h>

/*
 * Galaxy J7 Neo: framebuffer S-BOOT leaves scanning out (simple-framebuffer
 * of the exynos7870-j7velte DTS): 720x1280 a8r8g8b8 at 0x67000000.
 */
#define FB_BASE		0x67000000UL
#define FB_W		720
#define FB_H		1280
#define FB_STRIDE	(FB_W * 4)
#define FB_SIZE		(FB_STRIDE * FB_H)

#define RED	0xffff0000U
#define BLUE	0xff0000a0U
#define WHITE	0xffffffffU
#define YELLOW	0xffffff00U
#define GREEN	0xff00ff00U

extern volatile uint32_t *con_fb;

void con_clear(uint32_t bg);
void con_skip(void);
void con_str(const char *label, const char *s);
void con_hex(const char *label, uint64_t v);
/* label, then "a=xxxxxxxx b=xxxxxxxx" style pairs of 32-bit values */
void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb);
