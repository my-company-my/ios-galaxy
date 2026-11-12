#!/usr/bin/env python3
"""Samsung (S-BOOT) Android boot images: header v0 with a dt.img section.

  mkbootimg_samsung.py --info IMG
  mkbootimg_samsung.py --stock STOCK.img --kernel IMAGE (--ramdisk FILE | --empty-ramdisk) -o OUT.img

Layout (Exynos 7870 boot images; osm0sis mkbootimg --dt):
  struct boot_img_hdr (1632 bytes, at offset 0, padded to page_size):
    "ANDROID!", kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
    second_size, second_addr, tags_addr, page_size, dt_size, os_version,
    name[16], cmdline[512], id[32], extra_cmdline[1024]
  then kernel, ramdisk, second and dt.img (Exynos: Samsung "DTBH" table),
  each padded to page_size,
  then the "SEANDROIDENFORCE" tag Samsung appends.

Everything but kernel and ramdisk (addresses, page size, os_version, board
name, cmdline and the dt.img S-BOOT picks the device tree from) is copied
from the phone's own stock boot image. S-BOOT ignores the load addresses
(it places the kernel itself), but keeping the stock values costs nothing.
"""
import argparse, gzip, hashlib, struct, sys

HDR = struct.Struct('<8s10I16s512s32s1024s')
assert HDR.size == 1632
SEANDROID = b'SEANDROIDENFORCE'


def pad(n, page):
    return (n + page - 1) // page * page


def parse(buf):
    f = HDR.unpack_from(buf, 0)
    if f[0] != b'ANDROID!':
        raise SystemExit('not an Android boot image')
    h = dict(zip(['magic', 'kernel_size', 'kernel_addr', 'ramdisk_size', 'ramdisk_addr',
                  'second_size', 'second_addr', 'tags_addr', 'page_size', 'dt_size',
                  'os_version', 'name', 'cmdline', 'id', 'extra_cmdline'], f))
    page = h['page_size']
    if page not in (2048, 4096):
        raise SystemExit(f'unexpected page size {page}')
    off = page
    sections = {}
    for name in ('kernel', 'ramdisk', 'second', 'dt'):
        size = h[name + '_size']
        sections[name] = buf[off:off + size]
        off += pad(size, page)
    # Exynos (J7 Neo): Samsung "DTBH" table of DTBs (checked on a j7velte TWRP
    # image: 3 entries, chip 0x1ebe = 7870, hw_rev 0-255); QCDT is Qualcomm.
    if h['dt_size'] and sections['dt'][:4] not in (b'DTBH', b'QCDT', b'\xd0\x0d\xfe\xed'):
        # A header v1+ image would have header_version (small) here, not a dt size.
        print(f'warning: dt section starts with {sections["dt"][:4]!r}, not DTBH, QCDT or a DTB',
              file=sys.stderr)
    return h, sections


def empty_cpio_gz():
    """gzip'd newc cpio with only the trailer (S-BOOT wants a non-empty ramdisk)."""
    name = b'TRAILER!!!\0'
    hdr = b'070701' + b''.join(b'%08X' % v for v in (0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(name), 0))
    entry = hdr + name
    entry += b'\0' * (-len(entry) % 4)
    entry += b'\0' * (-len(entry) % 512)
    return gzip.compress(entry, mtime=0)


def build(stock, kernel, ramdisk):
    h, s = parse(stock)
    page = h['page_size']
    second, dt = s['second'], s['dt']
    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, second, dt):
        sha.update(blob)
        sha.update(struct.pack('<I', len(blob)))
    ident = sha.digest().ljust(32, b'\0')
    hdr = HDR.pack(b'ANDROID!', len(kernel), h['kernel_addr'], len(ramdisk), h['ramdisk_addr'],
                   len(second), h['second_addr'], h['tags_addr'], page, len(dt), h['os_version'],
                   h['name'], h['cmdline'], ident, h['extra_cmdline'])
    out = bytearray(hdr.ljust(page, b'\0'))
    for blob in (kernel, ramdisk, second, dt):
        out += blob + b'\0' * (pad(len(blob), page) - len(blob))
    return bytes(out) + SEANDROID


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--info')
    ap.add_argument('--stock')
    ap.add_argument('--kernel')
    ap.add_argument('--ramdisk')
    ap.add_argument('--empty-ramdisk', action='store_true')
    ap.add_argument('--max-size', type=lambda v: int(v, 0), default=0,
                    help='fail if the image is larger (BOOT partition size)')
    ap.add_argument('-o', '--output')
    a = ap.parse_args()
    if a.info:
        h, s = parse(open(a.info, 'rb').read())
        for k in ('kernel_size', 'kernel_addr', 'ramdisk_size', 'ramdisk_addr', 'second_size',
                  'second_addr', 'tags_addr', 'page_size', 'dt_size', 'os_version'):
            print(f'{k:13} 0x{h[k]:x}')
        print('name         ', h['name'].rstrip(b'\0').decode(errors='replace'))
        print('cmdline      ', h['cmdline'].rstrip(b'\0').decode(errors='replace'))
        print('dt magic     ', s['dt'][:4])
        return
    if not (a.stock and a.kernel and a.output and (a.ramdisk or a.empty_ramdisk)):
        ap.error('--stock, --kernel, --ramdisk/--empty-ramdisk and -o are required')
    ramdisk = open(a.ramdisk, 'rb').read() if a.ramdisk else empty_cpio_gz()
    img = build(open(a.stock, 'rb').read(), open(a.kernel, 'rb').read(), ramdisk)
    if a.max_size and len(img) > a.max_size:
        raise SystemExit(f'{a.output}: {len(img)} bytes does not fit the {a.max_size}-byte BOOT partition '
                         '(try a RELEASE kernel)')
    open(a.output, 'wb').write(img)
    print(f'{a.output}: {len(img)} bytes', file=sys.stderr)


if __name__ == '__main__':
    main()
