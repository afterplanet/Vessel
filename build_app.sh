#!/bin/zsh
# Builds Vessel.app next to this script. Usage: ./build_app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
# SwiftUI macros need full Xcode, not the Command Line Tools, whatever xcode-select points to.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
# Built beside the real one and swapped in at the end, so nothing can start a half-built app.
FINAL="$PWD/Vessel.app"
APP="$PWD/.Vessel.building.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Vessel" "$APP/Contents/MacOS/Vessel"
cp -R "$BIN/Vessel_Vessel.bundle" "$APP/Contents/Resources/"
cp Support/Info.plist "$APP/Contents/Info.plist"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/"
# The receiving and decoding engine (SatDump) is built from source by tools/build_satdump.sh and sealed
# inside the app, so there's never a separate app to install. ENGINE_SOURCE can point at another build.
ENGINE_SOURCE="${ENGINE_SOURCE:-$PWD/vendor/satdump}"
if [ -x "$ENGINE_SOURCE/MacOS/vessel-engine" ]; then
    ditto "$ENGINE_SOURCE" "$APP/Contents/Resources/Engine"
elif [ -x "$ENGINE_SOURCE/Contents/MacOS/satdump" ]; then
    # A SatDump.app, as a fallback while the engine hasn't been built from source.
    ditto "$ENGINE_SOURCE/Contents" "$APP/Contents/Resources/Engine"
    mv "$APP/Contents/Resources/Engine/MacOS/satdump" "$APP/Contents/Resources/Engine/MacOS/vessel-engine"
    rm -f "$APP/Contents/Resources/Engine/MacOS/satdump-ui" "$APP/Contents/Resources/Engine/MacOS/satdump_sdr_server" "$APP/Contents/Resources/Engine/Info.plist"
else
    echo "warning: no engine at $ENGINE_SOURCE, so listening won't work in this build. Run tools/build_satdump.sh first." >&2
fi
# GPS positions are worked out by GNSS-SDR, also inside the app. tools/build_gnss_sdr.sh makes this folder.
GNSS_SOURCE="${GNSS_SOURCE:-$PWD/vendor/gnss-sdr}"
if [ -x "$GNSS_SOURCE/bin/gnss-sdr" ]; then
    ditto "$GNSS_SOURCE" "$APP/Contents/Resources/GNSS"
else
    echo "warning: no GNSS-SDR at $GNSS_SOURCE, so finding a position by GPS won't work in this build" >&2
fi
# The app can only open where every bundled library can load, so its minimum macOS is the highest any of
# them needs. Libraries from Homebrew are built for the macOS they were installed on.
MINOS="$(find "$APP/Contents" -type f \( -name '*.dylib' -o -perm -u+x \) -print0 2>/dev/null \
    | xargs -0 -n 50 otool -l 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/ minos /{print $2; f=0}' | sort -V | tail -1)"
if [ -n "$MINOS" ]; then
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MINOS" "$APP/Contents/Info.plist"
    echo "Minimum macOS: $MINOS"
fi
codesign --force --sign - "$APP"
rm -rf "$FINAL"
mv "$APP" "$FINAL"
echo "Built $FINAL"
