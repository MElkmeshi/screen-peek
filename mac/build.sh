#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
archs=(--arch arm64 --arch x86_64)
swift build -c release "${archs[@]}"
bin=$(swift build -c release "${archs[@]}" --show-bin-path)
app=build/ScreenPeek.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/ScreenPeek" "$app/Contents/MacOS/ScreenPeek"
cp Info.plist "$app/Contents/Info.plist"
cp ../assets/icon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGN_IDENTITY:--}" "$app"
ditto -c -k --keepParent "$app" build/ScreenPeek-mac.zip
echo "built $PWD/$app"
