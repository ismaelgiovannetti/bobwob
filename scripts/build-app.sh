#!/bin/bash
# Assembles dist/BobWob.app. UNIVERSAL=1 builds for Apple Silicon and Intel, which requires Xcode.
set -euo pipefail

cd "$(dirname "$0")/.."

arch_flags=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    arch_flags=(--arch arm64 --arch x86_64)
fi

swift build -c release --product BobWobApp "${arch_flags[@]+"${arch_flags[@]}"}"
bin_path="$(swift build -c release --product BobWobApp --show-bin-path "${arch_flags[@]+"${arch_flags[@]}"}")"

app="dist/BobWob.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/BobWobApp" "$app/Contents/MacOS/BobWob"
cp packaging/Info.plist "$app/Contents/Info.plist"

codesign --force --sign - "$app"
codesign --verify "$app"

echo "$app"
