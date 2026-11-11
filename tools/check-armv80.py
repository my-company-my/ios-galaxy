#!/usr/bin/env python3
"""Find instructions newer than ARMv8.0 in iOS code (dyld shared cache or Mach-O).

  check-armv80.py [--strict] FILE [FILE...]

--strict: exit 1 if anything is found (used by CI on the kernel itself,
which must be pure ARMv8.0: the emulation is for user code only).
--min-code-kib N: exit 1 if a file has less than N KiB of code (a guard
against a parser bug that scans nothing; CI uses it on the kernel).

The Galaxy J7 Neo's Cortex-A53 is ARMv8.0-A (+CRC, +Crypto). The iPhone 8
userland targets the A11 (ARMv8.2). This scans the executable mappings of
dyld shared cache files (dyld_shared_cache_arm64 and its .01, .02 ...
subcaches, from the SystemOS cryptex) or every instruction section of plain
Mach-O files (S_ATTR_PURE/SOME_INSTRUCTIONS: __text, __stubs, the kernel's
__commpage_text, __KLD...), and counts encodings of:

  lse       CAS*, CASP*, LD<op>*, ST<op>*, SWP*  (ARMv8.1)  -> emulated by the
            kernel (osfmk/arm64/sweet_lse.c), one trap each: slow if frequent
  ldapr     LDAPR*  (ARMv8.3 RCpc)                            -> emulated too
  ldapur    LDAPUR*/STLUR* (ARMv8.4)                          -> NOT emulated
  fjcvtzs   FJCVTZS (ARMv8.3, JavaScript conversion)          -> NOT emulated
  dotprod   SDOT/UDOT vector (ARMv8.2 optional, A13+)         -> NOT emulated
  rdm       SQRDMLAH/SQRDMLSH vector (ARMv8.1)                -> NOT emulated
  fp16      half-precision vector arithmetic (ARMv8.2)        -> NOT emulated
  pstate    MSR/MRS of PAN, UAO, DIT, SSBS (ARMv8.1-8.5)      -> NOT emulated

Code reached only after a CPU feature check (hw.optional.arm.FEAT_*,
the commpage capability bits) is fine; unconditional use is not. A
non-zero count is a lead, not a verdict: instruction words are matched by
encoding, literal data inside code sections can match too. Addresses are
printed so they can be symbolicated (e.g. `ipsw dyld a2s CACHE ADDR`).
Needs numpy (pip3 install numpy).
"""
import bisect, collections, struct, sys

try:
    import numpy as np
except ImportError:
    sys.exit('needs numpy: pip3 install numpy')

# (name, mask, value, emulated)
PATTERNS = [
    ('lse-cas',  0x3fa07c00, 0x08a07c00, True),
    ('lse-casp', 0xbfa07c00, 0x08207c00, True),
    ('lse-rmw',  0x3f200c00, 0x38200000, True),    # includes LDAPR (o3=1, opc=100)
    ('ldapur',   0x3f200c00, 0x19000000, False),   # LDAPUR*/STLUR* family (size 011001 opc 0)
    ('fjcvtzs',  0xfffffc00, 0x1e7e0000, False),
    ('dotprod',  0x9fe0fc00, 0x0e809400, False),   # SDOT/UDOT (vector), any U
    ('rdm',      0xbf20f400, 0x2e008400, False),   # SQRDMLAH/SQRDMLSH (vector)
    ('fp16',     0x9f60c400, 0x0e400400, False),   # three-same FP16 vector ops
    # PSTATE fields the A53 lacks: MSR (immediate), then MRS/MSR (register)
    ('pstate',   0xfffff0ff, 0xd500409f, False),   # MSR PAN, #imm   (ARMv8.1)
    ('pstate',   0xfffff0ff, 0xd500407f, False),   # MSR UAO, #imm   (ARMv8.2)
    ('pstate',   0xfffff0ff, 0xd503405f, False),   # MSR DIT, #imm   (ARMv8.4)
    ('pstate',   0xfffff0ff, 0xd503403f, False),   # MSR SSBS, #imm  (ARMv8.5)
    ('pstate',   0xffdfffe0, 0xd5184260, False),   # MRS/MSR PAN
    ('pstate',   0xffdfffe0, 0xd5184280, False),   # MRS/MSR UAO
    ('pstate',   0xffdfffe0, 0xd51b42a0, False),   # MRS/MSR DIT
    ('pstate',   0xffdfffe0, 0xd51b42c0, False),   # MRS/MSR SSBS
]
S_ATTR_PURE_INSTRUCTIONS, S_ATTR_SOME_INSTRUCTIONS = 0x80000000, 0x400
SHOW = 8
MIN_KIB = 0


def mappings_dsc(buf):
    """Executable (file offset, size, address) ranges of one cache file."""
    magic = buf[:16]
    if not magic.startswith(b'dyld_v1'):
        return None
    off, count = struct.unpack_from('<II', buf, 0x10)
    out = []
    for i in range(count):
        addr, size, foff, maxprot, initprot = struct.unpack_from('<QQQII', buf, off + 32 * i)
        if initprot & 4:
            out.append((foff, size, addr))
    return out


def mappings_macho(buf):
    """(file offset, size, address) of every section that holds instructions."""
    if struct.unpack_from('<I', buf, 0)[0] != 0xfeedfacf:
        return None
    ncmds = struct.unpack_from('<I', buf, 16)[0]
    off, out = 32, []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', buf, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from('<I', buf, off + 64)[0]
            for s in range(nsects):
                so = off + 72 + 80 * s
                addr, ssize, foff = struct.unpack_from('<QQI', buf, so + 32)
                flags = struct.unpack_from('<I', buf, so + 64)[0]
                stype = flags & 0xff
                # S_ZEROFILL (1), S_GB_ZEROFILL (12), S_THREAD_LOCAL_ZEROFILL (18) have no file data
                if flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS) and stype not in (1, 12, 18) and foff:
                    out.append((foff, ssize, addr))
        off += cmdsize
    return out


def symbols_macho(buf):
    """Sorted (address, name) of the defined section symbols (LC_SYMTAB), or []."""
    ncmds = struct.unpack_from('<I', buf, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', buf, off)
        if cmd == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', buf, off + 8)
            syms = []
            for i in range(nsyms):
                strx, ntype, nsect, ndesc, value = struct.unpack_from('<IBBHQ', buf, symoff + 16 * i)
                if ntype & 0xe0 or (ntype & 0x0e) != 0x0e or not strx or strx >= strsize:
                    continue  # stab, or not defined in a section
                end = buf.index(b'\0', stroff + strx)
                name = buf[stroff + strx:end].decode('latin-1')
                if not name.startswith(('ltmp', 'L')):  # assembler temporaries
                    syms.append((value, name))
            syms.sort()
            return syms
        off += cmdsize
    return []


def symbolize(syms, addrs, addr):
    i = bisect.bisect_right(addrs, addr) - 1
    if i < 0:
        return ''
    return f'{syms[i][1]}+0x{addr - syms[i][0]:x}'


def scan(path):
    with open(path, 'rb') as f:
        buf = f.read()
    maps = mappings_dsc(buf)
    kind, syms = 'dyld cache', []
    if maps is None:
        maps, kind = mappings_macho(buf), 'Mach-O'
        if maps is not None:
            syms = symbols_macho(buf)
    if maps is None:
        print(f'{path}: not a dyld cache or 64-bit Mach-O, skipped')
        return {}
    saddrs = [a for a, _ in syms]
    totals = {}
    per_func = collections.Counter()
    words_seen = 0
    for foff, size, addr in maps:
        size -= size % 4
        w = np.frombuffer(buf, dtype='<u4', count=size // 4, offset=foff)
        words_seen += len(w)
        for name, mask, value, _ in PATTERNS:
            hits = np.nonzero((w & mask) == value)[0]
            if len(hits):
                t = totals.setdefault(name, [0, []])
                t[0] += len(hits)
                for h in hits[:SHOW - len(t[1])]:
                    a = addr + 4 * int(h)
                    t[1].append((a, int(w[h]), symbolize(syms, saddrs, a) if syms else ''))
                if syms:
                    for h in hits:
                        f = symbolize(syms, saddrs, addr + 4 * int(h)).rsplit('+', 1)[0]
                        per_func[(f, name)] += 1
    print(f'{path}: {kind}, {words_seen * 4 >> 10} KiB of code in {len(maps)} ranges'
          + (f', {len(syms)} symbols' if syms else ''))
    if words_seen * 4 >> 10 < MIN_KIB:
        sys.exit(f'{path}: less than {MIN_KIB} KiB of code scanned')
    if per_func:
        print(f'functions with hits ({len(per_func)}, most first):')
        for (f, name), n in per_func.most_common(40):
            print(f'  {n:6d}  {name:9}  {f}')
    return totals


def main():
    args = sys.argv[1:]
    global MIN_KIB
    strict = '--strict' in args
    args = [a for a in args if a != '--strict']
    if '--min-code-kib' in args:
        i = args.index('--min-code-kib')
        MIN_KIB = int(args[i + 1])
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)
    grand = {}
    for p in args:
        for name, (n, samples) in scan(p).items():
            g = grand.setdefault(name, [0, []])
            g[0] += n
            g[1] += samples[:SHOW - len(g[1])]
    emulated = {n: e for n, _, _, e in PATTERNS}
    if not grand:
        print('no post-ARMv8.0 encodings found')
        return
    bad = False
    for name, (n, samples) in sorted(grand.items()):
        tag = 'emulated by the kernel' if emulated[name] else 'NOT EMULATED'
        bad |= not emulated[name]
        print(f'{name:9} {n:9d}  ({tag})')
        for addr, word, sym in samples:
            print(f'          0x{addr:x}: 0x{word:08x}  {sym}')
    if bad:
        print('\nSome encodings are not emulated: check whether that code runs without a feature check.')
    if strict:
        sys.exit(1)


if __name__ == '__main__':
    main()
