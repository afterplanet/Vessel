#!/bin/zsh
# Compiles GNSS-SDR from source and gathers it with every library it needs into vendor/gnss-sdr, which
# build_app.sh puts inside the app. Only whoever builds the app needs to run this: people using the app don't.
# Usage: tools/build_gnss_sdr.sh [deps|build|bundle|all]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TAG="${GNSS_SDR_TAG:-v0.0.22}"
WORK="${GNSS_SDR_WORK:-$ROOT/.build/gnss-sdr}"
OUT="$ROOT/vendor/gnss-sdr"
STEP="${1:-all}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
BREW="$(brew --prefix)"
# Xcode's SDK, as the Command Line Tools' can be out of step with the compiler.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

deps() {
    brew install armadillo boost cmake gnuradio hdf5 libmatio openssl pkg-config protobuf pugixml ninja gflags glog
}

build() {
    mkdir -p "$WORK"
    [ -d "$WORK/venv" ] || "$BREW/bin/python3" -m venv "$WORK/venv"
    "$WORK/venv/bin/pip" install --quiet mako six
    [ -d "$WORK/src/.git" ] || git clone --depth 1 --branch "$TAG" https://github.com/gnss-sdr/gnss-sdr.git "$WORK/src"
    PATH="$WORK/venv/bin:$BREW/bin:$PATH" cmake -S "$WORK/src" -B "$WORK/build" -GNinja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WORK/install" -DCMAKE_OSX_SYSROOT="$SDKROOT" \
        -DPython3_EXECUTABLE="$WORK/venv/bin/python" -DPYTHON_EXECUTABLE="$WORK/venv/bin/python" \
        -DENABLE_UNIT_TESTING=OFF -DENABLE_SYSTEM_TESTING=OFF -DENABLE_INSTALL_TESTS=OFF \
        -DENABLE_UNIT_TESTING_MINIMAL=OFF -DENABLE_PACKAGING=OFF
    cmake --build "$WORK/build"
    cmake --install "$WORK/build"
}

# Copies a library and everything it needs into libs/, pointing them all at each other.
bundle() {
    local exe="$WORK/install/bin/gnss-sdr"
    [ -x "$exe" ] || { echo "No gnss-sdr at $exe" >&2; exit 1; }
    rm -rf "$OUT"
    mkdir -p "$OUT/bin" "$OUT/libs"
    cp "$exe" "$OUT/bin/gnss-sdr"
    chmod u+w "$OUT/bin/gnss-sdr"
    python3 -I "$ROOT/tools/bundle_dylibs.py" "$OUT/bin/gnss-sdr" "$OUT/libs" "$WORK/install/lib"
    cp "$WORK/src/COPYING" "$OUT/COPYING" 2>/dev/null || cp "$WORK/src/LICENSE" "$OUT/COPYING" 2>/dev/null || true
    echo "GNSS-SDR $TAG, source at https://github.com/gnss-sdr/gnss-sdr/tree/$TAG" > "$OUT/SOURCE.txt"
    du -sh "$OUT"
}

case "$STEP" in
    deps) deps ;;
    build) build ;;
    bundle) bundle ;;
    all) deps; build; bundle ;;
    *) echo "Usage: $0 [deps|build|bundle|all]" >&2; exit 1 ;;
esac
