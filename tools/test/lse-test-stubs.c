#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
typedef uint64_t user_addr_t;
int sweet_cas_user(user_addr_t a, uint64_t exp, uint64_t des, unsigned sz, uint64_t *old){
	uint64_t v=0; memcpy(&v,(void*)a,1u<<sz); *old=v; if(v==exp) memcpy((void*)a,&des,1u<<sz); return 0; }
int sweet_casp_user(user_addr_t a, uint64_t el, uint64_t eh, uint64_t nl, uint64_t nh, bool is64, uint64_t old[2]){
	unsigned s=is64?8:4; uint64_t l=0,h=0; memcpy(&l,(void*)a,s); memcpy(&h,(char*)a+s,s); old[0]=l; old[1]=h;
	if(l==el&&h==eh){memcpy((void*)a,&nl,s);memcpy((char*)a+s,&nh,s);} return 0;}
int copyin_atomic32(user_addr_t a, uint32_t *k){ memcpy(k,(void*)a,4); return 0;}
int copyin_atomic64(user_addr_t a, uint64_t *k){ memcpy(k,(void*)a,8); return 0;}
