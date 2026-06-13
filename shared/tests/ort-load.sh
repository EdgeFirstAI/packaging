#!/usr/bin/env bash
# ort-load.sh — post-build smoke test for a CPU ONNX Runtime build.
#
# dlopen()s the freshly-built libonnxruntime.so and resolves the C API entry
# point (OrtGetApiBase). A success proves the base library loads and exports
# the ONNX Runtime C API — catching a mislinked or stripped build that the
# compile step would not flag. GPU-free and header-free (pure dlopen), so it
# runs on any hosted runner; it deliberately does not touch a CUDA EP (the CPU
# targets ship none — the CUDA EP has its own static check, cuda-ep-abi.sh).
#
# Inputs (env):
#   SOURCE_DIR  — extracted ORT source
#   BUILD_DIR   — defaults to $SOURCE_DIR/build/Linux/Release

set -euo pipefail

: "${SOURCE_DIR:?SOURCE_DIR not set}"
BUILD_DIR="${BUILD_DIR:-$SOURCE_DIR/build/Linux/Release}"
LIB="$BUILD_DIR/libonnxruntime.so"

[ -f "$LIB" ] || { echo "ERROR: $LIB missing" >&2; exit 1; }
command -v cc >/dev/null || { echo "ERROR: cc not on PATH (need a C compiler for the load test)" >&2; exit 1; }

TEST_DIR="$BUILD_DIR/ort-load"
mkdir -p "$TEST_DIR"
cat > "$TEST_DIR/ort-load.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <path-to-libonnxruntime.so>\n", argv[0]);
        return 2;
    }
    void* h = dlopen(argv[1], RTLD_NOW);
    if (!h) {
        fprintf(stderr, "FAIL: dlopen: %s\n", dlerror());
        return 1;
    }
    /* Clear any stale error, then probe the C API entry point. */
    dlerror();
    void* sym = dlsym(h, "OrtGetApiBase");
    const char* err = dlerror();
    if (err != NULL || sym == NULL) {
        fprintf(stderr, "FAIL: OrtGetApiBase not exported: %s\n",
                err ? err : "symbol is NULL");
        return 1;
    }
    printf("OK: libonnxruntime loaded; OrtGetApiBase resolved\n");
    return 0;
}
C

cc "$TEST_DIR/ort-load.c" -ldl -o "$TEST_DIR/ort-load"

echo "== Running ort-load test =="
"$TEST_DIR/ort-load" "$LIB"
