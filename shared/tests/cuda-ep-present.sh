#!/usr/bin/env bash
# cuda-ep-present.sh — post-build test for CUDA-enabled builds.
#
# Compiles a minimal C++ program against the freshly-built libonnxruntime
# and asserts that CUDAExecutionProvider is listed in available providers.
# A success proves both the .so and the CUDA EP plugin load cleanly — the
# most common silent failure (cuDNN ABI mismatch) shows up as a missing
# CUDAExecutionProvider rather than a build/link error.
#
# Inputs (env):
#   SOURCE_DIR  — extracted ORT source (its include/ provides headers)
#   BUILD_DIR   — defaults to $SOURCE_DIR/build/Linux/Release

set -euo pipefail

: "${SOURCE_DIR:?SOURCE_DIR not set}"
BUILD_DIR="${BUILD_DIR:-$SOURCE_DIR/build/Linux/Release}"

[ -d "$SOURCE_DIR/include" ] || { echo "ERROR: $SOURCE_DIR/include missing" >&2; exit 1; }
[ -f "$BUILD_DIR/libonnxruntime.so" ] || { echo "ERROR: $BUILD_DIR/libonnxruntime.so missing" >&2; exit 1; }

TEST_DIR="$BUILD_DIR/cuda-ep-present"
mkdir -p "$TEST_DIR"
cat > "$TEST_DIR/cuda-ep-present.cpp" <<'CPP'
#include <onnxruntime_cxx_api.h>
#include <iostream>

int main() {
    Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "cuda-ep-present");
    auto providers = Ort::GetAvailableProviders();
    bool cuda_seen = false;
    std::cout << "Available providers (" << providers.size() << "):\n";
    for (const auto& p : providers) {
        std::cout << "  " << p << "\n";
        if (p == "CUDAExecutionProvider") cuda_seen = true;
    }
    if (!cuda_seen) {
        std::cerr << "FAIL: CUDAExecutionProvider not present\n";
        return 1;
    }
    std::cout << "OK: CUDAExecutionProvider present\n";
    return 0;
}
CPP

g++ -std=c++17 -O0 "$TEST_DIR/cuda-ep-present.cpp" \
    -I "$SOURCE_DIR/include/onnxruntime/core/session" \
    -L "$BUILD_DIR" \
    -lonnxruntime \
    -Wl,-rpath,"$BUILD_DIR" \
    -o "$TEST_DIR/cuda-ep-present"

echo "== Running cuda-ep-present test =="
"$TEST_DIR/cuda-ep-present"
