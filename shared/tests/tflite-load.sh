#!/usr/bin/env bash
# tflite-load.sh — post-build smoke test for the TFLite shared libraries.
#
# dlopen()s each freshly-built library and resolves a symbol it must export.
# A success proves the .so loads and exports its API — catching a mislinked,
# stripped, or empty build that the compile step would not flag. Deliberately
# uses runtime dlopen (not header-compile) because that is how the consumers
# load the libraries (edgefirst-tflite uses dlopen/LoadLibrary), so this
# mirrors real use.
#
# Libraries tested (both staged into BUILD_DIR by the target build.sh):
#   - libtensorflowlite_c.so          -> TfLiteInterpreterCreate (C API)
#   - libtensorflow-lite.so.<version> -> TfLiteIntArrayCreate     (C++ runtime;
#       a C-linkage core symbol that survives the version-script export filter
#       *TfLite*)
#
# Inputs (env):
#   SOURCE_DIR  — extracted TensorFlow source
#   BUILD_DIR   — defaults to $SOURCE_DIR/_build (matches build_layout.output_dir)

set -euo pipefail

: "${SOURCE_DIR:?SOURCE_DIR not set}"
BUILD_DIR="${BUILD_DIR:-$SOURCE_DIR/_build}"

LIB_C="$BUILD_DIR/libtensorflowlite_c.so"
# The C++ lib carries a versioned SONAME (libtensorflow-lite.so.2.19.0); glob
# for the real versioned file rather than hard-coding the version here.
LIB_CPP="$(find "$BUILD_DIR" -maxdepth 1 -type f -name 'libtensorflow-lite.so.*' | head -1)"

[ -f "$LIB_C" ]   || { echo "ERROR: $LIB_C missing" >&2; exit 1; }
[ -n "$LIB_CPP" ] || { echo "ERROR: no libtensorflow-lite.so.* found in $BUILD_DIR" >&2; exit 1; }

command -v cc >/dev/null || { echo "ERROR: cc not on PATH (need a C compiler for the load test)" >&2; exit 1; }

TEST_DIR="$BUILD_DIR/tflite-load"
mkdir -p "$TEST_DIR"
cat > "$TEST_DIR/tflite-load.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>

/* usage: tflite-load <path-to-lib> <symbol> */
int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <path-to-lib> <symbol>\n", argv[0]);
        return 2;
    }
    void* h = dlopen(argv[1], RTLD_NOW);
    if (!h) {
        fprintf(stderr, "FAIL: dlopen(%s): %s\n", argv[1], dlerror());
        return 1;
    }
    /* Clear any stale error, then probe the required symbol. */
    dlerror();
    void* sym = dlsym(h, argv[2]);
    const char* err = dlerror();
    if (err != NULL || sym == NULL) {
        fprintf(stderr, "FAIL: %s not exported by %s: %s\n",
                argv[2], argv[1], err ? err : "symbol is NULL");
        return 1;
    }
    printf("OK: %s loaded; %s resolved\n", argv[1], argv[2]);
    return 0;
}
C

cc "$TEST_DIR/tflite-load.c" -ldl -o "$TEST_DIR/tflite-load"

echo "== Running tflite-load test =="
"$TEST_DIR/tflite-load" "$LIB_C"   TfLiteInterpreterCreate
"$TEST_DIR/tflite-load" "$LIB_CPP" TfLiteIntArrayCreate
