#!/usr/bin/env bash
# One-line installer:  curl -fsSL https://raw.githubusercontent.com/zarifbinhasnat/studylens/main/get.sh | bash
# Downloads the latest release and runs its install.sh. Files fetched this way are not quarantined by macOS,
# so the unsigned app opens without a Gatekeeper warning.
set -euo pipefail
URL="https://github.com/zarifbinhasnat/studylens/releases/latest/download/StudyLens-macOS-arm64.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading StudyLens…"
curl -fsSL "$URL" -o "$TMP/StudyLens.zip"
ditto -x -k "$TMP/StudyLens.zip" "$TMP"
bash "$TMP/StudyLens/install.sh"
