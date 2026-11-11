#!/usr/bin/env python3
"""Find instructions newer than ARMv8.0 in iOS code (dyld shared cache or Mach-O).

  check-armv80.py [--strict] FILE [FILE...]

--strict: exit 1 if anything is found (used by CI on the kernel itself,
which must be pure ARMv8.0: the emulation is for user code only).

The Galaxy J7 Neo's Cortex-A53 is ARMv8.0-A (+CRC, +Crypto). The iPhone 8
userland targets the A11 (ARMv8.2). This scans the executable mappings of
dyld shared cache files (dyld_shared_cache_arm64 and its .01, .02 ...
subcaches, from the SystemOS cryptex) or the __TEXT,__text of plain
Mach-O files, and counts encodings of:

  lse       CAS*, CASP*, LD<op>*, ST<op>*, SWP*  (ARMv8.1)  -> emulated by the
            kernel (osfmk/arm64/sweet_lse.c), one trap each: slow if frequent
  ldapr     LDAPR*  (ARMv8.3 RCpc)                            -> emulated too
  ldapur    LDAPUR*/STLUR* (ARMv8.4)                          -> NOT emulated
  fjcvtzs   FJCVTZS (ARMv8.3, JavaScript conversion)          -> NOT emulated
  dotprod   SDOT/UDOT vector (ARMv8.2 optional, A13+)         -> NOT emulated
  rdm       SQRDMLAH/SQRDMLSH vector (ARMv8.1)                -> NOT emulated
  fp16      half-precision vector arithmetic (ARMv8.2)        -> NOT emulated

Code reached only after a CPU feature check (hw.optional.arm.FEAT_*,
the commpage capability bits) is fine; unconditional use is not. A
non-zero count is a lead, not a verdict: instruction words are matched by
encoding, literal data inside code sections can match too. Addresses are
printed so they can be symbolicated (e.g. `ipsw dyld a2s CACHE ADDR`).
Needs numpy (pip3 install numpy).
"""
import struct, sys

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
]
SHOW = 8


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
    if struct.unpack_from('<I', buf, 0)[0] != 0xfeedfacf:
        return None
    ncmds = struct.unpack_from('<I', buf, 16)[0]
    off, out = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', buf, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from('<I', buf, off + 64)[0]
            for s in range(nsects):
                so = off + 72 + 80 * s
                sect, seg = buf[so:so + 16].rstrip(b'\0'), buf[so + 16:so + 32].rstrip(b'\0')
                addr, size, foff = struct.unpack_from('<QQI', buf, so + 32)
                if seg in (b'__TEXT', b'__TEXT_EXEC') and sect in (b'__text', b'__stubs', b'__auth_stubs'):
                    out.append((foff, size, addr))
        off += size
    return out


def scan(path):
    with open(path, 'rb') as f:
        buf = f.read()
    maps = mappings_dsc(buf)
    kind = 'dyld cache'
    if maps is None:
        maps, kind = mappings_macho(buf), 'Mach-O'
    if maps is None:
        print(f'{path}: not a dyld cache or 64-bit Mach-O, skipped')
        return {}
    totals = {}
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
                    t[1].append((addr + 4 * int(h), int(w[h])))
    print(f'{path}: {kind}, {words_seen * 4 >> 20} MiB of code')
    return totals


def main():
    args = sys.argv[1:]
    strict = '--strict' in args
    args = [a for a in args if a != '--strict']
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
        for addr, word in samples:
            print(f'          0x{addr:x}: 0x{word:08x}')
    if bad:
        print('\nSome encodings are not emulated: check whether that code runs without a feature check.')
    if strict:
        sys.exit(1)


if __name__ == '__main__':
    main()
