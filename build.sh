#!/bin/bash
# Builds build/LaserFocus.app: a universal (Apple Silicon + Intel) app that runs on
# macOS 10.13 High Sierra and later. Requires Xcode (or its command line tools).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LaserFocus.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=(Sources/*.swift)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

build_arch() {
    local target="$1"
    xcrun swiftc -O -sdk "$SDK" -target "$target" -module-name LaserFocus \
        -Xlinker -rpath -Xlinker /usr/lib/swift \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        "${SOURCES[@]}" -o "build/LaserFocus-${target%%-*}"
}

echo "Compiling for Intel (macOS 10.13+)…"
build_arch x86_64-apple-macos10.13
echo "Compiling for Apple Silicon (macOS 11+)…"
build_arch arm64-apple-macos11.0

lipo -create build/LaserFocus-x86_64 build/LaserFocus-arm64 -output "$APP/Contents/MacOS/LaserFocus"
rm build/LaserFocus-x86_64 build/LaserFocus-arm64

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Indonesian word list for spelling and autocomplete; older macOS has none of its own.
cp -R Resources/Indonesian "$APP/Contents/Resources/Indonesian"

# macOS older than 10.14.4 has no built-in Swift runtime, so bundle it.
xcrun swift-stdlib-tool --copy --platform macosx \
    --scan-executable "$APP/Contents/MacOS/LaserFocus" \
    --destination "$APP/Contents/Frameworks"

codesign --force --deep --sign - "$APP"
echo "Built $APP"
