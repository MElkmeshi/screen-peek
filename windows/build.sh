#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
dotnet=${DOTNET:-$(command -v dotnet || echo $HOME/.dotnet/dotnet)}
for rid in win-x64 win-arm64; do
  "$dotnet" publish ScreenPeek.csproj -c Release -r "$rid" --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:EnableCompressionInSingleFile=true -o "build/$rid"
  cp "build/$rid/ScreenPeek.exe" "build/ScreenPeek-$rid.exe"
done
ls -lh build/ScreenPeek-*.exe
