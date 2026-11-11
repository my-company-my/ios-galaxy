#!/usr/bin/env python3
"""Adapt blacktop/darwin-xnu-build's build.sh for the J7 Neo (SWEET) kernel.

  tools/dxb-prepare.py DXB_DIR

Used by .github/workflows/xnu.yml and tools/build-xnu-mac.sh. Idempotent;
exits 1 if build.sh does not have the lines it expects (pinned DXB_SHA).

libfirehose_kernel.a (os_log buffers, from libdispatch) is built by dxb with
xcodebuild for macOS and linked into the kernel:
  1. dxb builds it for x86_64 and arm64e only; the SWEET kernel is plain
     arm64, so add that slice.
  2. Xcode compiles that slice for the default Mac CPU (apple-m1), which
     emits ARMv8.1 atomics (LSE) the Cortex-A53 does not have: CI run
     43121916137 found 12 of them in firehose functions. Build the arm64
     slice with -mcpu=cortex-a53, like xnu itself (patch 0082). The x86_64
     and arm64e slices are not changed.
"""
import pathlib, sys

MARK = '# ios-galaxy (tools/dxb-prepare.py)'

ARCHS_OLD = 'ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"'
ARCHS_NEW = 'ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"'

# Inserted in build_libdispatch(), after dxb has cloned libdispatch and
# edited the xcconfig, before xcodebuild runs. OTHER_CFLAGS[arch=arm64]
# takes precedence over OTHER_CFLAGS for that slice only; it repeats the
# xcconfig's own flags (read from the file) and adds the CPU.
FIREHOSE_CPU = f'''        {MARK}: the J7 Neo kernel links the plain
        # arm64 slice; build it for the Cortex-A53 (no LSE), like xnu itself.
        _xc="${{SRCROOT}}/xcodeconfig/libfirehose_kernel.xcconfig"
        _cf=$(sed -n 's/^OTHER_CFLAGS = //p' "${{_xc}}")
        [ -n "${{_cf}}" ] || {{ error "no OTHER_CFLAGS in ${{_xc}}"; exit 1; }}
        grep -q '^OTHER_CFLAGS\\[arch=arm64\\]' "${{_xc}}" || echo "OTHER_CFLAGS[arch=arm64] = ${{_cf}} -mcpu=cortex-a53" >> "${{_xc}}"
        grep '^OTHER_CFLAGS' "${{_xc}}"
'''


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = pathlib.Path(sys.argv[1]) / 'build.sh'
    lines = path.read_text().splitlines(keepends=True)
    text = ''.join(lines)

    # 1. arm64 slice
    n_old, n_new = text.count(ARCHS_OLD), text.count(ARCHS_NEW)
    if n_new == 0:
        if n_old != 1:
            sys.exit(f'{path}: expected 1 line with {ARCHS_OLD}, found {n_old}')
        text = text.replace(ARCHS_OLD, ARCHS_NEW)
        print('build.sh: libfirehose_kernel built for x86_64 arm64e arm64')
    lines = text.splitlines(keepends=True)

    # 2. Cortex-A53 flags for that slice
    if MARK not in text:
        try:
            start = next(i for i, l in enumerate(lines) if l.startswith('build_libdispatch() {'))
            xcb = next(i for i in range(start, len(lines)) if 'xcodebuild install -target libfirehose_kernel' in lines[i])
        except StopIteration:
            sys.exit(f'{path}: build_libdispatch() or its libfirehose_kernel xcodebuild line not found')
        cds = [i for i in range(start, xcb) if lines[i].strip() == 'cd "${SRCROOT}"']
        seds = [i for i in range(start, xcb) if 'xcodeconfig/libfirehose_kernel.xcconfig' in lines[i]]
        if len(cds) != 1 or not seds or seds[-1] > cds[0]:
            sys.exit(f'{path}: unexpected build_libdispatch() layout (cd at {cds}, xcconfig edits at {seds})')
        lines.insert(cds[0], FIREHOSE_CPU)
        print('build.sh: libfirehose_kernel arm64 slice built with -mcpu=cortex-a53')
    path.write_text(''.join(lines))


if __name__ == '__main__':
    main()
