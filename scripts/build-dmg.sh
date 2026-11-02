#!/bin/bash
# Creates dist/BobWob-<version>.dmg from a fresh build. Takes the same options as build-app.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

version="${VERSION:-$(plutil -extract CFBundleShortVersionString raw packaging/Info.plist)}"
export VERSION="$version"
scripts/build-app.sh

dmg="dist/BobWob-$version.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

cp -R dist/BobWob.app "$staging/"
ln -s /Applications "$staging/Applications"

rm -f "$dmg"
hdiutil create -quiet -volname "BobWob" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
hdiutil verify -quiet "$dmg"
(cd dist && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")

echo "$dmg"
