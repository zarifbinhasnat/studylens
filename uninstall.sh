#!/usr/bin/env bash
# Removes StudyLens. Asks before deleting your tracked data. Leaves Ollama, uv and the AI model installed.
set -euo pipefail
DATA="$HOME/Library/Application Support/StudyLens"
LABEL="io.github.zarifbinhasnat.studylens.analyze"

pkill -x StudyLens 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/StudyLens.app"
tccutil reset All io.github.zarifbinhasnat.studylens >/dev/null 2>&1 || true
echo "Removed the app, its schedule and its permissions."

read -r -p "Also delete your tracked data and settings in $DATA? [y/N] " reply </dev/tty || reply=""
if [[ "$reply" =~ ^[Yy] ]]; then
  rm -rf "$DATA"
  echo "Data deleted."
else
  echo "Data kept in $DATA"
fi
echo "To also remove the AI model: ollama rm qwen3-vl:8b-instruct"
