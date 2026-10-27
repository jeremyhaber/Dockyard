#!/bin/bash
# Launches Dockyard in demo mode on each screen and captures its window.
# Usage: screenshots.sh <path to Dockyard.app> <output dir>
set -u
app="$1"; out="$2"; mkdir -p "$out"
bin="$app/Contents/MacOS/Dockyard"
here="$(cd "$(dirname "$0")" && pwd)"
swiftc -O "$here/window-id.swift" -o "$RUNNER_TEMP/window-id" || exit 1

shoot() { # name, appearance, extra args...
  local name="$1" look="$2"; shift 2
  "$bin" -DockyardDemo YES -AppleInterfaceStyle "$look" -ApplePersistenceIgnoreState YES "$@" >"$out/$name.log" 2>&1 &
  local pid=$!
  sleep 10
  osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$pid"') to true' >/dev/null 2>&1
  sleep 2
  if id=$("$RUNNER_TEMP/window-id" Dockyard); then
    screencapture -x -o -l "$id" "$out/$name.png"
  else
    echo "no window for $name; capturing full screen"
    screencapture -x "$out/$name.png"
  fi
  kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
  [ -s "$out/$name.log" ] || rm -f "$out/$name.log"
}

for screen in main connectionManager siteEditor logDrawer jump; do
  shoot "$screen" Light -DockyardDemoScreen "$screen"
done
shoot main-dark Dark -DockyardDemoScreen main
ls -l "$out"
