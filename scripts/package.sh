#!/usr/bin/env bash
# Builds the release download: dist/StudyLens-macOS-arm64.zip with a prebuilt app and the installer.
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE_ID="io.github.zarifbinhasnat.studylens"
OUT=dist/StudyLens
rm -rf dist && mkdir -p "$OUT/StudyLens.app/Contents/MacOS"

cp app/Info.plist "$OUT/StudyLens.app/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 app/main.swift -o "$OUT/StudyLens.app/Contents/MacOS/StudyLens"
codesign --force --sign - --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$OUT/StudyLens.app"

rsync -a --exclude .venv --exclude __pycache__ analyzer "$OUT/"
cp -R examples config.example.json install.sh uninstall.sh LICENSE README.md PRIVACY.md "$OUT/"
printf '#!/bin/bash\ncd "$(dirname "$0")" && bash install.sh\n' > "$OUT/Install StudyLens.command"
chmod +x "$OUT"/*.sh "$OUT/Install StudyLens.command"

ditto -c -k --norsrc --noextattr --keepParent "$OUT" dist/StudyLens-macOS-arm64.zip
echo "Built dist/StudyLens-macOS-arm64.zip ($(du -h dist/StudyLens-macOS-arm64.zip | cut -f1))"
