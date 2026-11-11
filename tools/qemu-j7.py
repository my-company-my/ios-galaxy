#!/usr/bin/env python3
"""Run the J7 Neo shim in QEMU (virt, GIC-400, Cortex-A53) and check what it hands to xnu.

  qemu-j7.py [--payload FILE] [--in-kernel] [--boot-mpidr N] [--keep DIR]

Without --payload it builds a test payload: the ADT of mkadt.py --qemu-like
layout but with all eight J7 cores, and a 'kernel' of a few instructions
that copies x0 (boot_args) and its first words to a mailbox and paints the
top of the framebuffer green. QEMU then dumps memory and the script checks:
  - the shim found the payload (ramdisk, or appended with --in-kernel)
  - the kernel segment landed at phys_base, x0 = boot_args, boot_args fields
  - the ADT behind the kernel, with the boot core as cpu0 (--boot-mpidr N
    pretends S-BOOT started on that core: the shim reads MPIDR, so this
    edits the test ADT instead, putting N's node first is NOT done; the
    shim must swap)
  - --el2: the shim is entered at EL2 and must drop to EL1
  - DIR/fb.png shows the screen (needs Pillow, optional)
Needs qemu-system-aarch64 (macOS: brew install qemu) and a built shim
(shim/build.sh; this script reads shim/out/Image).

QEMU virt has no Exynos hardware: this tests the shim and loader only.
"""
import argparse, os, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import adt, mkadt  # noqa: E402

BOOT_LINE_LENGTH = 608
VIRT_BASE = 0xfffffff006000000
MAILBOX = 0x80000800        # inside the test kernel's segment, after its code


def test_kernel():
    """aarch64 code at entry (= phys_base + 0x100): x0 = boot_args PA."""
    # x1 = MAILBOX; [x1] = x0; [x1+8] = ba->physBase; [x1+16] = ba->Video.v_baseAddr;
    # [x1+24] = ba->deviceTreeP; [x1+32] = CurrentEL; fill 720*8 fb pixels green; wfe loop
    def movz_x(reg, imm16, shift):
        return 0xd2800000 | ((shift // 16) << 21) | (imm16 << 5) | reg
    def movk_x(reg, imm16, shift):
        return 0xf2800000 | ((shift // 16) << 21) | (imm16 << 5) | reg
    def mov64(reg, v):
        out = [movz_x(reg, v & 0xffff, 0)]
        for s in (16, 32, 48):
            if (v >> s) & 0xffff:
                out.append(movk_x(reg, (v >> s) & 0xffff, s))
        return out
    code = []
    code += mov64(1, MAILBOX)
    code += [0xf9000020]                    # str x0, [x1]
    code += [0xf9400802, 0xf9000422]        # ldr x2,[x0,#16] (physBase); str x2,[x1,#8]
    code += [0xf9401402, 0xf9000822]        # ldr x2,[x0,#40] (Video.v_baseAddr); str x2,[x1,#16]
    code += [0xf9403002]                    # ldr x2,[x0,#96] (deviceTreeP)
    code += [0xf9000c22]                    # str x2,[x1,#24]
    code += [0xd5384242, 0xf9001022]        # mrs x2, CurrentEL; str x2,[x1,#32]
    code += mov64(3, 0x67000000)
    code += mov64(4, 720 * 8)
    code += mov64(5, 0xff00ff00)
    code += [0xb8004465, 0xf1000484, 0x54ffffc1]  # loop: str w5,[x3],#4; subs x4,x4,#1; b.ne loop
    code += [0xd503205f, 0x17ffffff]        # wfe; b .
    return b''.join(struct.pack('<I', c) for c in code)


def test_payload(adt_blob):
    phys_base = mkadt.PHYS_BASE
    mem_size = mkadt.MEM_SIZE - mkadt.PANIC_LOG_SIZE
    kseg = b'\0' * 0x100 + test_kernel()
    kseg = kseg.ljust(0x4000, b'\0')
    entry = VIRT_BASE + 0x100
    seg_table = 0x2a8
    nsegs = 1
    data_off = (seg_table + 32 * nsegs + 0x3fff) & ~0x3fff
    adt_off = data_off + len(kseg)
    kernel_end = VIRT_BASE + len(kseg)
    hdr = b'SWEETXNU' + struct.pack('<II', 1, nsegs)
    hdr += struct.pack('<7Q', VIRT_BASE, entry, adt_off, len(adt_blob), kernel_end, phys_base, mem_size)
    hdr += b'cpus=1 debug=0xc'.ljust(BOOT_LINE_LENGTH, b'\0')
    assert len(hdr) == seg_table
    hdr += struct.pack('<4Q', VIRT_BASE, len(kseg), data_off, len(kseg))
    return hdr.ljust(data_off, b'\0') + kseg + adt_blob


def qemu_dump(image, initrd, outdir, secs, el2=False):
    mon = os.path.join(tempfile.mkdtemp(prefix='qj7'), 'mon')   # short: unix socket path limit
    machine = 'virt,gic-version=2' + (',virtualization=on' if el2 else '')
    args = ['qemu-system-aarch64', '-M', machine, '-cpu', 'cortex-a53',
            '-m', '4G', '-smp', '1', '-display', 'none', '-serial', 'null',
            '-kernel', image, '-monitor', f'unix:{mon},server,nowait']
    if initrd:
        args += ['-initrd', initrd]
    q = subprocess.Popen(args)
    try:
        time.sleep(secs)
        import socket
        s = socket.socket(socket.AF_UNIX)
        s.connect(mon)
        def cmd(c):
            s.sendall(c.encode() + b'\n')
            time.sleep(0.5)
        cmd(f'pmemsave 0x67000000 {720 * 1280 * 4} "{outdir}/fb.raw"')
        cmd(f'pmemsave 0x80000000 0x200000 "{outdir}/k.raw"')
        cmd('quit')
        s.close()
    finally:
        q.wait(timeout=10)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--payload')
    ap.add_argument('--in-kernel', action='store_true')
    ap.add_argument('--boot-mpidr', type=lambda v: int(v, 0), default=0)
    ap.add_argument('--secs', type=float, default=3)
    ap.add_argument('--el2', action='store_true', help='enter the shim at EL2 (QEMU virtualization=on)')
    ap.add_argument('--keep')
    a = ap.parse_args()
    out = a.keep or tempfile.mkdtemp()
    os.makedirs(out, exist_ok=True)
    image = os.path.join(HERE, '../shim/out/Image')

    tree = mkadt.build(seed=b'\0' * 64)
    # QEMU virt GIC/timer, but keep all eight cores to exercise the boot-core swap.
    for c in tree.children:
        if c.name == 'arm-io':
            for g in c.children:
                if g.name == 'gic':
                    g.props = [(k, f, mkadt.u64(mkadt.QEMU_GICD - mkadt.SOC_BASE, 0x1000,
                                                mkadt.QEMU_GICC - mkadt.SOC_BASE, 0x2000) if k == 'reg' else v)
                               for k, f, v in g.props]
    if a.boot_mpidr:
        # QEMU's single core has MPIDR 0. Renumber the test ADT so that core 0
        # appears at the position of --boot-mpidr: the shim must move it to cpu0.
        for c in tree.children:
            if c.name == 'cpus':
                regs = [cpu.prop('reg') for cpu in c.children]
                want = struct.pack('<I', a.boot_mpidr)
                j = regs.index(want)
                for cpu in c.children:
                    r = cpu.prop('reg')
                    nr = struct.pack('<I', 0) if r == want else (want if r == struct.pack('<I', 0) else r)
                    cpu.props = [(k, f, nr if k == 'reg' else v) for k, f, v in cpu.props]
                print(f'test ADT: MPIDR 0 placed at /cpus child {j}', file=sys.stderr)
    adt_blob = adt.serialize(tree)
    payload = open(a.payload, 'rb').read() if a.payload else test_payload(adt_blob)
    pfile = os.path.join(out, 'payload.bin')
    open(pfile, 'wb').write(payload)

    if a.in_kernel:
        img = open(image, 'rb').read()
        img += b'\0' * (-len(img) % 4096) + payload
        image = os.path.join(out, 'Image+payload')
        open(image, 'wb').write(img)
        qemu_dump(image, None, out, a.secs, a.el2)
    else:
        qemu_dump(image, pfile, out, a.secs, a.el2)

    fb = open(os.path.join(out, 'fb.raw'), 'rb').read()
    k = open(os.path.join(out, 'k.raw'), 'rb').read()
    ok = True
    def check(cond, what):
        nonlocal ok
        print(('OK   ' if cond else 'FAIL ') + what)
        ok &= bool(cond)
    try:
        from PIL import Image
        im = Image.frombuffer('RGBA', (720, 1280), fb, 'raw', 'BGRA', 0, 1)
        im.save(os.path.join(out, 'fb.png'))
        print(f'screen: {out}/fb.png')
    except ImportError:
        pass
    if a.payload:
        return
    mb = MAILBOX - mkadt.PHYS_BASE
    ba, phys, video, dtp, el = struct.unpack_from('<5Q', k, mb)
    check(struct.unpack_from('<I', fb, 0)[0] == 0xff00ff00, 'test kernel ran (green band on the framebuffer)')
    check(phys == mkadt.PHYS_BASE, f'boot_args.physBase = 0x{phys:x}')
    check(video == 0x67000000, f'boot_args.Video.v_baseAddr = 0x{video:x}')
    check(el == 4, f'kernel entered at EL{el >> 2}')
    adt_pa = dtp - VIRT_BASE + mkadt.PHYS_BASE
    root, _ = adt.parse(k[adt_pa - mkadt.PHYS_BASE:])
    cpus = next(c for c in root.children if c.name == 'cpus')
    regs = [struct.unpack('<I', c.prop('reg'))[0] for c in cpus.children]
    check(regs[0] == 0, f'boot core (MPIDR 0) is cpu0: /cpus regs {[hex(r) for r in regs]}')
    check(sorted(regs) == sorted(mkadt.MPIDRS), 'all eight MPIDRs still present once')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
