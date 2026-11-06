#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}/.."
if [[ "$(uname -s)" != Darwin ]]; then
  print -u2 'This native app must be built on macOS.'
  exit 1
fi
native_arch="$(uname -m)"
case "$native_arch" in
  arm64|x86_64) ;;
  *) print -u2 "Unsupported build architecture: $native_arch"; exit 1 ;;
esac
app_bundle="$PWD/build/AI Usage Dashboard.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$PWD/build/module-cache"
# Start resources clean so an earlier private cache can never enter a new build.
find "$app_bundle/Contents/Resources" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>AI Usage Dashboard</string>
<key>CFBundleDisplayName</key><string>AI Usage Dashboard</string>
<key>CFBundleIdentifier</key><string>io.github.aiusagedashboard</string>
<key>CFBundleExecutable</key><string>AIUsageDashboard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -O -framework AppKit -framework WebKit -framework Security \
  -target "$native_arch-apple-macos14.0" -module-cache-path "$PWD/build/module-cache" \
  src/native/BackendController.swift src/native/SharingController.swift \
  src/native/RelayModels.swift src/native/RelayAPIClient.swift src/native/RelaySettings.swift \
  src/native/RelayView.swift src/native/RelayConnection.swift src/native/Widget.swift \
  -o "$app_bundle/Contents/MacOS/AIUsageDashboard"
# Code and static assets only. Runtime caches, credentials and bootstrap data are excluded.
for resource in src/service/**/*(.N); do
  case "$resource" in
    */__pycache__/*) continue ;;
    *.py|*.html|*.css|*.js|*.svg) ;;
    *) continue ;;
  esac
  resource_relative="${resource#src/service/}"
  mkdir -p "$app_bundle/Contents/Resources/${resource_relative:h}"
  cp "$resource" "$app_bundle/Contents/Resources/$resource_relative"
done
cp src/native/RelayReader.js "$app_bundle/Contents/Resources/RelayReader.js"
cp examples/demo.json "$app_bundle/Contents/Resources/demo.json"
cp LICENSE NOTICE "$app_bundle/Contents/Resources/"
codesign --force --deep --sign - "$app_bundle"
print "$app_bundle"
