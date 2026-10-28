#!/bin/bash
# Launches Dockyard in demo mode on each screen and captures its window.
# Usage: screenshots.sh <path to Dockyard.app> <output dir>
# The app writes the CGWindowID of the window to shoot to a file (-DockyardWindowIDFile); window-id.swift is the fallback.
set -u
app="$1"; out="$2"; mkdir -p "$out"
bin="$app/Contents/MacOS/Dockyard"
here="$(cd "$(dirname "$0")" && pwd)"
swiftc -O "$here/window-id.swift" -o "$RUNNER_TEMP/window-id" || exit 1

shoot() { # name, appearance (light|dark), screen
  local name="$1" look="$2" screen="$3"
  local idfile="$RUNNER_TEMP/window-$name.id"
  # Sheets and popovers are only redrawn on the visible part of the screen, so those shots use a window that fits it.
  local size=1440x900
  case "$screen" in compare|recentChanges|siteEditor|siteEditorJump|siteEditorSafety|versions|conflict|launchPrompt|importPreview|importUnsupported|export|importExport) size=1000x680 ;; esac
  case "$screen" in siteEditor1Password|onePasswordImport) size=1000x680 ;; esac
  rm -f "$idfile"
  "$bin" -DockyardDemo YES -DockyardAppearance "$look" -DockyardDemoScreen "$screen" \
    -DockyardWindowSize "$size" -DockyardWindowIDFile "$idfile" -ApplePersistenceIgnoreState YES >"$out/$name.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 40); do [ -s "$idfile" ] && break; sleep 1; done
  osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$pid"') to true' >/dev/null 2>&1
  sleep 3
  local id=""
  if [ -s "$idfile" ]; then id="$(cat "$idfile")"; else id="$("$RUNNER_TEMP/window-id" Dockyard)"; fi
  if [ -n "$id" ]; then
    screencapture -x -o -l "$id" "$out/$name.png"
  else
    echo "no window for $name; capturing full screen"
    screencapture -x "$out/$name.png"
  fi
  kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
  [ -s "$out/$name.log" ] || rm -f "$out/$name.log"
}

for screen in main connectionManager siteEditor siteEditorJump logDrawer jump terminal sideBySide tabGroups compare editing recentChanges settings importPreview importUnsupported export importExport quickLook \
  transfers transfersFailed versions search watchFolders siteEditorSafety launchPrompt conflict; do
  shoot "$screen" light "$screen"
done
for screen in healthCheck recentlyRemoved onePasswordImport siteEditor1Password; do
  shoot "$screen" light "$screen"
done
shoot main-dark dark main
shoot terminal-dark dark terminal
ls -l "$out"
