#!/bin/zsh
# Checks that a built Vessel.app starts and that its engines run, on whatever macOS this is.
# Usage: tools/smoke_test.sh [path/to/Vessel.app]
set -uo pipefail
APP="${1:-Vessel.app}"
LOG="$(mktemp -d)"
fail() { echo "FAIL: $1" >&2; exit 1; }
echo "macOS $(sw_vers -productVersion), $(uname -m)"
echo "App needs macOS $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"

codesign --verify --deep --strict "$APP" || fail "the app's signature is broken"

# Every library must come from inside the app or from macOS itself.
outside=$(find "$APP/Contents" -type f \( -name '*.dylib' -o -perm -u+x \) -print0 | xargs -0 otool -L 2>/dev/null \
    | grep -E '^\s+/(opt|usr/local|Users)/' | sort -u)
[ -z "$outside" ] || fail "libraries from outside the app:\n$outside"

ENGINE="$APP/Contents/Resources/Engine/MacOS/vessel-engine"
[ -x "$ENGINE" ] || fail "no receiving engine in the app"
"$ENGINE" legacy sdr_probe > "$LOG/probe.txt" 2>&1 &
PROBE=$!
for i in {1..60}; do grep -q "Done! Goodbye" "$LOG/probe.txt" && break; sleep 1; done
kill -9 $PROBE 2>/dev/null
grep -q "Found devices (sources)" "$LOG/probe.txt" || { tail -30 "$LOG/probe.txt"; fail "the engine didn't list its sources"; }
grep -q "type : rtltcp" "$LOG/probe.txt" || fail "the engine's radio plugins didn't load"
echo "engine: ok"

GNSS="$APP/Contents/Resources/GNSS/bin/gnss-sdr"
if [ -x "$GNSS" ]; then
    "$GNSS" --version > "$LOG/gnss.txt" 2>&1 || { cat "$LOG/gnss.txt"; fail "GNSS-SDR didn't run"; }
    echo "gps engine: $(head -1 "$LOG/gnss.txt")"
else
    echo "gps engine: not included"
fi

VESSEL_TEST="--hardware-report --hardware-wait 8" "$APP/Contents/MacOS/Vessel" > "$LOG/app.txt" 2>&1 &
APPPID=$!
for i in {1..120}; do grep -q "^hardware:" "$LOG/app.txt" && break; kill -0 $APPPID 2>/dev/null || break; sleep 1; done
kill -0 $APPPID 2>/dev/null || { tail -40 "$LOG/app.txt"; fail "the app quit or crashed on launch"; }
grep -q "^hardware:" "$LOG/app.txt" || { tail -40 "$LOG/app.txt"; fail "the app didn't finish starting"; }
sleep 10
kill -0 $APPPID 2>/dev/null || { tail -40 "$LOG/app.txt"; fail "the app crashed after starting"; }
kill -9 $APPPID 2>/dev/null
pkill -9 -f "$APP/Contents/Resources/Engine" 2>/dev/null
echo "app: ok ($(grep '^hardware:' "$LOG/app.txt"))"
echo "PASS"
