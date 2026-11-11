# iOS 16 on the Galaxy J7 Neo (SM-J701M, Exynos 7870) - working notes

## Status (2026-11-11)

- Ported from dipa-studio/ios-sweet (Redmi Note 10 Pro, reached the iOS home
  screen). Nothing of the J7 port has run on the phone yet.
- Verified here: the XNU patch series 0001-0087 applies to xnu-8796.141.3
  (local apply of the series, the patched tree equals the edited one); the
  shim builds with clang + ld.lld and, in QEMU (virt, GIC-400, Cortex-A53),
  finds the payload in the ramdisk or appended, moves the boot core to
  cpu0 in the ADT, drops from EL2 to EL1 and enters the kernel with correct
  boot_args (tools/qemu-j7.py); the ARMv8.1 atomics emulation passes its
  host unit test (tools/test/lse_test.py); tools/check-armv80.py matches
  LLVM's disassembly.
- Partly verified: every changed kernel file was syntax-checked here with
  clang -fsyntax-only and xnu's warning flags (-Weverything minus xnu's
  exclusions) against the patched source tree, and its diagnostics were
  compared with the original tree: no new ones, except the same
  -Wcast-align/-Wshadow the original UFS driver already had. This found
  and fixed the 4K commpage/VA limit (MACH_VM_MAX_ADDRESS must be the iOS
  0xFC0000000) and missing prototypes. The new LL/SC assembly assembles
  for ARMv8.0. Generated headers were stubbed, so this is not a full build.
- NOT verified: the kernel has not been compiled yet. The macOS CI job was
  cancelled before a runner started (runs 43110727956, 43111625356) because
  GitHub retired the macos-14 image on 2026-11-02. The repo is public now;
  the workflow uses macos-15 with Xcode 16, and patch 0088 backports
  IORPC.kernelContent (xnu-11215), which Xcode 16's iig generates. Nothing
  of the hardware drivers has run on hardware.

## Decisions taken with the user

- Identity iPhone 8 (iPhone10,4 / D201AP), 750x1334 @2x scaled to 720x1280
  (instead of the iPhone X identity of the original).
- J7 Neo only (no Redmi support in the build).
- Kernel built by GitHub Actions in this repo (fallback: own Mac).
- USB Ethernet included. Battery read from the S2MU005 fuel gauge.
- Touch keys: Recents = double Home (app switcher), Back = nothing.

## Hardware facts used (sources)

| What | Value | Source |
| --- | --- | --- |
| CPU | 8 x Cortex-A53, MPIDR 0x0-0x3, 0x100-0x103, PSCI CPU_ON 0xc4000003 via SMC | Linux exynos7870.dtsi |
| ISA | ARMv8.0 + CRC + crypto; no LSE, PAN, FP16 | A53 TRM |
| Page size | 4K and 64K only (TGran16 = 0) | A53 TRM (DDI 0500, r0p4), Linux list (Rutland) |
| GIC | GIC-400: GICD 0x104e1000, GICC 0x104e2000; vtimer PPI 11 = INTID 27 | exynos7870.dtsi |
| Timer | 26 MHz; S-BOOT leaves CNTFRQ_EL0 = 0 | exynos7870.dtsi comment |
| RAM | 0x40000000+0x3e400000, 0x80000000+0x40000000 (kernel uses the upper GiB) | j7velte DTS |
| Framebuffer | 0x67000000, 720x1280 a8r8g8b8, stride 2880 | pmOS j7velte DTS (simplefb works there) |
| eMMC | DW-MSHC "smu" 0x13540000, IDMAC; DMA < 512 B broken on 7870 (we only do multiples of 512) | Linux dw_mmc-exynos, LKML 2026-04 |
| Touch | Melfas MIP4, I2C1 (0x13840000) addr 0x48, IRQ gpc3-2 | pmOS j7velte DTS |
| Touch keys | Coreriver TC350K, I2C2 addr 0x20, IRQ gpa1-4, 2.8 V switch gpd1-6 | pmOS j7velte DTS (untested there too) |
| Keys | power gpa0-0, home gpa1-7, vol+ gpa2-0, vol- gpa2-1, active low | j7velte DTS |
| Battery | S2MU005 FG I2C0 addr 0x3b; charger status I2C4 addr 0x3d reg 0x08 | Samsung kernel s2mu005_* |
| USB | DWC3 0x13600000, PHY 0x135c0000, PMU 0x10480704 bit 1, LDO8 3.3 V (S2MPU05 reg 0x32), MUIC 0x3d reg 0xB5 = 0x24 | Linux phy-exynos5-usbdrd, pmOS usb-muic.start |
| Boot | S-BOOT: Android boot image v0 + dt.img, ignores load addresses; OEM unlock needed | U-Boot exynos7870 docs |

## Risks, in the order they would show up

1. iOS 16 userland built for the A11 may use instructions the A53 lacks.
   LSE atomics and LDAPR are emulated (slow if frequent); FP16, dot
   product, RDM, FJCVTZS are not. Run tools/check-armv80.py on the shared
   cache before flashing.
2. 4K pages: iOS 16 has only run on 16K-page kernels. iOS 12 ran on 4K
   (A7/A8), and the shared-cache slide info is 4K-based, but userland
   code assuming 16K would break.
3. 1 GiB of RAM for iOS 16 (an iPhone 8 has 2 GiB): jetsam will kill a lot.
4. eMMC take-over: assumes S-BOOT leaves the card selected (RCA 1-16) in
   the transfer state with the controller clocked.
5. The GIC-400, SMP, I2C, GPIO, PMIC and USB code is written from the
   Linux drivers and has never run.

## Next action

1. Get a kernel built (CI with macOS runners, or tools/build-xnu-mac.sh),
   fix compile errors.
2. User: back up the phone (tools/j7-flash.sh backup), build the boot
   image with an empty ramdisk first (shim/build.sh) and check the shim
   screen (CPU line, INITRD line).
3. Then the full boot with cpus=1, read the log with tools/sweet-log-pull.sh.
