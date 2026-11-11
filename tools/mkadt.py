#!/usr/bin/env python3
"""Build the Apple Device Tree (ADT) the Galaxy J7 Neo xnu boots with.

Only what the kernel and the iOS userland actually read; every MMIO address
comes from the Exynos 7870 / exynos7870-j7velte device trees (Linux).

  mkadt.py OUT.adt [--dump] [--qemu]

--qemu: same tree with QEMU virt's GIC-400, timer and a single CPU
(tools/qemu-j7.py, for testing the shim and the early kernel only).

Identity: the iOS userland is the iPhone 8 (iPhone10,4 / D201AP) IPSW.
MobileGestalt derives product type, device class, Home button, artwork etc.
from the root identity, /product and /buttons of the real D201AP device
tree. That tree is an Apple artifact (kept out of git): extract it from the
IPSW with
  tools/remotezip.py IPSW_URL Firmware/all_flash/DeviceTree.d201ap.im4p research/ipsw-8
  python3 tools/adt.py unwrap research/ipsw-8/Firmware/all_flash/DeviceTree.d201ap.im4p research/ipsw-8/d201ap.adt
"""
import hashlib, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402

# Kernel-managed RAM: the whole upper DDR bank. The J7 Neo has 2 GiB in two
# banks (0x40000000 + 0x3e400000, 0x80000000 + 0x40000000; the gap is the
# secure world) and the boot framebuffer sits inside the lower bank at
# 0x67000000. XNU manages one contiguous range, so the upper bank (1 GiB) it is.
PHYS_BASE = 0x80000000
MEM_SIZE = 0x40000000
# Panic log buffer, carved from the TOP of the dram range and exposed to XNU as
# /pram + /chosen/embedded-panic-log-size. Without it, pe_init.c's
# check_for_panic_log() leaves gPanicBase == 0, debug_log_init() bails out twice
# and the kernel hangs right after "kdp_core zlib memory".
PANIC_LOG_SIZE = 0x100000
# /arm-io children are relative to this; it must not be 0 (serial_init bails)
SOC_BASE = 0x01000000

# GIC-400: distributor and CPU interface (Linux exynos7870.dtsi gic@104e1000)
GICD, GICD_SIZE = 0x104e1000, 0x1000
GICC, GICC_SIZE = 0x104e2000, 0x2000
TIMEBASE = 26000000          # S-BOOT leaves CNTFRQ_EL0 = 0; Linux DTS clock-frequency
VTIMER_INTID = 27            # PPI 11
# Boot framebuffer (S-BOOT, simple-framebuffer)
FB, FB_W, FB_H = 0x67000000, 720, 1280
FB_STRIDE = FB_W * 4
# eMMC: DW-MSHC mmc0 (bsd/dev/sweet_mmc.c), absolute physical reg
MMC, MMC_SIZE = 0x13540000, 0x2000
# Presented display: iPhone 8, 750x1334 @2x (SweetFramebuffer.cpp scales it)
CANVAS_W, CANVAS_H, DISPLAY_SCALE = 750, 1334, 2
# MPIDR of the eight Cortex-A53 cores: cluster (Aff1) 0 and 1, cores 0-3
MPIDRS = [0x000, 0x001, 0x002, 0x003, 0x100, 0x101, 0x102, 0x103]
CPU_HZ = 1586000000          # Exynos 7870 maximum, both clusters

# QEMU virt, -M virt,gic-version=2 -cpu cortex-a53
QEMU_GICD, QEMU_GICC, QEMU_TIMEBASE = 0x08000000, 0x08010000, 62500000

J7_ECID = 0x4A374E454F000001  # 'J7NEO' + 1, synthetic
BOOT_MANIFEST_HASH = hashlib.sha384(b'sweet boot manifest').digest()

HERE = os.path.dirname(os.path.abspath(__file__))
D201AP_ADT = os.path.join(HERE, '../research/ipsw-8/d201ap.adt')


def real_node(name, path=D201AP_ADT):
    """Properties of a top-level node of the real D201AP tree, without the
    syscfg placeholders iBoot would fill in (flag bit set) and the node
    bookkeeping; None if the tree or the node is missing."""
    if not os.path.exists(path):
        print(f'warning: {path} missing, no /{name} from the iPhone 8 tree', file=sys.stderr)
        return None
    root, _ = adt.parse(adt.load(path))
    for c in root.children:
        if c.name == name:
            return [(k, v) for k, f, v in c.props if not f and k not in ('name', 'AAPL,phandle')]
    print(f'warning: {path}: no /{name} node', file=sys.stderr)
    return None


u32 = lambda *v: struct.pack('<%dI' % len(v), *v)
u64 = lambda *v: struct.pack('<%dQ' % len(v), *v)
cstr = lambda s: s.encode() + b'\0'


def node(name, props=(), children=()):
    n = adt.Node()
    n.props = [('name', 0, cstr(name))] + [(k, 0, v) for k, v in props]
    n.children = list(children)
    return n


def build(seed=None, qemu=False):
    phys_base, mem_size = PHYS_BASE, MEM_SIZE
    # Carve the panic log off the top so the kernel never allocates over it.
    panic_base = phys_base + mem_size - PANIC_LOG_SIZE
    mem_size -= PANIC_LOG_SIZE
    gicd, gicc, timebase = (QEMU_GICD, QEMU_GICC, QEMU_TIMEBASE) if qemu else (GICD, GICC, TIMEBASE)
    seed = seed if seed is not None else os.urandom(64)
    phandle = iter(range(1, 1000))
    ph = lambda: ('AAPL,phandle', u32(next(phandle)))

    chosen = node('chosen', [
        ph(),
        ('dram-base', u64(phys_base)),
        ('dram-size', u64(mem_size)),
        ('random-seed', seed),
        ('debug-enabled', u32(1)),
        ('embedded-panic-log-size', u32(PANIC_LOG_SIZE)),
        ('firmware-version', cstr('j7neo-shim')),
        ('system-firmware-version', cstr('j7neo-shim')),
        # iBoot's SHA-384 of the boot manifest; /sbin/mount -P 1 exits unless
        # it exists. Fixed stand-in value.
        ('boot-manifest-hash', BOOT_MANIFEST_HASH),
        # libimg4 (cryptexd) aborts "failed to get crypto algorithm" without it.
        ('crypto-hash-method', cstr('sha2-384')),
        # MobileGestalt's screen class: display-scale from /chosen, the pixel
        # size from IOMobileFramebuffer. iPhone 8: 750x1334 @2x = 375x667 points.
        ('display-scale', u32(DISPLAY_SCALE)),
        # IOPlatformUUID (gethostuuid) on arm comes from these. Synthetic ECID
        # (not the phone's); chip-id of the A11 the iPhone 8 userland expects.
        ('unique-chip-id', struct.pack('<Q', J7_ECID)),
        ('chip-id', u32(0x8015)),
        # Security status of a dev-fused, undemoted board (tuple 0,0,1,1):
        # mobileactivationd then takes its native "Hactivation" branch.
        ('certificate-production-status', u32(0)),
        ('effective-production-status-ap', u32(0)),
        ('certificate-security-mode', u32(1)),
        ('effective-security-mode-sep', u32(1)),
    ], [node('memory-map', [ph()]),
        # Local boot policy (kern_csr.c): SIP relaxed like `csrutil disable`,
        # unauthenticated (unsealed) root. The iOS shared cache is in no
        # trust cache, so dyld can only map it with CSR_ALLOW_UNRESTRICTED_FS.
        node('asmb', [ph(), ('lp-sip0', u64(0x6f)), ('lp-sip1', u32(1))])])

    # Eight Cortex-A53 cores in MPIDR order, one homogeneous SMP cluster for
    # the scheduler. cpu0 is "running": the shim writes the boot core's MPIDR
    # into it (swapping with that core's node) if S-BOOT started on another
    # core. The kernel uses cpus=N to start a prefix (N <= 8).
    cpu_nodes = []
    for i, mpidr in enumerate(MPIDRS[:1] if qemu else MPIDRS):
        cpu_nodes.append(node(f'cpu{i}', [
            ph(),
            ('device_type', cstr('cpu')),
            ('compatible', cstr('arm,cortex-a53') + cstr('ARM,v8')),
            ('reg', u32(mpidr)),            # MPIDR Aff1:Aff0, NOT the logical ID
            ('cpu-id', u32(i)),             # descriptive: XNU assigns IDs by DT order
            ('cluster-id', u32(0)),         # descriptive; see ml_parse_cpu_topology
            ('cluster-type', u32(0)),       # homogeneous CLUSTER_TYPE_SMP
            ('die-cluster-id', u32(mpidr >> 8)),
            ('cluster-core-id', u32(mpidr & 0xff)),
            ('l2-cache-id', u32(mpidr >> 8)),       # one L2 per cluster
            ('l2-cache-size', u32(256 * 1024)),
            ('state', cstr('running' if i == 0 else 'stopped')),
            ('timebase-frequency', u32(timebase)),
            ('clock-frequency', u32(CPU_HZ)),
            ('bus-frequency', u32(100000000)),
            ('memory-frequency', u32(933000000)),
            ('peripheral-frequency', u32(timebase)),
            ('fixed-frequency', u32(timebase)),
        ]))
    cpus = node('cpus', [ph(), ('#address-cells', u32(1)), ('#size-cells', u32(0))], cpu_nodes)

    # pexpert/arm/pe_fiq.c (SWEET_GICV2): reg = <GICD off, size, GICC off, size>
    gic = node('gic', [
        ph(),
        ('compatible', cstr('arm,gic-400')),
        ('interrupt-controller', b''),
        ('virtual-timer-intid', u32(VTIMER_INTID)),
        ('reg', u64(gicd - SOC_BASE, GICD_SIZE, gicc - SOC_BASE, GICC_SIZE)),
    ])
    arm_io = node('arm-io', [
        ph(),
        ('device_type', cstr('sweet-io')),
        ('compatible', cstr('sweet-io') + cstr('arm-io')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
        ('ranges', u64(0, SOC_BASE, 0x100000000 - SOC_BASE)),
    ], [gic,
        # No hardware: watchdogd checks IODeviceTree:/arm-io/wdt for no-pmu and
        # otherwise crashes trying to set the PMU boot stage.
        node('wdt', [ph(), ('no-pmu', u32(1))]),
        # Main display: IOMobileFramebuffer.framework counts /arm-io children
        # with this device_type and reads the canvas size from the node
        # (the presented iPhone 8 size); the kernel's AppleCLCD matches the
        # compatible string.
        node('disp0', [
            ph(),
            ('device_type', cstr('display-subsystem')),
            ('compatible', cstr('sweet,display')),
            ('canvas-width', u32(CANVAS_W)),
            ('canvas-height', u32(CANVAS_H)),
        ])])

    fbcon = node('sweet-fbcon', [
        ph(),
        ('reg', u64(FB, FB_STRIDE * FB_H)),
        ('width', u32(FB_W)),
        ('height', u32(FB_H)),
        ('stride', u32(FB_STRIDE)),
    ])

    mmc = node('sweet-mmc', [
        ph(),
        ('compatible', cstr('samsung,exynos7870-dw-mshc-smu')),
        ('reg', u64(MMC, MMC_SIZE)),
    ])

    # pmap_compute_max_asids requires the node even when no overrides are set.
    # No effaceable storage: keybagd reads /private/var/keybags/systembag.kb
    # as a plain plist instead of decrypting it with the effaceable key.
    defaults = node('defaults', [ph(), ('no-effaceable-storage', u32(1))])

    # MobileGestalt HomeButtonType etc. come from /buttons: take the real
    # iPhone 8 node; without the tree, a node with a Home button.
    buttons_props = real_node('buttons')
    if buttons_props is None:
        buttons_props = [('button-names', cstr('volup') + cstr('voldown') + cstr('hold') + cstr('menu'))]
    buttons = node('buttons', [ph()] + buttons_props)

    product_props = real_node('product')
    product = [node('product', [ph()] + product_props)] if product_props else []

    # Panic log region. /pram reg = <phys size>; it sits just above the
    # dram-size we expose, so XNU maps it but never allocates into it.
    pram = node('pram', [ph(), ('reg', u64(panic_base) + u64(PANIC_LOG_SIZE))])

    # Identity of the iPhone 8 whose userland runs here: compatible[0] is
    # hw.model/hw.target (D201AP), model is hw.machine/hw.product
    # (iPhone10,4). 'samsung,j7velte' stays for SweetPlatformExpert matching.
    return node('device-tree', [
        ph(),
        ('compatible', cstr('D201AP') + cstr('iPhone10,4') + cstr('samsung,j7velte') +
         cstr('samsung,exynos7870') + cstr('AppleARM')),
        ('model', cstr('iPhone10,4')),
        ('target-type', cstr('D201')),
        ('target-sub-type', cstr('D201AP')),
        ('manufacturer', cstr('Apple Inc.')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
    ], [chosen, defaults, cpus, arm_io, fbcon, buttons, pram] + product + ([] if qemu else [mmc]))


if __name__ == '__main__':
    root = build(qemu='--qemu' in sys.argv)
    blob = adt.serialize(root)
    open(sys.argv[1], 'wb').write(blob)
    if '--dump' in sys.argv:
        adt.dump(adt.parse(blob)[0])
    print(f'{sys.argv[1]}: {len(blob)} bytes', file=sys.stderr)
