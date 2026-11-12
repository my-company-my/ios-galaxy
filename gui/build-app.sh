#!/bin/bash
# Build "iOS Galaxy.app" from gui/Sources with swiftc (no Xcode project).
#
#   gui/build-app.sh [OUTDIR]          (default gui/out)
#
# Needs Xcode or the Command Line Tools (swiftc + macOS SDK). Universal
# (Apple Silicon + Intel), macOS 13 or newer, signed ad hoc. Also writes
# OUTDIR/iOS-Galaxy.app.zip (what the CI publishes in the "latest" release).
set -euo pipefail
[[ $(uname) == Darwin ]] || { echo "macOS only" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
out=$(mkdir -p "${1:-$here/out}" && cd "${1:-$here/out}" && pwd)
app="$out/iOS Galaxy.app"
exe="iOS Galaxy"
version=${IOSGALAXY_VERSION:-1.0}
build=${IOSGALAXY_BUILD:-$(git -C "$here" rev-list --count HEAD 2>/dev/null || echo 1)}
sdk=$(xcrun --sdk macosx --show-sdk-path)

rm -rf "$app" "$out/iOS-Galaxy.app.zip"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
	xcrun swiftc -O -swift-version 5 -parse-as-library -sdk "$sdk" -target "$arch-apple-macos13.0" \
		-o "$out/$exe-$arch" "$here"/Sources/*.swift
done
lipo -create -output "$app/Contents/MacOS/$exe" "$out/$exe-arm64" "$out/$exe-x86_64"
rm -f "$out/$exe-arm64" "$out/$exe-x86_64"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>es</string>
	<key>CFBundleExecutable</key><string>$exe</string>
	<key>CFBundleIdentifier</key><string>org.iosgalaxy.app</string>
	<key>CFBundleName</key><string>iOS Galaxy</string>
	<key>CFBundleDisplayName</key><string>iOS Galaxy</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$build</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --verbose "$app"
lipo -info "$app/Contents/MacOS/$exe"
(cd "$out" && ditto -c -k --keepParent "iOS Galaxy.app" iOS-Galaxy.app.zip)
echo "$app"
echo "$out/iOS-Galaxy.app.zip"
