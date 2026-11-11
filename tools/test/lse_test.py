#!/usr/bin/env python3
"""Host unit test of the kernel's ARMv8.1 atomics emulation (osfmk/arm64/sweet_lse.c).

  tools/test/lse_test.py        (needs a C compiler: cc)

Takes sweet_lse.c from xnu/patches/0083-*.patch (a new file there), swaps
the XNU types and user-memory primitives for host stubs (lse-test-stubs.c)
and runs the cases in lse-test-main.c against plain host memory.
"""
import glob, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def new_file_from_patch(patch, path):
    lines, inside = [], False
    for line in open(patch).read().splitlines():
        if line.startswith('+++ '):
            inside = line == '+++ b/' + path
            continue
        if inside:
            if line.startswith('--- ') or line.startswith('diff '):
                break
            if line.startswith('+'):
                lines.append(line[1:])
    if not lines:
        sys.exit(f'{path} not found as a new file in {patch}')
    return '\n'.join(lines) + '\n'


def main():
    patch = glob.glob(os.path.join(REPO, 'xnu/patches/0083-*.patch'))[0]
    src = new_file_from_patch(patch, 'osfmk/arm64/sweet_lse.c')
    body = src[src.index('extern int sweet_cas_user'):src.rindex('#endif /* SWEET */')]
    start = body.index('\tuint64_t n = os_atomic_inc(&sweet_lse_emulated, relaxed);')
    end = body.index('\treturn true;\n}', start)
    body = body[:start] + body[end:]          # drop the XNU-only logging
    hdr = '''#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
typedef uint64_t user_addr_t;
typedef struct { uint64_t x[29], fp, lr, sp, pc; } arm_saved_state64_t;
typedef arm_saved_state64_t arm_saved_state_t;
#define saved_state64(s) (s)
#define is_saved_state64(s) 1
#define set_saved_state_lr(s, v) ((s)->lr = (v))
#define set_saved_state_fp(s, v) ((s)->fp = (v))
#define set_saved_state_reg(s, n, v) ((s)->x[n] = (v))
#define get_saved_state_sp(s) ((s)->sp)
#define DMB_ISH 0
#define __builtin_arm_dmb(x) ((void)0)
#define _Atomic
'''
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, 'lse.c'), 'w').write(hdr + body)
        exe = os.path.join(d, 'lse-test')
        subprocess.run(['cc', '-O1', '-w', '-o', exe, os.path.join(HERE, 'lse-test-main.c'),
                        os.path.join(d, 'lse.c'), os.path.join(HERE, 'lse-test-stubs.c')], check=True)
        sys.exit(subprocess.run([exe]).returncode)


if __name__ == '__main__':
    main()
