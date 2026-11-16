#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HOME/Library/Caches/SoundTraceBuild"
CONTENTS="$BUILD/音源排查.app/Contents"
# iCloud restores FinderInfo after signing, so the runnable bundle stays outside iCloud.
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$ROOT/build.nosync"
xcrun swiftc -swift-version 5 -O \
    -target "$(uname -m)-apple-macos14.2" \
    -sdk "$(xcrun --show-sdk-path)" \
    "$ROOT"/Sources/*.swift \
    -framework SwiftUI -framework AppKit -framework CoreAudio -lproc \
    -o "$CONTENTS/MacOS/SoundTrace"
cp "$ROOT/AppInfo.plist" "$CONTENTS/Info.plist"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$ROOT/Assets/AppIcon.png" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    /usr/bin/sips -z "$double" "$double" "$ROOT/Assets/AppIcon.png" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$BUILD/音源排查.app"
/usr/bin/codesign --verify --strict "$BUILD/音源排查.app"
/usr/bin/ditto --noextattr --norsrc -c -k --keepParent \
    "$BUILD/音源排查.app" "$ROOT/build.nosync/音源排查.zip"
printf '\n应用：%s/音源排查.app\n安装包：%s/build.nosync/音源排查.zip\n' "$BUILD" "$ROOT"
