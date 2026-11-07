#!/usr/bin/env bash
# Installs StudyLens for the current user.
#   From a release download: uses the prebuilt StudyLens.app next to this script.
#   From a source checkout:  builds the app with swiftc (needs Xcode Command Line Tools).
# Safe to re-run to update; it never overwrites your config.json or your data.
set -euo pipefail
cd "$(dirname "$0")"

DATA="$HOME/Library/Application Support/StudyLens"
APP="$HOME/Applications/StudyLens.app"
LABEL="io.github.zarifbinhasnat.studylens.analyze"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
BUNDLE_ID="io.github.zarifbinhasnat.studylens"

ask() {  # ask "Question?" -> 0 for yes (default), works when piped from curl
  local reply
  read -r -p "$1 [Y/n] " reply </dev/tty || reply=""
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

step "Checking your Mac…"
[[ "$(uname -m)" == "arm64" ]] || { echo "StudyLens needs a Mac with Apple silicon (M1 or newer)."; exit 1; }
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
(( macos_major >= 14 )) || { echo "StudyLens needs macOS 14 Sonoma or newer."; exit 1; }
mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
(( mem_gb >= 16 )) || echo "Note: you have ${mem_gb} GB of memory. The default AI model wants 16 GB; see the README for a smaller one."

BREW="$(command -v brew || true)"
UV="$(command -v uv || true)"
OLLAMA="$(command -v ollama || true)"
if [[ -z "$UV" || -z "$OLLAMA" ]]; then
  if [[ -z "$BREW" ]]; then
    echo "StudyLens needs uv and Ollama. Install Homebrew from https://brew.sh and run this again,"
    echo "or install uv (https://docs.astral.sh/uv/) and Ollama (https://ollama.com/download) yourself."
    exit 1
  fi
  missing=(); [[ -z "$UV" ]] && missing+=(uv); [[ -z "$OLLAMA" ]] && missing+=(ollama)
  ask "Install ${missing[*]} with Homebrew?" || exit 1
  "$BREW" install "${missing[@]}"
  UV="$(command -v uv)"; OLLAMA="$(command -v ollama)"
fi

step "Starting Ollama…"
if ! curl -s localhost:11434/api/version >/dev/null; then
  if [[ -n "$BREW" ]] && "$BREW" list ollama >/dev/null 2>&1; then
    "$BREW" services start ollama >/dev/null
  else
    open -ga Ollama || true
  fi
  for _ in $(seq 1 30); do curl -s localhost:11434/api/version >/dev/null && break; sleep 1; done
fi
curl -s localhost:11434/api/version >/dev/null || { echo "Ollama did not start. Open the Ollama app and run this again."; exit 1; }

step "Settings…"
mkdir -p "$DATA/shots" "$HOME/Applications" "$HOME/Library/LaunchAgents"
if [[ -f "$DATA/config.json" ]]; then
  echo "Keeping your existing config.json."
else
  cp config.example.json "$DATA/config.json"
fi
MODEL="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["model"])' "$DATA/config.json")"
if ! "$OLLAMA" list | awk '{print $1}' | grep -qx "$MODEL"; then
  if ask "Download the AI model $MODEL now (about 6 GB, one time)?"; then
    "$OLLAMA" pull "$MODEL"
  else
    echo "Skipped. StudyLens records time now and labels it once you run: ollama pull $MODEL"
  fi
fi

step "Analyzer…"
rsync -a --delete --exclude .venv analyzer/ "$DATA/analyzer/"
"$UV" sync --project "$DATA/analyzer" --frozen --quiet
mkdir -p "$DATA/bin"
cat > "$DATA/bin/studylens" <<SH
#!/bin/sh
exec "$UV" run --project "$DATA/analyzer" --frozen --quiet studylens "\$@"
SH
chmod +x "$DATA/bin/studylens"

step "App…"
pkill -x StudyLens 2>/dev/null || true
rm -rf "$APP"
if [[ -d StudyLens.app ]]; then
  ditto StudyLens.app "$APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
else
  command -v swiftc >/dev/null || { echo "Building from source needs the Command Line Tools: xcode-select --install"; exit 1; }
  mkdir -p "$APP/Contents/MacOS"
  cp app/Info.plist "$APP/Contents/Info.plist"
  swiftc -O -swift-version 5 -target arm64-apple-macos14.0 app/main.swift -o "$APP/Contents/MacOS/StudyLens"
  # macOS ties privacy permissions to the signing requirement; pinning it to the bundle id keeps them across updates.
  codesign --force --sign - --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
fi

step "Schedule…"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$DATA/bin/studylens</string><string>analyze</string></array>
	<key>StartInterval</key><integer>600</integer>
	<key>RunAtLoad</key><true/>
	<key>LowPriorityIO</key><true/>
	<key>ProcessType</key><string>Background</string>
	<key>StandardOutPath</key><string>$DATA/analyzer.log</string>
	<key>StandardErrorPath</key><string>$DATA/analyzer.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before the old job is fully gone, so give bootstrap a moment and one retry.
sleep 1
launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || { sleep 3; launchctl bootstrap "gui/$(id -u)" "$AGENT"; }

open "$APP"
step "StudyLens is running (book icon in the menu bar)."
cat <<TXT
When macOS asks, allow:
  • Screen Recording  – to see what you are studying (screenshots are deleted after labeling)
  • Accessibility     – only to recognise Safari private windows
  • Chrome / Safari   – only to check for incognito / private windows

Your command line helper: "$DATA/bin/studylens"
TXT
if ask "Describe what you study now, so the AI knows your subjects?"; then
  "$DATA/bin/studylens" setup </dev/tty || echo "You can run it any time: \"$DATA/bin/studylens\" setup"
fi
