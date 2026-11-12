#!/usr/bin/env python3
"""iPhone 8 (iPhone10,4, D201AP) iOS 16 files for the J7 Neo, without the whole IPSW.

  ipsw-fetch.py list [--json]
      iOS 16 builds for iPhone10,4 from api.ipsw.me, newest first.
  ipsw-fetch.py fetch BUILD [--out DIR] [--devicetree-only]
      Download from Apple's IPSW (HTTP range requests, tools/remotezip.py)
      only BuildManifest.plist, the OS, Cryptex1,SystemOS and Cryptex1,AppOS
      disk images (about 7.4 GB) and the D201AP DeviceTree. DIR defaults to
      research/ipsw-8/BUILD. Writes DIR/parts.json (absolute paths, for
      tools/mkiosroot.sh) and research/ipsw-8/d201ap.adt (tools/mkadt.py).
      Interrupted downloads resume; every file is CRC-32 checked.
  ipsw-fetch.py check BUILD|DIR
      macOS: mount the SystemOS cryptex read-only and run tools/check-armv80.py
      on its dyld shared cache (ARMv8.1+ instructions the Cortex-A53 lacks).

The images are chosen from the BuildManifest identity with DeviceClass
d201ap and RestoreBehavior Erase, as in README step 2.
"""
import argparse, glob, json, os, plistlib, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import adt  # noqa: E402
import remotezip  # noqa: E402

DEVICE = 'iPhone10,4'
BOARD = 'd201ap'
API = f'https://api.ipsw.me/v4/device/{DEVICE}?type=ipsw'
IPSW_DIR = os.path.join(REPO, 'research', 'ipsw-8')
ADT_OUT = os.path.join(IPSW_DIR, 'd201ap.adt')
IMAGES = {'os': 'OS', 'systemos': 'Cryptex1,SystemOS', 'appos': 'Cryptex1,AppOS'}


def firmwares():
    d = json.loads(remotezip.curl(API))
    fws = [f for f in d['firmwares'] if f['version'].split('.')[0] == '16']
    fws.sort(key=lambda f: [int(x) for x in f['version'].split('.')], reverse=True)
    return [{k: f[k] for k in ('version', 'buildid', 'signed', 'filesize', 'url', 'releasedate')} for f in fws]


def find_build(build):
    for f in firmwares():
        if f['buildid'] == build:
            return f
    sys.exit(f'build {build} is not an iOS 16 build for {DEVICE} (see: ipsw-fetch.py list)')


def identity(manifest):
    for b in manifest['BuildIdentities']:
        info = b['Info']
        if info.get('DeviceClass', '').lower() == BOARD and info.get('RestoreBehavior') == 'Erase':
            return b['Manifest']
    sys.exit(f'no {BOARD} Erase identity in BuildManifest.plist')


def path_of(manifest, key):
    try:
        return manifest[key]['Info']['Path']
    except KeyError:
        sys.exit(f'BuildManifest.plist: no {key}')


def cmd_list(args):
    fws = firmwares()
    if args.json:
        print(json.dumps(fws, indent=1))
        return
    for f in fws:
        print(f"{f['version']:9} {f['buildid']:8} {'signed' if f['signed'] else '      '} "
              f"{f['filesize'] / 1e9:5.2f} GB  {f['releasedate'] or ''}")


def cmd_fetch(args):
    fw = find_build(args.build)
    out = os.path.abspath(args.out or os.path.join(IPSW_DIR, fw['buildid']))
    os.makedirs(out, exist_ok=True)
    url = fw['url']
    print(f"iOS {fw['version']} ({fw['buildid']}) {url}", flush=True)
    entries = {e[0]: e for e in remotezip.central_dir(url)}
    remotezip.extract(url, entries['BuildManifest.plist'], out)
    with open(os.path.join(out, 'BuildManifest.plist'), 'rb') as f:
        man = identity(plistlib.load(f))
    names = {'devicetree': path_of(man, 'DeviceTree')}
    if not args.devicetree_only:
        names.update({k: path_of(man, v) for k, v in IMAGES.items()})
    missing = [n for n in names.values() if n not in entries]
    if missing:
        sys.exit(f'not in the IPSW: {missing}')
    need = sum(entries[n][3] for n in names.values()
               if not (os.path.exists(os.path.join(out, n)) and os.path.getsize(os.path.join(out, n)) == entries[n][3]))
    free = shutil.disk_usage(out).free
    if need + (1 << 30) > free:
        sys.exit(f'not enough disk space in {out}: need {need / 1e9:.1f} GB + 1 GB margin, free {free / 1e9:.1f} GB')
    for key, name in names.items():
        print(f'{key}: {name} ({entries[name][3] / 1e6:.1f} MB)', flush=True)
        remotezip.extract(url, entries[name], out)
    dt = os.path.join(out, names['devicetree'])
    data = adt.load(dt)
    adt.parse(data)  # fails loudly if it is not a device tree
    os.makedirs(os.path.dirname(ADT_OUT), exist_ok=True)
    with open(ADT_OUT, 'wb') as f:
        f.write(data)
    print(f'{ADT_OUT}: {len(data)} bytes (DeviceTree of {BOARD})')
    parts = {'version': fw['version'], 'build': fw['buildid'], 'url': url, 'board': BOARD,
             'devicetree': dt, 'adt': ADT_OUT}
    parts.update({k: os.path.join(out, n) for k, n in names.items() if k in IMAGES})
    with open(os.path.join(out, 'parts.json'), 'w') as f:
        json.dump(parts, f, indent=1)
    print(f"{os.path.join(out, 'parts.json')} written")


def cmd_check(args):
    d = args.target if os.path.isdir(args.target) else os.path.join(IPSW_DIR, args.target)
    try:
        with open(os.path.join(d, 'parts.json')) as f:
            parts = json.load(f)
        sysos = parts['systemos']
    except (OSError, KeyError):
        sys.exit(f'{d}: no parts.json with the SystemOS image (run: ipsw-fetch.py fetch BUILD)')
    if sys.platform != 'darwin':
        sys.exit('check needs macOS (hdiutil mounts the APFS cryptex image)')
    mnt = tempfile.mkdtemp(prefix='sysos.')
    subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mnt, sysos],
                   check=True, stdout=subprocess.DEVNULL)
    try:
        caches = sorted(f for f in glob.glob(os.path.join(mnt, 'System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64*'))
                        if not f.endswith(('.map', '.atlas')))
        if not caches:
            sys.exit(f'no dyld_shared_cache_arm64* in {sysos}')
        r = subprocess.run([sys.executable, os.path.join(HERE, 'check-armv80.py'), *caches])
    finally:
        subprocess.run(['hdiutil', 'detach', mnt], stdout=subprocess.DEVNULL)
        os.rmdir(mnt)
    sys.exit(r.returncode)


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('list'); s.add_argument('--json', action='store_true'); s.set_defaults(fn=cmd_list)
    s = sub.add_parser('fetch'); s.add_argument('build'); s.add_argument('--out')
    s.add_argument('--devicetree-only', action='store_true'); s.set_defaults(fn=cmd_fetch)
    s = sub.add_parser('check'); s.add_argument('target'); s.set_defaults(fn=cmd_check)
    args = p.parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
