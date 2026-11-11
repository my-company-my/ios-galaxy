#!/bin/bash
# Build the J7 Neo xnu on your own Mac, the same way .github/workflows/xnu.yml
# does on GitHub's macOS runners (use this if those are not available).
#
#   tools/build-xnu-mac.sh [WORKDIR]          (default ~/xnu-j7-build)
#
# Needs Xcode 15.x or 16.x (patch 0088 makes xnu-8796 accept Xcode 16's
# iig output; the CI uses Xcode 16 on macos-15), Homebrew, and a few GB of
# disk. With several Xcodes installed it takes the oldest 15.x/16.x. The kernel ends in
# xnu/out/kernel.development.sweet.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=${1:-$HOME/xnu-j7-build}
DXB_REPO=https://github.com/blacktop/darwin-xnu-build
DXB_SHA=663906528d1cd5ea8fde7de6f16de73db9511549

[[ $(uname) == Darwin ]] || { echo "macOS only" >&2; exit 1; }
xc=$(ls -d /Applications/Xcode_1[56]*.app /Applications/Xcode-1[56]*.app 2>/dev/null | sort -V | head -1 || true)
if [ -n "$xc" ]; then
	export DEVELOPER_DIR="$xc/Contents/Developer"
fi
ver=$(xcodebuild -version | awk 'NR==1{print $2}')
case $ver in
15.* | 16.*) echo "Xcode $ver" ;;
*) echo "error: Xcode $ver; use Xcode 15.x or 16.x (developer.apple.com/download/all, install as /Applications/Xcode_16.4.app)" >&2; exit 1 ;;
esac

brew install jq gum bash cmake ninja
command -v xcodes >/dev/null || {
	# build.sh only checks that xcodes exists
	mkdir -p "$work/bin"; printf '#!/bin/sh\nexit 0\n' > "$work/bin/xcodes"; chmod +x "$work/bin/xcodes"
	export PATH="$work/bin:$PATH"
}

mkdir -p "$work"
if [ ! -d "$work/dxb" ]; then
	git init -q "$work/dxb"
	git -C "$work/dxb" fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA"
	git -C "$work/dxb" checkout -q FETCH_HEAD
	sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' "$work/dxb/build.sh"
fi
cp "$repo"/xnu/patches/*.patch "$repo"/xnu/patches/*.sh "$work/dxb/patches/"
cd "$work/dxb"
MACOS_VERSION=13.5 KERNEL_CONFIG=DEVELOPMENT MACHINE_CONFIG=SWEET MAKEFLAGS=-k \
	"$(brew --prefix)/bin/bash" build.sh
mkdir -p "$repo/xnu/out"
cp fakeroot/System/Library/Kernels/kernel.development.sweet "$repo/xnu/out/"
ls -l "$repo/xnu/out/kernel.development.sweet"
