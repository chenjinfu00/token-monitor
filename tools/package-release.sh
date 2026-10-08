#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Build only source-owned files; the release never copies local account state.
zsh build.sh --universal
app="${PWD}/dist/Token Monitor.app"
plist="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
[[ "$version" =~ '^[0-9]+([.][0-9]+){2}$' ]] || { print -u2 "Invalid release version"; exit 1; }
basename="Token-Monitor-${version}-macos-universal"
release_directory="${PWD}/dist/release"
release_stage="$(mktemp -d "${PWD}/dist/.token-monitor-release.XXXXXX")"
image_stage=""
trap 'rm -rf "$release_stage"; [[ -z "$image_stage" ]] || rm -rf "$image_stage"' EXIT

xcrun lipo "$app/Contents/MacOS/TokenMonitor" -verify_arch arm64
xcrun lipo "$app/Contents/MacOS/TokenMonitor" -verify_arch x86_64
xcrun vtool -show-build "$app/Contents/MacOS/TokenMonitor" | awk '
  /minos/ { count++; split($2, version, "."); if (version[1] > 13 || (version[1] == 13 && version[2] > 0)) exit 1 }
  END { if (count != 2) exit 1 }
' || { print -u2 "Both architectures must support macOS 13.0"; exit 1; }
codesign --verify --deep --strict "$app"
plutil -lint "$plist"

# Fail closed if a previous or modified bundle contains unexpected files.
for bundle_file in "$app"/**/*(D.N); do
  case "${bundle_file#$app/}" in
    Contents/Info.plist|Contents/MacOS/TokenMonitor|Contents/Resources/claude_bridge.py|Contents/Resources/Claude\ Login.command|Contents/_CodeSignature/CodeResources) ;;
    *) print -u2 "Unexpected file in release bundle: ${bundle_file#$app/}"; exit 1 ;;
  esac
done

zip="$release_stage/$basename.zip"
dmg="$release_stage/$basename.dmg"
ditto -c -k --keepParent --norsrc --noextattr --noacl "$app" "$zip"

image_stage="$(mktemp -d "${PWD}/dist/.token-monitor-image.XXXXXX")"
ditto --norsrc --noextattr --noacl "$app" "$image_stage/Token Monitor.app"
ln -s /Applications "$image_stage/Applications"
if hdiutil create -srcfolder "$image_stage" -volname "Token Monitor ${version}" -fs HFS+ -format UDZO "$dmg"; then
  hdiutil verify "$dmg"
else
  rm -f "$dmg"
  print -u2 "DMG creation is unavailable on this host; the universal ZIP is ready."
fi

artifacts=("$basename.zip")
[[ ! -f "$dmg" ]] || artifacts+=("$basename.dmg")
(cd "$release_stage" && shasum -a 256 "${artifacts[@]}" > SHA256SUMS.txt)
# Replace the generated output as a set, so a new version cannot upload old assets.
chmod 755 "$release_stage"
rm -rf "$release_directory"
mv "$release_stage" "$release_directory"
print "Release files: $release_directory"
print -l "${artifacts[@]}" SHA256SUMS.txt
