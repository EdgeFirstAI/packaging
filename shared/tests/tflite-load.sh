#!/usr/bin/env bash
# tflite-load.sh — post-build smoke test for the TFLite C API library.
#
# dlopen()s the freshly-built libtensorflowlite_c.so and resolves a core
# C API symbol (TfLiteInterpreterCreate). A success proves the .so loads
# and exports the C API — catching a mislinked, stripped, or empty build
# that the compile step would not flag. Deliberately uses runtime dlopen
# (not header-compile) because that is how the consumers load the library
# (edgefirst-tflite uses dlopen/LoadLibrary), so this mirrors real use.
#
# Inputs (env):
#   SOURCE_DIR  — extracted TensorFlow source
#   BUILD_DIR   — defaults to $SOURCE_DIR/_build (matches build_layout.output_dir)

set -euo pipefail

: "${SOURCE_DIR:?SOURCE_DIR not set}"
BUILD_DIR="${BUILD_DIR:-$SOURCE_DIR/_build}"
LIB="$BUILD_DIR/libtensorflowlite_c.so"

[ -f "$LIB" ] || { echo "ERROR: $LIB missing" >&2; exit 1; }

command -v cc >/dev/null || { echo "ERROR: cc not on PATH (need a C compiler for the load test)" >&2; exit 1; }

TEST_DIR="$BUILD_DIR/tflite-load"
mkdir -p "$TEST_DIR"
cat > "$TEST_DIR/tflite-load.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <path-to-libtensorflowlite_c.so>\n", argv[0]);
        return 2;
    }
    void* h = dlopen(argv[1], RTLD_NOW);
    if (!h) {
        fprintf(stderr, "FAIL: dlopen: %s\n", dlerror());
        return 1;
    }
    /* Clear any stale error, then probe a core C API symbol. */
    dlerror();
    void* sym = dlsym(h, "TfLiteInterpreterCreate");
    const char* err = dlerror();
    if (err != NULL || sym == NULL) {
        fprintf(stderr, "FAIL: TfLiteInterpreterCreate not exported: %s\n",
                err ? err : "symbol is NULL");
        return 1;
    }
    printf("OK: libtensorflowlite_c loaded; TfLiteInterpreterCreate resolved\n");
    return 0;
}
C

cc "$TEST_DIR/tflite-load.c" -ldl -o "$TEST_DIR/tflite-load"

echo "== Running tflite-load test =="
"$TEST_DIR/tflite-load" "$LIB"
