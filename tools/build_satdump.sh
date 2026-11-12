#!/bin/zsh
# Compiles SatDump, Vessel's receiving and decoding engine, from source and gathers it with every library it
# needs into vendor/satdump, which build_app.sh seals inside Vessel.app. Nothing needs installing separately:
# people using Vessel never see SatDump as an app of its own. Only whoever builds Vessel runs this.
# Usage: tools/build_satdump.sh [deps|fetch|radios|nng|build|bundle|all]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
# The SatDump version Vessel is developed and tested against.
REF="${SATDUMP_REF:-9fee0793c7d42bea2d401d330422e18c33c126fa}"
WORK="${SATDUMP_WORK:-$ROOT/.build/satdump}"
SRC="$WORK/src"
OUT="$ROOT/vendor/satdump"
STEP="${1:-all}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
BREW="$(brew --prefix)"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

# The same Homebrew packages SatDump's own macOS build uses, without the ones only its window needs.
deps() {
    brew install cmake ninja pkgconf cpptrace gettext automake meson orc libxml2 zlib portaudio boost nng volk \
        libomp fftw jemalloc armadillo hdf5 libusb libpng
}

fetch() {
    mkdir -p "$WORK"
    if [ ! -d "$SRC/.git" ]; then
        git init -q "$SRC"
        git -C "$SRC" remote add origin https://github.com/SatDump/SatDump.git
    fi
    git -C "$SRC" fetch -q --depth 1 origin "$REF"
    git -C "$SRC" checkout -q --force FETCH_HEAD
    echo "SatDump at $(git -C "$SRC" rev-parse HEAD)"
}

# Radio libraries (Airspy, RTL-SDR, HackRF, HydraSDR, Fobos, LimeSDR, PlutoSDR, bladeRF, USRP), built by
# SatDump's own script into $SRC/deps. SDRplay's closed-source library is left out unless asked for,
# because it has its own licence: set VESSEL_SDRPLAY=1 to include it.
radios() {
    [ -d "$SRC/deps/lib" ] && [ -z "${REBUILD_RADIOS:-}" ] && { echo "Radio libraries already built (set REBUILD_RADIOS=1 to redo)"; return; }
    local script="$WORK/build_deps.sh"
    if [ -n "${VESSEL_SDRPLAY:-}" ]; then
        cp "$SRC/macOS/build_deps.sh" "$script"
    else
        awk '/^echo "Adding SDRPlay Library..."/{skip=1} skip && /^rm -rf sdrplay-macos\*/{skip=0; next} !skip' \
            "$SRC/macOS/build_deps.sh" > "$script"
    fi
    mkdir -p "$SRC/build"
    (cd "$SRC/build" && GITHUB_WORKSPACE="$SRC" PATH="$BREW/bin:$PATH" bash "$script")
}

# SatDump uses nng's 1.x interface, which Homebrew's nng 2 no longer has, so 1.x is built alongside the radios.
nng() {
    [ -f "$SRC/deps/include/nng/protocol/pubsub0/pub.h" ] && [ -z "${REBUILD_NNG:-}" ] && { echo "nng 1.x already built"; return; }
    local dir="$WORK/nng"
    [ -d "$dir/.git" ] || git clone -q --depth 1 --branch v1.12.4 https://github.com/nanomsg/nng.git "$dir"
    PATH="$BREW/bin:$PATH" cmake -S "$dir" -B "$dir/build" -GNinja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$SRC/deps" -DCMAKE_OSX_SYSROOT="$SDKROOT" -DBUILD_SHARED_LIBS=ON \
        -DNNG_TESTS=OFF -DNNG_TOOLS=OFF -DNNG_ENABLE_NNGCAT=OFF -DCMAKE_MACOSX_RPATH=ON
    cmake --build "$dir/build"
    cmake --install "$dir/build"
}

# Newer Xcode no longer pulls in the C standard headers indirectly, and some SatDump files rely on that,
# so they're included up front instead of changing SatDump's source.
build() {
    # CI=1 stops SatDump tuning itself to this Mac's exact chip, so the engine runs on any Apple silicon Mac.
    CI=1 PATH="$BREW/bin:$PATH" cmake -S "$SRC" -B "$SRC/build" -GNinja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$SDKROOT" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DBUNDLING_MODE=ON -DBUILD_GUI=OFF -DBUILD_TESTING=OFF -DBUILD_TOOLS=OFF \
        -UCMAKE_CXX_FLAGS -DCMAKE_PROJECT_INCLUDE="$ROOT/tools/satdump_headers.cmake" \
        -DNNG_LIBRARY="$SRC/deps/lib/libnng.dylib"
    cmake --build "$SRC/build"
}

# The engine's own layout, as Vessel expects it: MacOS/vessel-engine, Resources/{plugins,resources}, libs/.
bundle() {
    local exe="$SRC/build/satdump"
    [ -x "$exe" ] || { echo "No satdump at $exe. Run the build step first." >&2; exit 1; }
    rm -rf "$OUT"
    mkdir -p "$OUT/MacOS" "$OUT/libs" "$OUT/Resources/plugins"
    cp "$exe" "$OUT/MacOS/vessel-engine"
    cp "$SRC/build"/plugins/*.dylib "$OUT/Resources/plugins/"
    cp -R "$SRC/resources" "$OUT/Resources/resources"
    cp "$SRC/satdump_cfg.json" "$OUT/Resources/"
    chmod -R u+w "$OUT"
    local extra=()
    for p in "$OUT"/Resources/plugins/*.dylib; do extra+=(--also "$p"); done
    python3 -I "$ROOT/tools/bundle_dylibs.py" "$OUT/MacOS/vessel-engine" "$OUT/libs" \
        "$SRC/build" "$SRC/build/src-core" "$SRC/deps/lib" "$BREW/lib" "$BREW/opt/libomp/lib" \
        "$BREW/opt/openblas/lib" "$BREW/opt/gcc/lib/gcc/current" "${extra[@]}"
    cp "$SRC/LICENSE" "$OUT/LICENSE"
    cat > "$OUT/SOURCE.txt" <<EOF
Vessel's receiving and decoding engine is SatDump, by Aang23 and contributors, licensed under the
GNU General Public License v3.0 (see LICENSE in this folder). It runs as a separate program.

Built from commit $(git -C "$SRC" rev-parse HEAD)
Source: https://github.com/SatDump/SatDump/tree/$(git -C "$SRC" rev-parse HEAD)
The radio libraries it uses were built by SatDump's macOS/build_deps.sh from that same commit.
EOF
    du -sh "$OUT"
}

case "$STEP" in
    deps) deps ;;
    fetch) fetch ;;
    radios) radios ;;
    nng) nng ;;
    build) build ;;
    bundle) bundle ;;
    all) deps; fetch; radios; nng; build; bundle ;;
    *) echo "Usage: $0 [deps|fetch|radios|nng|build|bundle|all]" >&2; exit 1 ;;
esac
