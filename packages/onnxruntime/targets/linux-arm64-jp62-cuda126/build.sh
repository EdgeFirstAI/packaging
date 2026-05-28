#!/usr/bin/env bash
# build.sh — invoke ORT's build.sh with the flags this target requires.
#
# Called from the workflow after shared/fetch-source.sh has produced a
# clean source tree at $SOURCE_DIR. Reads the target's own target.yaml
# and the recipe (passed via env) to assemble build flags.
#
# Inputs (env):
#   SOURCE_DIR   — path to extracted ORT source (from fetch-source.sh)
#   RECIPE       — path to recipe yaml (for build_defaults)
#   PARALLEL     — override target's default parallelism (optional)

set -euo pipefail

TARGET_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TARGET_DIR/../.." && pwd)"
TARGET_YAML="$TARGET_DIR/target.yaml"

: "${SOURCE_DIR:?SOURCE_DIR not set (path to extracted ORT source)}"
: "${RECIPE:?RECIPE not set (path to recipe yaml)}"
[ -d "$SOURCE_DIR" ] || { echo "ERROR: SOURCE_DIR does not exist: $SOURCE_DIR" >&2; exit 1; }
[ -f "$SOURCE_DIR/build.sh" ] || { echo "ERROR: $SOURCE_DIR/build.sh missing — not an ORT source tree" >&2; exit 1; }

command -v yq    >/dev/null || { echo "ERROR: yq not on PATH" >&2; exit 1; }
command -v cmake >/dev/null || { echo "ERROR: cmake not on PATH (source build venv)" >&2; exit 1; }
command -v ninja >/dev/null || { echo "WARN: ninja not on PATH; ORT will fall back to make"; }

PARALLEL="${PARALLEL:-$(yq -r '.parallel' "$TARGET_YAML")}"
# CONFIG resolution: target value wins if set; otherwise the recipe's
# build_defaults.config; otherwise "Release". (The previous form chained
# yq invocations through a pipe in a way that always ended up Release —
# this is the explicit precedence we actually want.)
CONFIG_TARGET="$(yq -r '.build.flags.config // ""' "$TARGET_YAML")"
CONFIG_RECIPE="$(yq -r '.build_defaults.config // ""' "$RECIPE")"
if [ -n "$CONFIG_TARGET" ] && [ "$CONFIG_TARGET" != "null" ]; then
    CONFIG="$CONFIG_TARGET"
elif [ -n "$CONFIG_RECIPE" ] && [ "$CONFIG_RECIPE" != "null" ]; then
    CONFIG="$CONFIG_RECIPE"
else
    CONFIG="Release"
fi

# Extract flags from target + recipe, merging. Target wins on conflicts.
TARGET_KEY="$(yq -r '.key' "$TARGET_YAML")"
USE_CUDA="$(yq -r '.build.flags.use_cuda // false' "$TARGET_YAML")"
CUDA_HOME="$(yq -r '.build.flags.cuda_home // "/usr/local/cuda"' "$TARGET_YAML")"
CUDNN_HOME="$(yq -r '.build.flags.cudnn_home // ""' "$TARGET_YAML")"
ALLOW_ROOT="$(yq -r '.build.flags.allow_running_as_root // false' "$TARGET_YAML")"

echo "== build =="
echo "source : $SOURCE_DIR"
echo "target : $TARGET_KEY"
echo "config : $CONFIG"
echo "parallel: $PARALLEL"
echo "use_cuda: $USE_CUDA"
[ "$USE_CUDA" = "true" ] && echo "cuda_home: $CUDA_HOME, cudnn_home: $CUDNN_HOME"
echo

# Assemble CMake extra defines by merging recipe.build_defaults.cmake_extra_defines
# with target.build.cmake_extra_defines. Target keys overwrite recipe keys.
CMAKE_DEFINES=()
EXTENDS="$(yq -r '.build.extends_recipe_defaults // true' "$TARGET_YAML")"
if [ "$EXTENDS" = "true" ]; then
    while IFS='=' read -r k v; do
        [ -z "$k" ] && continue
        CMAKE_DEFINES+=("$k=$v")
    done < <(yq -r '.build_defaults.cmake_extra_defines // {} | to_entries | .[] | "\(.key)=\(.value)"' "$RECIPE")
fi
# Overlay target-specific defines (later assignments to the same key win in CMake).
while IFS='=' read -r k v; do
    [ -z "$k" ] && continue
    CMAKE_DEFINES+=("$k=$v")
done < <(yq -r '.build.cmake_extra_defines // {} | to_entries | .[] | "\(.key)=\(.value)"' "$TARGET_YAML")

# Build the command line for ORT's build.sh
CMD=(./build.sh --config "$CONFIG" --build_shared_lib --parallel "$PARALLEL" --skip_tests)
[ "$USE_CUDA" = "true" ] && CMD+=(--use_cuda --cuda_home "$CUDA_HOME")
[ -n "$CUDNN_HOME" ] && [ "$CUDNN_HOME" != "null" ] && CMD+=(--cudnn_home "$CUDNN_HOME")
[ "$ALLOW_ROOT" = "true" ] && CMD+=(--allow_running_as_root)
if [ "${#CMAKE_DEFINES[@]}" -gt 0 ]; then
    CMD+=(--cmake_extra_defines)
    CMD+=("${CMAKE_DEFINES[@]}")
fi

echo "command:"
printf '  %q' "${CMD[@]}"
echo
echo

cd "$SOURCE_DIR"
"${CMD[@]}"

echo
echo "== build succeeded =="
ls -lh "$SOURCE_DIR/build/Linux/$CONFIG/"libonnxruntime*.so* 2>/dev/null || true
