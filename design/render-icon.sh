#!/bin/zsh
# Renders design/AppIcon.svg into the app's asset catalog. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "${0:A:h}/.."
out=AppAlibi/Assets.xcassets/AppIcon.appiconset
mkdir -p $out
for size in 16 32 64 128 256 512 1024; do
  rsvg-convert -w $size -h $size design/AppIcon.svg -o $out/icon-$size.png
done
