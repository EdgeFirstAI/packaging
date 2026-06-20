#!/usr/bin/env bash
# build.sh — build the TFLite shared libraries for linux-x86_64.
#
# CMake-based (NOT bazel). Builds BOTH libraries the package ships:
#   - C API : cmake -S tensorflow/lite/c  -> libtensorflowlite_c.so
#   - C++   : cmake -S tensorflow/lite    -> libtensorflow-lite.so.2.19.0 (+ .so)
# Both are staged into $SOURCE_DIR/_build so the single build_layout.output_dir
# glob (libtensorflow*.so*) collects them with their symlink chains.
#
# The C++ shared build requires the recipe's CMake patch
# (TFLITE_BUILD_SHARED_LIB, applied by fetch-source.sh); the C API project
# builds shared natively. Flags come from the recipe's
# build_defaults.cmake_extra_defines, optionally overlaid by this target's
# build.cmake_extra_defines (target keys win, mirroring the ORT target).
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
[ -f "$SOURCE_DIR/tensorflow/lite/CMakeLists.txt" ] \
    || { echo "ERROR: $SOURCE_DIR/tensorflow/lite/CMakeLists.txt missing — not a TensorFlow source tree" >&2; exit 1; }

command -v yq    >/dev/null || { echo "ERROR: yq not on PATH" >&2; exit 1; }
command -v cmake >/dev/null || { echo "ERROR: cmake not on PATH (source the build venv)" >&2; exit 1; }
command -v ninja >/dev/null || echo "WARN: ninja not on PATH; CMake will fall back to make"

PARALLEL="${PARALLEL:-$(yq -r '.parallel // 2' "$TARGET_YAML")}"

# CONFIG: recipe build_defaults.config, default Release. (tflite has no
# per-target config override today; recipe is the single source.)
CONFIG="$(yq -r '.build_defaults.config // "Release"' "$RECIPE")"
[ "$CONFIG" = "null" ] && CONFIG="Release"

C_API_SRC="$SOURCE_DIR/tensorflow/lite/c"
CPP_SRC="$SOURCE_DIR/tensorflow/lite"
BUILD_DIR="$SOURCE_DIR/_build"          # build_layout.output_dir — both libs land here
CPP_BUILD_DIR="$SOURCE_DIR/_build_cpp"  # separate config dir for the C++ project

# Assemble -D defines: recipe build_defaults.cmake_extra_defines first, then
# overlay target build.cmake_extra_defines (later -D wins in CMake). Same
# IFS='=' idiom as the ORT target's build.sh. Applied to BOTH projects; the
# C-API-only TFLITE_C_BUILD_SHARED_LIBS is simply unused (a harmless warning)
# by the C++ project, which keys off TFLITE_BUILD_SHARED_LIB instead.
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

echo "== build settings =="
echo "C API src : $C_API_SRC"
echo "C++   src : $CPP_SRC"
echo "output    : $BUILD_DIR"
echo "config    : $CONFIG"
echo "parallel  : $PARALLEL"
echo "defines   : ${CMAKE_DEFINES[*]:-(none)}"
echo

# ---- C API: libtensorflowlite_c.so -------------------------------------------
echo "== [1/2] cmake configure (C API) =="
cmake -S "$C_API_SRC" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="$CONFIG" \
    "${CMAKE_DEFINES[@]}"

echo
echo "== [1/2] cmake build (C API) =="
cmake --build "$BUILD_DIR" --config "$CONFIG" --parallel "$PARALLEL"

[ -f "$BUILD_DIR/libtensorflowlite_c.so" ] \
    || { echo "ERROR: build did not produce $BUILD_DIR/libtensorflowlite_c.so" >&2; exit 1; }

# ---- C++: libtensorflow-lite.so.2.19.0 ---------------------------------------
echo
echo "== [2/2] cmake configure (C++ shared) =="
cmake -S "$CPP_SRC" -B "$CPP_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="$CONFIG" \
    -DTFLITE_BUILD_SHARED_LIB=ON \
    "${CMAKE_DEFINES[@]}"

echo
echo "== [2/2] cmake build (C++ shared) =="
# Build only the library target — skip the example/benchmark/test executables.
cmake --build "$CPP_BUILD_DIR" --config "$CONFIG" --parallel "$PARALLEL" --target tensorflow-lite

# Locate the real versioned C++ .so the build produced (CMake writes it to the
# build root for single-config generators, but glob a couple levels deep to be
# robust), then stage its whole symlink chain into BUILD_DIR with cp -P.
CPP_SO_REAL="$(find "$CPP_BUILD_DIR" -maxdepth 2 -type f -name 'libtensorflow-lite.so.*' | head -1)"
[ -n "$CPP_SO_REAL" ] \
    || { echo "ERROR: C++ build did not produce libtensorflow-lite.so.* under $CPP_BUILD_DIR" >&2; exit 1; }
CPP_SO_DIR="$(dirname "$CPP_SO_REAL")"
cp -P "$CPP_SO_DIR"/libtensorflow-lite.so* "$BUILD_DIR/"

# Sanity: both libraries must now be present in the single output dir.
compgen -G "$BUILD_DIR/libtensorflow-lite.so.*" >/dev/null \
    || { echo "ERROR: C++ lib not staged into $BUILD_DIR" >&2; exit 1; }

echo
echo "== build succeeded =="
ls -lh "$BUILD_DIR"/libtensorflowlite_c.so "$BUILD_DIR"/libtensorflow-lite.so*
