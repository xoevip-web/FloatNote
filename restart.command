#!/bin/bash
# Restart FloatNote: quit the running instance of this FloatNote.app, then open it again.
# Double-click in Finder, or run ./restart.command in a terminal.
# Only the instance started from this app bundle is stopped; FLOATNOTE_PROFILE dev runs are not affected.

APP="$(cd "$(dirname "$0")" && pwd)/FloatNote.app"
BIN="$APP/Contents/MacOS/FloatNote"

if [ ! -x "$BIN" ]; then
  echo "FloatNote.app not found at: $APP"
  echo "Run ./build.sh first."
  read -n 1 -s -r -p "Press any key to close..."
  exit 1
fi

# Stop the running instance(s) started from this bundle
if pgrep -f "^$BIN" >/dev/null; then
  echo "Quitting FloatNote..."
  pkill -f "^$BIN"
  # Wait up to 5 seconds for it to exit
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "^$BIN" >/dev/null || break
    sleep 0.5
  done
  if pgrep -f "^$BIN" >/dev/null; then
    echo "Still running, forcing quit..."
    pkill -9 -f "^$BIN"
    sleep 0.5
  fi
fi

echo "Opening FloatNote..."
open "$APP"
echo "Done."
sleep 1
