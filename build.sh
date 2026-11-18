#!/bin/bash
set -euo pipefail

source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
app_path="${1:-$source_dir/GPU Watch.app}"
staging="$(mktemp -d "${TMPDIR:-/tmp}/gpu-watch.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
bundle="$staging/GPU Watch.app"

mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
/usr/bin/install -m 755 "$source_dir/check_gpu_util" "$bundle/Contents/Resources/check_gpu_util"
/usr/bin/install -m 644 "$source_dir/LICENSE" "$bundle/Contents/Resources/LICENSE"

read -r -a architectures <<< "${GPU_WATCH_ARCHS:-$(uname -m)}"
binaries=()
for architecture in "${architectures[@]}"; do
    binary="$staging/GPUWatch-$architecture"
    swiftc -O -parse-as-library -target "$architecture-apple-macosx13.0" \
        -module-cache-path "${GPU_WATCH_MODULE_CACHE:-$staging/module-cache}" \
        "$source_dir/GPUCheck.swift" "$source_dir/GPUWatch.swift" \
        -o "$binary"
    binaries+=("$binary")
done
xcrun lipo -create "${binaries[@]}" -output "$bundle/Contents/MacOS/GPUWatch"

cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>GPUWatch</string>
    <key>CFBundleIdentifier</key>
    <string>local.gpu-watch</string>
    <key>CFBundleName</key>
    <string>GPU Watch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.4.0</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/ditto "$bundle" "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
printf 'Built %s\n' "$app_path"
