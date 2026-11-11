#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
typedef struct { uint64_t x[29], fp, lr, sp, pc; } st_t;
bool sweet_lse_emulate(st_t *s, uint32_t instr);
static int fails;
#define CHECK(c,msg) do{ if(!(c)){printf("FAIL %s\n",msg);fails++;} else printf("ok   %s\n",msg);}while(0)
int main(void){
	st_t s={0}; uint64_t mem[4]={0};
	/* ldaddal w8, w0, [x0] : 0xb8e80000 ; Rs=8 Rn=0 Rt=0 */
	mem[0]=0x00000000fffffffeULL; s.x[0]=(uint64_t)mem; s.x[8]=3;
	CHECK(sweet_lse_emulate(&s,0xb8e80000),"ldaddal decoded");
	CHECK(s.x[0]==0xfffffffe && (uint32_t)mem[0]==1,"ldadd 32-bit wraps, returns old");
	/* casal x1, x8, [x0] : 0xc8e1fc08 ; Rs=1 Rt=8 */
	mem[0]=42; s.x[0]=(uint64_t)mem; s.x[1]=42; s.x[8]=7;
	CHECK(sweet_lse_emulate(&s,0xc8e1fc08) && mem[0]==7 && s.x[1]==42,"casal success");
	s.x[1]=1; s.x[8]=9;
	CHECK(sweet_lse_emulate(&s,0xc8e1fc08) && mem[0]==7 && s.x[1]==7,"casal failure returns current");
	/* swpal x1, x0, [x0] : 0xf8e18000 Rs=1 Rt=0 */
	mem[0]=0x1111; s.x[0]=(uint64_t)mem; s.x[1]=0x2222;
	CHECK(sweet_lse_emulate(&s,0xf8e18000) && mem[0]==0x2222 && s.x[0]==0x1111,"swpal");
	/* ldsetb w2, w3, [x4]: size00 111000 A0 R0 1 Rs=2 o3=0 opc=011 00 Rn=4 Rt=3 */
	uint32_t i=0x38200000|(2<<16)|(3<<12)|(4<<5)|3; unsigned char b[8]={0x10,0x55};
	s.x[4]=(uint64_t)b; s.x[2]=0x81;
	CHECK(sweet_lse_emulate(&s,i) && b[0]==0x91 && s.x[3]==0x10 && b[1]==0x55,"ldsetb byte, neighbour intact");
	/* ldsmax w (opc=100) signed: old -5, operand 3 -> 3 */
	uint32_t w[2]={(uint32_t)-5,0}; i=0xb8200000|(5<<16)|(4<<12)|(6<<5)|7; s.x[6]=(uint64_t)w; s.x[5]=3;
	CHECK(sweet_lse_emulate(&s,i) && w[0]==3 && s.x[7]==0xfffffffb,"ldsmax signed 32");
	/* ldumin x (opc=111) */
	mem[0]=10; i=0xf8200000|(5<<16)|(7<<12)|(6<<5)|7; s.x[6]=(uint64_t)mem; s.x[5]=4;
	CHECK(sweet_lse_emulate(&s,i) && mem[0]==4 && s.x[7]==10,"ldumin 64");
	/* stclr (Rt=31): ldclr x, opc=001 */
	mem[0]=0xff; i=0xf8200000|(5<<16)|(1<<12)|(6<<5)|31; s.x[5]=0x0f;
	CHECK(sweet_lse_emulate(&s,i) && mem[0]==0xf0,"stclr (XZR target)");
	/* ldapr w: 10 111000 1 0 1 11111 1 100 00 Rn Rt */
	w[0]=0x12345678; i=0xb8a0c000|(31<<16)|(6<<5)|9; s.x[6]=(uint64_t)w;
	CHECK(sweet_lse_emulate(&s,i) && s.x[9]==0x12345678,"ldapr");
	/* casp x2,x3, x4,x5,[x6]: 0 1 001000 0 0 1 Rs=2 0 11111 Rn Rt=4 */
	uint64_t pr[2]={1,2}; i=0x48207c00|(2<<16)|(6<<5)|4; s.x[6]=(uint64_t)pr; s.x[2]=1;s.x[3]=2;s.x[4]=8;s.x[5]=9;
	CHECK(sweet_lse_emulate(&s,i) && pr[0]==8 && pr[1]==9 && s.x[2]==1 && s.x[3]==2,"casp 64");
	/* plain ldxr must not be emulated: 0xc85f7c00 */
	CHECK(!sweet_lse_emulate(&s,0xc85f7c00),"ldxr not matched");
	/* ldr (register) must not match: 0xf8606800 */
	CHECK(!sweet_lse_emulate(&s,0xf8606800),"ldr (register) not matched");
	printf(fails?"%d FAILED\n":"all passed\n",fails); return fails!=0;
}
