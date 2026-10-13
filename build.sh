#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
architectures=()
case "${1:-}" in
  "") ;;
  --universal)
    [[ $# == 1 ]] || { print -u2 "Usage: zsh build.sh [--universal | --arch arm64 | --arch x86_64]"; exit 2; }
    architectures=(--arch arm64 --arch x86_64)
    ;;
  --arch)
    [[ $# == 2 && ( "$2" == arm64 || "$2" == x86_64 ) ]] || { print -u2 "Expected --arch arm64 or --arch x86_64"; exit 2; }
    architectures=(--arch "$2")
    ;;
  *) print -u2 "Usage: zsh build.sh [--universal | --arch arm64 | --arch x86_64]"; exit 2 ;;
esac
export CLANG_MODULE_CACHE_PATH="${PWD}/.build/clang-cache"
export SWIFT_MODULECACHE_PATH="${PWD}/.build/swift-cache"
swift_options=(--disable-sandbox --disable-netrc --disable-keychain --cache-path .build/cache --config-path .build/config --security-path .build/security -debug-info-format none -c release)
xcrun swift build "${swift_options[@]}" "${architectures[@]}"
binary_directory="$(xcrun swift build "${swift_options[@]}" "${architectures[@]}" --show-bin-path)"
mkdir -p dist
build_stage="$(mktemp -d "${PWD}/dist/.token-monitor-build.XXXXXX")"
trap 'rm -rf "$build_stage"' EXIT
app="$build_stage/Token Monitor.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/TokenMonitor" "$app/Contents/MacOS/TokenMonitor"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp Design/BrandAssets/README.md "$app/Contents/Resources/BrandAssets.md"
cp tools/claude_bridge.py "$app/Contents/Resources/claude_bridge.py"
cp "tools/Claude Login.command" "$app/Contents/Resources/Claude Login.command"
chmod +x "$app/Contents/Resources/Claude Login.command"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TokenMonitor</string>
<key>CFBundleIdentifier</key><string>local.tokenmonitor.widget</string>
<key>CFBundleName</key><string>Token Monitor</string>
<key>CFBundleDisplayName</key><string>Token Monitor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.10.4</string>
<key>CFBundleVersion</key><string>31</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
if [[ "${1:-}" == --universal ]]; then
  xcrun lipo "$app/Contents/MacOS/TokenMonitor" -verify_arch arm64
  xcrun lipo "$app/Contents/MacOS/TokenMonitor" -verify_arch x86_64
elif [[ "${1:-}" == --arch ]]; then
  xcrun lipo "$app/Contents/MacOS/TokenMonitor" -verify_arch "$2"
fi
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
destination="${PWD}/dist/Token Monitor.app"
rm -rf "$destination"
mv "$app" "$destination"
print "Built: $destination"
xcrun lipo -info "$destination/Contents/MacOS/TokenMonitor"
