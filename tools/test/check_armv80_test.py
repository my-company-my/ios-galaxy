#!/usr/bin/env python3
"""Regression test for tools/check-armv80.py on real clang Mach-O objects.

  python3 tools/test/check_armv80_test.py

Needs clang (any host: it only assembles for arm64-apple-macos) and numpy.
Checks that the scanner:
  - walks every load command (a bug once made it stop after the first
    segment, so CI scanned < 1 MiB of the kernel and reported nothing);
  - reads every instruction section, not only __text (the kernel's
    __TEXT_EXEC,__commpage_text runs in every iOS process);
  - ignores data sections, even when their words look like instructions;
  - finds LSE and PSTATE (PAN/UAO/DIT/SSBS) accesses, but not the ARMv8.0
    system register accesses next to them in the encoding space;
  - names the function of each hit, exits 1 in --strict mode and with
    --min-code-kib above the code size;
  - with --ignore-symbol, skips a data table kept in __text (the kernel's
    SHA-256 K256: K256[57] = 0x78a5636f has an LSE encoding) but still
    prints it, and counts it without the option.
"""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, '..', 'check-armv80.py')

SRC = r'''
	.text
	.globl _plain_v80
_plain_v80:
	ldaxr	w0, [x1]
	stlxr	w2, w0, [x1]
	msr	SPSel, #1
	msr	DAIFSet, #2
	msr	DAIFClr, #2
	mrs	x0, NZCV
	mrs	x1, DAIF
	mrs	x2, CurrentEL
	mrs	x3, SPSel
	mrs	x4, ELR_EL1
	msr	SP_EL0, x6
	nop
	ret
	.globl _uses_lse
_uses_lse:
	ldaddal	x1, x0, [x2]
	casal	w1, w2, [x3]
	swp	x1, x2, [x3]
	ret
	.globl _uses_pstate
_uses_pstate:
	msr	PAN, #1
	msr	UAO, #0
	msr	DIT, #1
	msr	SSBS, #0
	mrs	x0, PAN
	msr	UAO, x1
	mrs	x2, DIT
	msr	SSBS, x3
	ret
	.p2align 4
K256:					// data in __text, like sha256_compress_arm64.s
	.long	0x428a2f98, 0x71374491, 0x78a5636f, 0xc67178f2
	.section __TEXT_EXEC,__commpage_text,regular,pure_instructions
	.globl _pfz_like
_pfz_like:
	casa	w10, w11, [x3]
	ret
	.section __TEXT,__const
_data_looks_like_lse:
	.long 0x88ea7c6a, 0xc8a07c41, 0xf8e10040, 0xd500419f
	.section __DATA,__data
_more_data:
	.long 0x88ea7c6a, 0xf8e10040
'''

CLEAN = '''
	.text
	.globl _only_v80
_only_v80:
	ldaxr	w0, [x1]
	stlxr	w2, w0, [x1]
	ret
	.section __TEXT,__const
_data:
	.long 0x88ea7c6a
'''


def assemble(tmp, name, text):
    s, o = os.path.join(tmp, name + '.s'), os.path.join(tmp, name + '.o')
    with open(s, 'w') as f:
        f.write(text)
    subprocess.run(['clang', '-target', 'arm64-apple-macos13', '-march=armv8.5-a+ssbs',
                    '-c', s, '-o', o], check=True)
    return o


def run(*args):
    p = subprocess.run([sys.executable, TOOL, *args], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def main():
    fails = []

    def check(cond, what, out):
        print(('ok    ' if cond else 'FAIL  ') + what)
        if not cond:
            fails.append(what)
            print(out)

    with tempfile.TemporaryDirectory() as tmp:
        obj = assemble(tmp, 'mixed', SRC)
        rc, out = run('--strict', '--ignore-symbol', 'K256', obj)
        counts = dict(re.findall(r'^(\S+)\s+(\d+)\s+\(', out, re.M))
        check(rc == 1, '--strict exits 1 when something is found', out)
        check('in 2 ranges' in out, 'two instruction sections scanned (__text, __commpage_text), no data', out)
        check(counts.get('lse-cas') == '2', 'lse-cas: casal in __text + casa in __commpage_text', out)
        check(counts.get('lse-rmw') == '2', 'lse-rmw: ldaddal + swp (K256 ignored)', out)
        check(counts.get('pstate') == '8', 'pstate: 4 MSR immediate + 4 MRS/MSR register', out)
        check(len(counts) == 3, 'no other pattern matches', out)
        check('_plain_v80' not in out, 'ARMv8.0 system register accesses are not reported', out)
        check(re.search(r'^\s+1\s+lse-cas\s+_pfz_like$', out, re.M) is not None,
              'hit named by its function (_pfz_like)', out)
        check('ltmp' not in out, 'assembler temporary labels are not used as names', out)
        check('ignored (--ignore-symbol): 1 lse-rmw in K256' in out, 'ignored K256 hit is printed', out)

        rc, out = run(obj)
        counts = dict(re.findall(r'^(\S+)\s+(\d+)\s+\(', out, re.M))
        check(counts.get('lse-rmw') == '3' and 'K256+0x8' in out,
              'without --ignore-symbol the K256 constant counts (K256+0x8)', out)

        rc, out = run('--min-code-kib', '1', obj)
        check(rc == 1 and 'less than 1 KiB' in out, '--min-code-kib fails when too little code is read', out)

        clean = assemble(tmp, 'clean', CLEAN)
        rc, out = run('--strict', clean)
        check(rc == 0 and 'no post-ARMv8.0 encodings found' in out, 'ARMv8.0-only object passes --strict', out)

    print('PASS' if not fails else f'{len(fails)} FAILED')
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
