#!/usr/bin/env bash
# build.sh — build the TFLite C API shared library for linux-aarch64.
#
# CMake-based: upstream ships a self-contained CMakeLists at
# tensorflow/lite/c/. We configure into $SOURCE_DIR/_build and build only
# libtensorflowlite_c (the C API). Flags come from the recipe's
# build_defaults.cmake_extra_defines, optionally overlaid by this target's
# build.cmake_extra_defines (target keys win, mirroring the ORT target).
#
# Unlike the ORT Jetson target, this is a CPU-only build with no CUDA — it
# runs on any aarch64 Linux host, not just physical Jetson hardware.
#
# Inputs (env):
#   SOURCE_DIR  — path to extracted TensorFlow source (from fetch-source.sh)
#   RECIPE      — path to recipe yaml (for build_defaults)
#   PARALLEL    — override target's default parallelism (optional)

set -euo pipefail

TARGET_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_YAML="$TARGET_DIR/target.yaml"

: "${SOURCE_DIR:?SOURCE_DIR not set (path to extracted TensorFlow source)}"
: "${RECIPE:?RECIPE not set (path to recipe yaml)}"
[ -d "$SOURCE_DIR" ] || { echo "ERROR: SOURCE_DIR does not exist: $SOURCE_DIR" >&2; exit 1; }
[ -f "$SOURCE_DIR/tensorflow/lite/c/CMakeLists.txt" ] \
    || { echo "ERROR: $SOURCE_DIR/tensorflow/lite/c/CMakeLists.txt missing — not a TensorFlow source tree" >&2; exit 1; }

command -v yq    >/dev/null || { echo "ERROR: yq not on PATH" >&2; exit 1; }
command -v cmake >/dev/null || { echo "ERROR: cmake not on PATH (source the build venv)" >&2; exit 1; }
command -v ninja >/dev/null || echo "WARN: ninja not on PATH; CMake will fall back to make"

PARALLEL="${PARALLEL:-$(yq -r '.parallel // 2' "$TARGET_YAML")}"

# CONFIG: recipe build_defaults.config, default Release. (tflite has no
# per-target config override today; recipe is the single source.)
CONFIG="$(yq -r '.build_defaults.config // "Release"' "$RECIPE")"
[ "$CONFIG" = "null" ] && CONFIG="Release"

SRC_PROJECT="$SOURCE_DIR/tensorflow/lite/c"
BUILD_DIR="$SOURCE_DIR/_build"

# Assemble -D defines: recipe build_defaults.cmake_extra_defines first, then
# overlay target build.cmake_extra_defines (later -D wins in CMake). Same
# IFS='=' idiom as the ORT target's build.sh.
CMAKE_DEFINES=()
EXTENDS="$(yq -r '.build.extends_recipe_defaults // true' "$TARGET_YAML")"
if [ "$EXTENDS" = "true" ]; then
    while IFS='=' read -r k v; do
        [ -z "$k" ] && continue
        CMAKE_DEFINES+=("-D${k}=${v}")
    done < <(yq -r '.build_defaults.cmake_extra_defines // {} | to_entries | .[] | "\(.key)=\(.value)"' "$RECIPE")
fi
while IFS='=' read -r k v; do
    [ -z "$k" ] && continue
    CMAKE_DEFINES+=("-D${k}=${v}")
done < <(yq -r '.build.cmake_extra_defines // {} | to_entries | .[] | "\(.key)=\(.value)"' "$TARGET_YAML")

echo "== build =="
echo "source  : $SRC_PROJECT"
echo "build   : $BUILD_DIR"
echo "config  : $CONFIG"
echo "parallel: $PARALLEL"
echo "defines : ${CMAKE_DEFINES[*]:-(none)}"
echo

echo "== cmake configure =="
cmake -S "$SRC_PROJECT" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="$CONFIG" \
    "${CMAKE_DEFINES[@]}"

echo
echo "== cmake build =="
cmake --build "$BUILD_DIR" --config "$CONFIG" --parallel "$PARALLEL"

# Sanity: the library must exist where build_layout.output_dir (_build) points.
[ -f "$BUILD_DIR/libtensorflowlite_c.so" ] \
    || { echo "ERROR: build did not produce $BUILD_DIR/libtensorflowlite_c.so" >&2; exit 1; }

echo
echo "== build succeeded =="
ls -lh "$BUILD_DIR/libtensorflowlite_c.so"
