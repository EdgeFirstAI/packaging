#!/usr/bin/env bash
# package-tarball.sh — produce a redistributable tarball from a built tree.
#
# Generic across upstream packages. Reads `build_layout` from the recipe
# (which library globs to copy, which headers, where the build wrote
# output) and `provenance` from the target.yaml. Same script handles
# onnxruntime, tflite, future packages.
#
# Inputs (env):
#   SOURCE_DIR   — extracted source (contains build output + headers)
#   RECIPE       — recipe yaml (for upstream metadata + build_layout)
#   TARGET_YAML  — target yaml (for target key + provenance hints)
#   BUILD_NUMBER — EdgeFirst build counter (default 1)
#   DIST_DIR     — where to write the tarball (default $SOURCE_DIR/../dist)
#   CONFIG       — Release|Debug (default Release; substituted into build_layout.output_dir)

set -euo pipefail

: "${SOURCE_DIR:?SOURCE_DIR not set}"
: "${RECIPE:?RECIPE not set}"
: "${TARGET_YAML:?TARGET_YAML not set}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST_DIR="${DIST_DIR:-$(dirname "$SOURCE_DIR")/dist}"
CONFIG="${CONFIG:-Release}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_cmd yq
require_sha256

# Sets UPSTREAM_REPO, UPSTREAM_TAG, UPSTREAM_SHA, UPSTREAM_NAME,
# PKG_NAME, PKG_VERSION, TARGET_KEY, LICENSE_SPDX, BUILD_OUTPUT.
load_recipe_identity "$RECIPE" "$TARGET_YAML" "$SOURCE_DIR"
[ -d "$BUILD_OUTPUT" ] || { echo "ERROR: build output dir not found: $BUILD_OUTPUT" >&2; exit 1; }

STAGE_NAME="${PKG_NAME}-${PKG_VERSION}-edgefirst${BUILD_NUMBER}-${TARGET_KEY}"
STAGE_DIR="$DIST_DIR/$STAGE_NAME"
TARBALL="$DIST_DIR/${PKG_NAME}-${TARGET_KEY}.tar.gz"

echo "== package-tarball =="
echo "package      : $PKG_NAME"
echo "version      : $PKG_VERSION (upstream $UPSTREAM_TAG)"
echo "target key   : $TARGET_KEY"
echo "build #      : $BUILD_NUMBER"
echo "build output : $BUILD_OUTPUT"
echo "stage        : $STAGE_DIR"
echo "tarball      : $TARBALL"
echo

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/lib" "$STAGE_DIR/include"

# main: glob that includes the SONAME chain. cp -P preserves symlinks
# (without -P, three identical full binaries ship and SONAME linking breaks).
MAIN_GLOB="$(yq -r '.build_layout.libraries.main' "$RECIPE")"
if [ -z "$MAIN_GLOB" ] || [ "$MAIN_GLOB" = "null" ]; then
    echo "ERROR: build_layout.libraries.main is missing or null in $RECIPE" >&2
    exit 1
fi
# shellcheck disable=SC2086
for f in $BUILD_OUTPUT/$MAIN_GLOB; do
    [ -e "$f" ] || continue
    cp -P "$f" "$STAGE_DIR/lib/"
done

# extras: optional plugin libraries (e.g., EP providers). Missing files are
# skipped silently since different builds enable different optional libraries.
# Guard against N=0: BSD seq(1) outputs "0\n-1" for `seq 0 -1` (auto-decrement),
# unlike GNU seq which outputs nothing. Skip the loop entirely for empty lists.
EXTRAS_COUNT="$(yq -r '.build_layout.libraries.extras // [] | length' "$RECIPE")"
if [ "$EXTRAS_COUNT" -gt 0 ]; then
    for i in $(seq 0 $((EXTRAS_COUNT - 1))); do
        EXTRA="$(yq -r ".build_layout.libraries.extras[$i]" "$RECIPE")"
        if [ -f "$BUILD_OUTPUT/$EXTRA" ]; then
            cp "$BUILD_OUTPUT/$EXTRA" "$STAGE_DIR/lib/"
        fi
    done
fi

HEADERS_COUNT="$(header_count "$RECIPE")"
if [ "$HEADERS_COUNT" -gt 0 ]; then
    for i in $(seq 0 $((HEADERS_COUNT - 1))); do
        IFS=$'\t' read -r H_SRC H_DEST <<<"$(header_src_dest "$RECIPE" "$i")"
        stage_header "$SOURCE_DIR" "$H_SRC" "$H_DEST" "$STAGE_DIR/include"
    done
fi

DOCS_COUNT="$(yq -r '.build_layout.docs // [] | length' "$RECIPE")"
if [ "$DOCS_COUNT" -gt 0 ]; then
    for i in $(seq 0 $((DOCS_COUNT - 1))); do
        D="$(yq -r ".build_layout.docs[$i]" "$RECIPE")"
        if [ -f "$SOURCE_DIR/$D" ]; then
            cp "$SOURCE_DIR/$D" "$STAGE_DIR/"
        fi
    done
fi

# ---- BUILD_INFO.txt provenance -------------------------------------------
# Each probe is wrapped to never fail under set -euo pipefail; missing tools
# yield "n/a" or "unknown". Kept inline (vs a helper) so the actual probed
# path/command stays visible at the call site.
NVCC_BIN="$(command -v nvcc 2>/dev/null || echo /usr/local/cuda/bin/nvcc)"
L4T_MAJOR="$(grep -oE '^# R[0-9]+' /etc/nv_tegra_release 2>/dev/null | head -1 | sed 's/^# R//' || true)"
L4T_REV="$(grep -oE 'REVISION: [0-9.]+' /etc/nv_tegra_release 2>/dev/null | head -1 | sed 's/REVISION: //' || true)"
if [ -n "${L4T_MAJOR:-}" ] && [ -n "${L4T_REV:-}" ]; then
    L4T_LINE="R${L4T_MAJOR}.${L4T_REV}"
else
    L4T_LINE="n/a"
fi
CUDA_LINE="$( "$NVCC_BIN" --version 2>/dev/null | grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^V//' || true)"
CUDA_LINE="${CUDA_LINE:-n/a}"
CMAKE_FROM_BUILD="$(grep '^CMAKE_COMMAND:' "$BUILD_OUTPUT/CMakeCache.txt" 2>/dev/null | cut -d= -f2- || true)"
if [ -n "$CMAKE_FROM_BUILD" ] && [ -x "$CMAKE_FROM_BUILD" ]; then
    CMAKE_LINE="$("$CMAKE_FROM_BUILD" --version 2>/dev/null | head -1)"
else
    CMAKE_LINE="$(cmake --version 2>/dev/null | head -1 || echo unknown)"
fi
JETPACK_LINE="$(dpkg-query -W -f='${Version}\n' nvidia-jetpack 2>/dev/null \
    || dpkg-query -W -f='${Version}\n' nvidia-l4t-core 2>/dev/null || echo n/a)"
CUDNN_LINE="$(dpkg-query -W -f='${Version}\n' libcudnn9-cuda-12 2>/dev/null || echo n/a)"
HW_HINT="$(yq -r '.provenance.hardware_hint // "unknown"' "$TARGET_YAML")"
HW_LINE="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "$HW_HINT")"
GCC_LINE="$(g++ --version 2>/dev/null | head -1 || echo unknown)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CUDA_ARCH="$(yq -r '.build.cmake_extra_defines.CMAKE_CUDA_ARCHITECTURES // "n/a"' "$TARGET_YAML")"
# Only annotate the CUDA compute capability for accelerated targets; a
# CPU-only target (e.g. tflite linux-x86_64) leaves it off rather than
# printing a meaningless "(sm_n/a)".
if [ "$CUDA_ARCH" != "n/a" ]; then
    HW_SUFFIX=" (sm_${CUDA_ARCH})"
else
    HW_SUFFIX=""
fi

cat > "$STAGE_DIR/BUILD_INFO.txt" <<INFO
${PKG_NAME} ${PKG_VERSION}
EdgeFirst build: ${BUILD_NUMBER}
Built: ${BUILT_AT}
Target: ${TARGET_KEY}
Hardware: ${HW_LINE}${HW_SUFFIX}
L4T: ${L4T_LINE}
JetPack metapackage: ${JETPACK_LINE}
CUDA: ${CUDA_LINE}
cuDNN: ${CUDNN_LINE}
Compiler: ${GCC_LINE}
CMake: ${CMAKE_LINE}
Upstream tag: ${UPSTREAM_TAG}
Upstream sha256: ${UPSTREAM_SHA}
Upstream source: https://github.com/${UPSTREAM_REPO}
Packaging: https://github.com/EdgeFirstAI/packaging
INFO

echo "== Stage contents =="
ls -lhR "$STAGE_DIR"

( cd "$DIST_DIR" && tar -czf "$(basename "$TARBALL")" "$(basename "$STAGE_DIR")" )
sha256_line "$TARBALL" > "$TARBALL.sha256"

echo
echo "== Done =="
ls -lh "$TARBALL" "$TARBALL.sha256"
cat "$TARBALL.sha256"
