#!/bin/bash
# Build Heimdall (Samsung Download-mode flasher; Henrik Grimler's maintained
# fork, command line only, no Qt) into PREFIX/bin/heimdall.
#
#   tools/heimdall-build.sh [PREFIX]   (default ~/Library/Application Support/iOS Galaxy)
#
# Used by the Mac app (gui/) to install TWRP. Homebrew has no working
# Heimdall (the old heimdall-suite cask is disabled). On macOS it installs
# cmake, pkg-config and libusb with Homebrew; on Linux they must be there.
set -euo pipefail
prefix=${1:-"$HOME/Library/Application Support/iOS Galaxy"}
url=https://git.sr.ht/~grimler/Heimdall
tag=v2.2.2
commit=d9554e7fa30a00abed7f0ac86b10e63c2c3b8e20	# v2.2.2^{}

if [ "$(uname)" = Darwin ]; then
	brew install cmake pkg-config libusb
	jobs=$(sysctl -n hw.ncpu)
else
	jobs=$(nproc)
fi
src="$prefix/heimdall-src"
build="$prefix/heimdall-build"
mkdir -p "$prefix/bin"
if [ ! -d "$src/.git" ]; then
	rm -rf "$src"
	git clone -q --depth 1 --branch "$tag" "$url" "$src"
fi
git -C "$src" fetch -q --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
git -C "$src" checkout -q "$tag"
[ "$(git -C "$src" rev-parse HEAD)" = "$commit" ] || { echo "error: $tag is not $commit" >&2; exit 1; }
cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release -DDISABLE_FRONTEND=ON
cmake --build "$build" -j "$jobs"
cp "$build/bin/heimdall" "$prefix/bin/heimdall"
echo "installed: $prefix/bin/heimdall ($("$prefix/bin/heimdall" version))"
