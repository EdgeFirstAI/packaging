#!/usr/bin/env bash
# cuda-ep-present.sh — on-device CUDA execution-provider acceptance test.
#
# Builds shared/tests/ort-cuda-probe.cpp and runs it against an ONNX Runtime
# core library on real CUDA hardware (e.g. a Jetson). The probe asserts the
# core was built with CUDA support, then appends the CUDA EP with CPU fallback
# disabled and runs a one-node Add model on the GPU. A PASS proves the core,
# libonnxruntime_providers_shared.so, and libonnxruntime_providers_cuda.so load
# together and the CUDA/cuDNN userspace initializes. Needs a GPU, so it is not
# a CI post-build test; CI runs the GPU-free half via cuda-ep-abi.sh.
#
# Two ways to run it:
#
#   Build tree (after run-build.sh on a Jetson):
#     SOURCE_DIR=work/<target_key>/source shared/tests/cuda-ep-present.sh
#
#   Installed .debs (on-device acceptance, TESTING.md). There is no -dev
#   package, so take the headers from the matching release tarball:
#     ORT_INCLUDE=<tarball>/include shared/tests/cuda-ep-present.sh
#
#   Unpublished .debs, unpacked with `dpkg-deb -x` into a staging root so the
#   device's installed packages are left untouched. The core loads the EP
#   plugins from its own directory, so the staged plugins are the ones tested:
#     ORT_ROOT=<staging> ORT_INCLUDE=<tarball>/include shared/tests/cuda-ep-present.sh
#
# Inputs (env):
#   SOURCE_DIR   — extracted ORT source; selects build-tree mode
#   BUILD_DIR    — build-tree output (default $SOURCE_DIR/build/Linux/Release)
#   ORT_ROOT     — staging root holding unpacked .debs (default: /, the system)
#   ORT_LIB      — core library to test. Default: the single real file behind
#                  libonnxruntime.so* in $BUILD_DIR (build-tree mode) or in
#                  $ORT_ROOT/usr/lib/<multiarch>. Matching the whole chain
#                  covers the build tree both before and after run-build.sh
#                  normalizes the soname (which drops libonnxruntime.so).
#   ORT_INCLUDE  — directory holding onnxruntime_cxx_api.h and friends.
#                  Default: $SOURCE_DIR/include/onnxruntime/core/session

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROBE_SRC="$SCRIPT_DIR/ort-cuda-probe.cpp"

command -v g++ >/dev/null || { echo "ERROR: g++ not on PATH (apt install g++)" >&2; exit 1; }

# Print the one real file every libonnxruntime.so* symlink in $1 resolves to.
find_core() {
    local found
    mapfile -t found < <(readlink -f "$1"/libonnxruntime.so* 2>/dev/null | sort -u)
    if [ "${#found[@]}" -ne 1 ] || [ ! -f "${found[0]}" ]; then
        echo "ERROR: expected exactly one libonnxruntime.so* library in $1; set ORT_LIB" >&2
        return 1
    fi
    echo "${found[0]}"
}

if [ -n "${SOURCE_DIR:-}" ]; then
    BUILD_DIR="${BUILD_DIR:-$SOURCE_DIR/build/Linux/Release}"
    ORT_LIB="${ORT_LIB:-$(find_core "$BUILD_DIR")}"
    ORT_INCLUDE="${ORT_INCLUDE:-$SOURCE_DIR/include/onnxruntime/core/session}"
    WORK_DIR="$BUILD_DIR/cuda-ep-present"
    mkdir -p "$WORK_DIR"
else
    : "${ORT_INCLUDE:?set ORT_INCLUDE to the release tarball include/ dir, or SOURCE_DIR for a build tree}"
    ORT_LIB="${ORT_LIB:-$(find_core "${ORT_ROOT:-}/usr/lib/$(gcc -print-multiarch)")}"
    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "$WORK_DIR"' EXIT
fi

[ -f "$ORT_LIB" ] || { echo "ERROR: ORT_LIB not found: $ORT_LIB" >&2; exit 1; }
[ -f "$ORT_INCLUDE/onnxruntime_cxx_api.h" ] || { echo "ERROR: onnxruntime_cxx_api.h not in ORT_INCLUDE: $ORT_INCLUDE" >&2; exit 1; }

g++ -std=c++17 -O1 "$PROBE_SRC" -I "$ORT_INCLUDE" -ldl -o "$WORK_DIR/ort-cuda-probe"

echo "== Running cuda-ep-present test =="
"$WORK_DIR/ort-cuda-probe" "$ORT_LIB"
