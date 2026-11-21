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
identity=${SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  identity=$(security find-identity -p codesigning 2>/dev/null | awk '/"ScreenPeek Local"/ {print $2; exit}')
fi
codesign --force --sign "${identity:--}" "$app"
stage=build/dmg
rm -rf "$stage" build/ScreenPeek.dmg
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname ScreenPeek -srcfolder "$stage" -fs HFS+ -format UDZO -ov build/ScreenPeek.dmg >/dev/null
rm -rf "$stage"
echo "built $PWD/$app"
