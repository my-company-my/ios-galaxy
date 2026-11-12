# iOS 16 on the Galaxy J7 Neo (SM-J701M, Exynos 7870) - working notes

## Status (2026-11-12)

- Ported from dipa-studio/ios-sweet (Redmi Note 10 Pro, reached the iOS home
  screen). Nothing of the J7 port has run on the phone yet.
- Verified here: the XNU patch series 0001-0088 applies to xnu-8796.141.3
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
- Kernel built by CI (macos-15, Xcode 16, patches 0001-0088): run
  43114790052 produced kernel.development.sweet (17 MB); run 43118045181
  passed the Verify step, but its ARMv8.0 check was not valid:
  check-armv80.py stopped after the first load command (the section loop
  overwrote the command size) and scanned < 1 MiB ("0 MiB of code").
- With the scanner fixed (d9de668), run 43119622639 scanned 8922 KiB of
  the kernel and found 1108 LSE encodings (115 CAS, 11 CASP, 982 LDADD/
  SWP/LDCLR/...): that kernel would stop at the first atomic on the A53.
  Cause (observed with clang 18 here): for an Apple target, -march alone
  leaves -target-cpu apple-m1, and LLVM adds that CPU's features: LSE,
  RCPC, FP16, dotprod, SHA3, and __ARM_FEATURE_ATOMICS is defined. Fix in
  0082: -mcpu=cortex-a53 (target-cpu cortex-a53; CRC, AES, SHA2 stay).
  The commpage PFZ trylock used an unconditional casa, which the assembler
  rejects for cortex-a53: it now uses LDAXR/STXR when
  __ARM_FEATURE_ATOMICS is not defined. Tested here: the two real PFZ
  functions, built both ways, give the same results in 7 cases on
  unicorn (Cortex-A53 model for LL/SC, max CPU for casa); casa on the A53
  model raises an exception.
- Run 43121916137 (84fddc5, -mcpu=cortex-a53): the kernel compiles with
  the new flags (no errors); Verify scanned 8945 KiB in 4 instruction
  sections and found 13 hits, down from 1108:
  - 12 in firehose functions (_firehose_buffer_ring_enqueue,
    __firehose_buffer_tracepoint_reserve, __firehose_merge_updates...),
    at the same addresses as before: libfirehose_kernel.a, built by dxb
    with xcodebuild for the default Mac CPU, not with xnu's flags. Fix:
    tools/dxb-prepare.py adds OTHER_CFLAGS[arch=arm64] = (the xcconfig's
    flags) -mcpu=cortex-a53 to libfirehose_kernel.xcconfig (libdispatch-
    1415.140.2 has no hand-written LSE; target settings are empty, so the
    xcconfig decides). x86_64/arm64e slices unchanged.
  - 1 in K256: SHA-256 round constants kept in __text by
    osfmk/arm64/corecrypto/sha256_compress_arm64.s; K256[57] = 0x78a5636f
    matches the LSE pattern. Data, never executed: CI passes
    --ignore-symbol K256 (the hit is still printed).
- Run 43123698894 (4613792): all jobs pass. Verify: "all 88 patches
  applied"; 8945 KiB of code in 4 instruction sections, 70686 symbols
  (the same symbol count as the previous run, so the firehose functions
  are still linked); "ignored (--ignore-symbol): 1 lse-rmw in K256"; "no
  post-ARMv8.0 encodings found". The kernel to test on the phone is the
  xnu-kernel artifact of this run. Limits of this check: it matches the
  encodings listed in check-armv80.py (LSE, LDAPR/LDAPUR, FJCVTZS, dotprod,
  RDM, FP16, PAN/UAO/DIT/SSBS); it is not a full disassembly.
- check-armv80.py now reads every instruction section (S_ATTR_*_INSTRUCTIONS:
  __commpage_text, __KLD...), detects MSR/MRS of PAN, UAO, DIT, SSBS, names
  the function of each hit and has a --min-code-kib guard (CI: 4096).
  tools/test/check_armv80_test.py tests it on clang Mach-O objects (the
  original scanner fails 6 of its 11 checks).
- NOT verified: nothing has run on the phone. Nothing of the hardware
  drivers has run on hardware.

## Mac app "iOS Galaxy" (gui/, 2026-11-12)

- SwiftUI wizard over the existing scripts, 10 steps (Herramientas,
  Repositorio, TWRP, Respaldo, Prueba del shim, Kernel, iOS, Imagen raíz,
  Arranque completo, Logs). Decisions with the user: SwiftUI, Spanish,
  wizard with free navigation and saved checkmarks, the app clones the
  work branch into ~/ios-galaxy, tools checked + installed with Homebrew,
  Heimdall built from source (Grimler v2.2.2, pinned commit), typed
  confirmation with the partition name (RECOVERY / BOOT / ERASE), phone
  state polled every 2 s and buttons disabled with the keys to press,
  backups in ~/Documents/iOS Galaxy/backups/<date>, administrator steps
  through the macOS password dialog, IPSW: only the needed parts, version
  chosen from a list; one "latest" release with the kernel and the app;
  macOS 13+ (chosen by me; the user's Mac has macOS 27).
- Helpers: tools/ipsw-fetch.py (list/fetch/check), tools/heimdall-build.sh,
  sweet-usbnet.sh --wait/--listen (only ifconfig needs root).
- Verified here (Linux): ipsw-fetch.py against the real ipsw.me API and
  Apple's IPSW (32 iOS 16 builds; BuildManifest of 16.0, 16.4, 16.7.16 all
  have d201ap/Erase OS + Cryptex1,SystemOS + Cryptex1,AppOS; DeviceTree
  download -> d201ap.adt 'D201AP|iPhone10,4', mkadt.py accepts it; the
  disk check stops before any image download); heimdall-build.sh builds
  v2.2.2 (also re-run, path with spaces), `heimdall detect` exits 1 with
  no phone and only lists USB devices (source read); usbnet --listen
  receives UDP lines, --wait waits and prints the interface (fake `ip`).
  The app's Swift code cannot be compiled here (no Swift on this Linux):
  the CI app job builds it on macos-15, runs --selftest and takes a PNG of
  every step (capturas.zip in the release).
- CI run 43196699703 (f7b1d00): all jobs pass. App job on macos-15:
  gui/build-app.sh builds the universal app, --selftest passes (adb
  parsing, bash quoting round trip, line splitting, JSON of ipsw-fetch /
  parts.json / release API, Shell.capture with a child holding the pipe
  and a timeout, Runner stdin "ERASE\n", failure line, Detener),
  heimdall-build.sh builds v2.2.2 with Homebrew libusb and `detect`
  exits 1, ipsw-fetch.py lists and fetches the DeviceTree, mkadt.py uses
  it; the step captures show every page rendered (no phone: buttons
  disabled with the key hints). The release job published "latest":
  kernel.development.sweet, iOS-Galaxy.app.zip, capturas.zip, SHA256SUMS
  (checked after download here).
- CI run 43198765307 (fe068a7): all jobs pass; the snapshot run now quits
  by itself ("snapshots done", no kill); window 1100x900 by default (the
  CI screen is 1024x768, so captures are 1024x681); the release "latest"
  is from this run.
- First real use (user's Mac, macOS 27 "Golden Gate"): "Instalar lo que
  falta" ran `brew install numpy llvm lld lzfse rsync && brew install
  --cask android-platform-tools`. llvm/lld/lzfse/rsync installed; numpy
  installed but not linked (/opt/homebrew/bin/f2py and numpy-config
  already existed, likely from an old pip install for another Python),
  brew exited 1 and the && skipped the adb cask. Also brew auto-updated
  (llvm 22 -> 23) and ran its cleanup. Fixes, decided with the user:
  numpy in the app's own venv (Application Support/iOS Galaxy/venv, first
  in PATH, created from Homebrew's python3; numpy 2.5.4 has cp315 arm64
  wheels), HOMEBREW_NO_INSTALL_CLEANUP=1, auto-update kept; formulas,
  casks and the venv are separate commands and the result is the check
  afterwards. The venv bash was run here exactly as the app builds it:
  fresh, existing and broken venv, path with spaces. CI run 43203076670
  (736a610): all jobs pass; it published this version as "latest".
- Second real use: the adb cask installed; numpy failed with pip's "Can
  not perform a '--user' install. User site-packages are not visible in
  this virtualenv": the user's pip config (pip.conf user = true, or
  PIP_USER=1) forces --user. Reproduced here with both; the venv pip now
  runs with PIP_USER=0 (overrides only that setting), tested with
  [global] user = true, [install] user = yes and PIP_USER=1. Heimdall was
  still missing because the repo was not cloned yet: the final check now
  says to do step 1 first.
- Not verified: the app with a real phone (adb/Heimdall states, flashing),
  the administrator dialog path, the TWRP .tar extraction with a real
  Samsung tar.

## TWRP for the J7 Neo (2026-11-12)

- No official TWRP for j7velte (twrp.me has j7elte = J700, j7xelte = J710).
- Checked image: TWRP-3.7.1-j7velte-@Batuhantrkgl.img from GitHub
  batuhantrkgl/releases tag TWRP-3.7.1-Exynos7870-Stable, SHA-256
  696cc964d70c6fdb86952b477f9afd5a2adefa3e259eea32c5df31db8f52b69f,
  30072832 bytes. Header v0, page 2048, kernel 0x10008000, ramdisk
  0x11000000 (LZMA cpio), dt.img = Samsung DTBH v2 with 3 DTBs "samsung,
  J7VE LTE SEA OPEN 00/01/02A", chip 0x1ebe, platform 0x50a6, subtype
  0x217584da, hw_rev 0-0 / 1-2 / 3-255. prop.default: ro.product.device=
  j7velte, model "Samsung Galaxy J7 Nxt", built 2024-03-01; binary version
  string 3.7.0_9-0. recovery.fstab: 13540000.dwmmc0/by-name BOOT,
  RECOVERY, USERDATA, EFS, RADIO... adb on, ro.secure=0, toybox blockdev/
  readlink/tr, dd, sh: what tools/j7-flash.sh needs.
- Guess, not verified: S-BOOT of the J701M (LTN variant) accepts these SEA
  DTBs, because it selects by chip/hw_rev (the pmOS port tested on the
  SM-J701M gives only model_info-chip = 7870 and hw_rev 0-255).
- tools/mkbootimg_samsung.py no longer warns on DTBH (the Exynos dt.img
  format; the warning came from the Qualcomm Redmi port). Building with
  the TWRP image as stock copies its dt.img unchanged.

## No power button (2026-11-12)

- The user's power button is broken. Decided with the user: Heimdall
  writes TWRP with its automatic restart (no --no-reboot) while Vol+ and
  Home are held; the app downloads the checked TWRP image (SHA-256, size)
  and keeps "Elegir otra"; restart buttons always visible (adb reboot
  recovery / download / Android; from Download mode `heimdall print-pit`,
  which only reads the PIT and then restarts, checked in Heimdall's
  source); an escape in the shim and the kernel.
- Restart reason: PMU INFORM3 (0x10480000 + 0x80c), recovery 0x12345674,
  download 0x12345671, from mainline Linux 7.4-rc2 exynos7870.dtsi
  (syscon-reboot-mode); then PSCI SYSTEM_RESET (SMC; the shim keeps
  HCR_EL2 = RW only, so SMC goes to EL3), then PMU SWRESET (0x400 = 1) if
  the firmware returns. Not verified on the phone: that S-BOOT honours
  INFORM3 after a PSCI reset (mainline relies on it: no syscon-reboot node).
- shim/escape.c: armed only when the DT root compatible has
  "samsung,exynos7870" (checked on the 3 J7VE DTBs of the TWRP image: yes;
  QEMU virt: no). Vol+ held 300 ms = TWRP, Vol- = Download, both = nothing;
  checked at start and in every halt (also the exception screen).
  tools/qemu-j7.py --escape up|down|none builds shim/out-esc with the
  registers in RAM and checks INFORM3 and the reset request (CI).
- Patch 0089 (bsd/dev/sweet_keys.c): Vol+ and Vol- held 3 s = TWRP; boot-
  arg sweetescape=0. Syntax-checked with xnu's warnings (same diagnostics
  as before; found a missing ml_io_map declaration first); 0082-0088
  unchanged; work/xnu + 0082..0089 == edited tree.
- The J7 Neo's battery is removable (last resort).
- CI run 43211060972 (def5515): all jobs pass: kernel with 0089 built,
  Verify (89 patches, ARMv8.0 only), QEMU escape up/down/none, app
  self-test (TWRP URL/SHA-256 check) and captures; release "latest"
  updated (its kernel has the "restart into TWRP" strings). The app's
  TWRP download command was run here against GitHub: real SHA-256
  accepted, wrong one rejected with nothing left behind.

## TWRP on the SM-J701M: no USB (2026-11-12)

- Observed by the user: TWRP-3.7.1-j7velte writes fine (Heimdall "upload
  successful", no red text) and stays installed (Android does not replace
  it; "adb reboot recovery" from Android opens it). Holding Vol+ and Home
  during Heimdall's automatic restart does not enter recovery (Android
  starts). Touch never works in this TWRP on the phone (the user says that
  is expected). The Mac sees no USB device at all in TWRP, also after
  replugging (in Android it does). Home + Vol- while plugging the USB cable
  into a powered-off phone (battery reinserted) opens TWRP without the
  power button.
- Guess, not verified: the pmOS port tested on an SM-J701M needs the
  S2MU005 MUIC D+/D- switch set (0xB5 = 0x24) before USB works; this TWRP
  kernel ("3.18.140-SIMPLE-KERNEL", DTBs "J7VE LTE SEA OPEN") may leave it
  open. Its MUIC driver has usb_sel / uart_sel / usb_state / attached_dev
  sysfs files and parses switch_sel; no i2c tools in the ramdisk.
- tools/twrp-diag: the same image with one service that writes a report
  (/sdcard/iosgalaxy-twrp-diag.txt: cmdline, android_usb, MUIC files,
  props, dmesg), writes usb_sel = PDA, restarts the gadget, and restarts
  into Android after 90 s unless a computer configured USB. Only the
  ramdisk differs (header/kernel/dt identical; rebuilding with the original
  ramdisk gives the original image byte for byte; no hard links or device
  nodes in the cpio). test.sh checks the script on a fake /sys (mksh, dash).
  The CI publishes twrp-j7velte-iosgalaxy-diag.img in the release.
- Not tried yet: Home + Vol+ and Vol+ + Vol- while plugging USB (looking
  for a power-button-free way into Download mode / Android from TWRP).

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

1. User: back up the phone (tools/j7-flash.sh backup), build the boot
   image with an empty ramdisk first (shim/build.sh) and check the shim
   screen (CPU line, INITRD line).
2. Then the full boot with cpus=1 (kernel: xnu-kernel artifact of run
   43123698894), read the log with tools/sweet-log-pull.sh.
