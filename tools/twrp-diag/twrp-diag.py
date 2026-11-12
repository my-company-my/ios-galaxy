#!/usr/bin/env python3
"""Build the diagnostic TWRP for the J7 Neo from the checked j7velte image.

  twrp-diag.py TWRP-3.7.1-j7velte.img OUT.img

Input must be the image the app downloads (SHA-256 below). Only the
ramdisk changes: it gets /sbin/iosgalaxy-diag.sh (this directory) and a
service in /init.recovery.exynos7870.rc that runs it at boot. The kernel,
dt.img (Samsung DTBH) and header fields are kept, and like the original
the image has no SEANDROIDENFORCE tag (tools/mkbootimg_samsung.py rebuilds
it from the original as "stock"). The ramdisk is compressed like the original: LZMA "alone",
lc=3 lp=0 pb=2, 8 MiB dictionary, unknown size + end marker.
"""
import hashlib, lzma, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
import mkbootimg_samsung as mkb  # noqa: E402

BASE_SHA256 = '696cc964d70c6fdb86952b477f9afd5a2adefa3e259eea32c5df31db8f52b69f'
RC = 'init.recovery.exynos7870.rc'
SCRIPT = 'sbin/iosgalaxy-diag.sh'
RC_ADD = '''
# iOS Galaxy (tools/twrp-diag): USB report, MUIC switch attempt, back to
# Android after 90 s unless a computer configured USB.
service iosgalaxy_diag /sbin/sh /sbin/iosgalaxy-diag.sh
    user root
    group root
    seclabel u:r:recovery:s0
    oneshot
    disabled

on boot
    start iosgalaxy_diag
'''


def cpio_read(data):
    """newc entries: [name, fields(13 ints), payload]; stops at TRAILER!!!."""
    out, i = [], 0
    while True:
        if data[i:i + 6] not in (b'070701', b'070702'):
            raise SystemExit(f'cpio: bad magic at {i}')
        f = [int(data[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
        nsize, fsize = f[11], f[6]
        name = data[i + 110:i + 110 + nsize - 1].decode()
        i += 110 + nsize
        i += -i % 4
        payload = data[i:i + fsize]
        i += fsize
        i += -i % 4
        if name == 'TRAILER!!!':
            return out
        out.append([name, f, payload])


def cpio_write(entries):
    out = bytearray()
    for ino, (name, f, payload) in enumerate(entries + [['TRAILER!!!', [0] * 13, b'']], 1):
        f = list(f)
        f[0] = ino if name != 'TRAILER!!!' else 0
        f[6] = len(payload)
        f[11] = len(name) + 1
        if name == 'TRAILER!!!':
            f[4] = 1  # nlink
        out += b'070701' + b''.join(b'%08X' % v for v in f) + name.encode() + b'\0'
        out += b'\0' * (-len(out) % 4)
        out += payload
        out += b'\0' * (-len(out) % 4)
    out += b'\0' * (-len(out) % 512)
    return bytes(out)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    img = open(src, 'rb').read()
    got = hashlib.sha256(img).hexdigest()
    if got != BASE_SHA256:
        sys.exit(f'{src}: SHA-256 {got}, not the checked TWRP-3.7.1-j7velte image')
    h, s = mkb.parse(img)
    rd = s['ramdisk']
    if rd[:13] != bytes([0x5d, 0, 0, 0x80, 0]) + b'\xff' * 8:
        sys.exit('ramdisk is not LZMA alone (0x5d, 8 MiB, unknown size)')
    entries = cpio_read(lzma.decompress(rd, format=lzma.FORMAT_ALONE))
    names = [e[0] for e in entries]
    if SCRIPT in names:
        sys.exit('already a diagnostic image')
    rc = next(e for e in entries if e[0] == RC)
    rc[2] = rc[2] + RC_ADD.encode()
    template = next(e for e in entries if e[0] == 'sbin/sh')       # regular file, root:root
    script = open(os.path.join(HERE, 'iosgalaxy-diag.sh'), 'rb').read()
    f = list(template[1])
    f[1] = 0o100750   # -rwxr-x---
    f[2] = f[3] = 0   # uid, gid root
    entries.insert(names.index('sbin/sh') + 1, [SCRIPT, f, script])
    filters = [{'id': lzma.FILTER_LZMA1, 'dict_size': 1 << 23, 'lc': 3, 'lp': 0, 'pb': 2}]
    new_rd = lzma.compress(cpio_write(entries), format=lzma.FORMAT_ALONE, filters=filters)
    out = mkb.build(img, s['kernel'], new_rd)
    if not img.endswith(mkb.SEANDROID):
        out = out[:-len(mkb.SEANDROID)]   # this TWRP has no tag: keep it that way
    open(dst, 'wb').write(out)
    print(f'{dst}: {len(out)} bytes, SHA-256 {hashlib.sha256(out).hexdigest()}')


if __name__ == '__main__':
    main()
