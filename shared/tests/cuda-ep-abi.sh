#!/usr/bin/env bash
# cuda-ep-abi.sh — GPU-free post-build verification for CUDA-enabled ORT.
#
# The CUDA build runs in a JetPack container on a GPU-less aarch64 CI runner,
# so we cannot instantiate a CUDA session to validate at runtime. Instead we
# statically verify the freshly-built CUDA execution-provider plugin:
#
#   1. the main library, the providers-shared framework, and the CUDA EP .so
#      all exist where build_layout expects them; and
#   2. the CUDA EP links the expected accelerator SONAME *majors* — a wrong
#      cuDNN or CUDA major (the classic silent ABI break that a successful
#      compile sails past) shows up here as a missing NEEDED entry, with no
#      GPU required.
#
# Full runtime CUDAExecutionProvider validation still requires a real GPU; the
# on-hardware probe lives in shared/tests/cuda-ep-present.sh for manual use on
# a Jetson.
#
# Inputs (env):
#   SOURCE_DIR  — extracted ORT source
#   BUILD_DIR   — defaults to $SOURCE_DIR/build/Linux/Release

set -euo pipefail

: "${SOURCE_DIR:?SOURCE_DIR not set}"
BUILD_DIR="${BUILD_DIR:-$SOURCE_DIR/build/Linux/Release}"

command -v readelf >/dev/null || { echo "ERROR: readelf not on PATH (install binutils)" >&2; exit 1; }

MAIN="$BUILD_DIR/libonnxruntime.so"
SHARED_EP="$BUILD_DIR/libonnxruntime_providers_shared.so"
CUDA_EP="$BUILD_DIR/libonnxruntime_providers_cuda.so"

echo "== cuda-ep-abi: artifact presence =="
for f in "$MAIN" "$SHARED_EP" "$CUDA_EP"; do
    if [ -f "$f" ]; then
        echo "  ok: $(basename "$f")"
    else
        echo "ERROR: expected build artifact missing: $f" >&2
        exit 1
    fi
done

# NEEDED SONAMEs recorded in the CUDA EP's dynamic section.
NEEDED="$(readelf -d "$CUDA_EP" | awk -F'[][]' '/NEEDED/{print $2}')"
echo
echo "== cuda-ep-abi: CUDA EP NEEDED libraries =="
echo "$NEEDED" | sed 's/^/  /'

# Hard requirements: the ABI-critical accelerator majors. A JetPack 6.x build
# must link CUDA 12 (libcudart.so.12) and cuDNN 9 (libcudnn.so.9). A mismatch
# here is exactly the silent break this check exists to catch.
REQUIRED="libcudart.so.12 libcudnn.so.9"
# Also-expected (reported, not enforced — ORT's exact link set shifts between
# versions and some may be pulled in transitively rather than as direct NEEDED).
EXPECTED_EXTRA="libcublas.so.12 libcublasLt.so.12 libcufft.so.11"

echo
echo "== cuda-ep-abi: ABI major checks =="
missing=0
for s in $REQUIRED; do
    if grep -qx "$s" <<<"$NEEDED"; then
        echo "  ok (required):   $s"
    else
        echo "  MISSING (required): $s" >&2
        missing=1
    fi
done
for s in $EXPECTED_EXTRA; do
    if grep -qx "$s" <<<"$NEEDED"; then
        echo "  ok (expected):   $s"
    else
        echo "  note: $s not a direct NEEDED entry (ok if linked transitively)"
    fi
done

if [ "$missing" -ne 0 ]; then
    echo >&2
    echo "FAIL: CUDA EP is missing a required accelerator SONAME major — the build" >&2
    echo "  links a CUDA/cuDNN ABI that does not match the JetPack 6.x target." >&2
    exit 1
fi

# Base-lib CUDA-absence check. The base package (libonnxruntime1.22) and the
# providers-shared package are meant to install/run on a CUDA-less host, so the
# main library and the EP-loader framework must NOT carry a direct NEEDED link
# to any CUDA/cuDNN SONAME. ORT's design keeps CUDA confined to the CUDA EP
# plugin; this asserts that invariant so the four-package split's promise
# ("apt install libonnxruntime1.22 works without CUDA") is verified, not assumed.
echo
echo "== cuda-ep-abi: base-lib CUDA-absence check =="
base_leak=0
for lib in "$MAIN" "$SHARED_EP"; do
    leaked="$(readelf -d "$lib" | awk -F'[][]' '/NEEDED/{print $2}' \
        | grep -E '^lib(cudart|cudnn|cublas|cublasLt|cufft|cuda)\.' || true)"
    if [ -n "$leaked" ]; then
        echo "  LEAK in $(basename "$lib"):" >&2
        echo "$leaked" | sed 's/^/    /' >&2
        base_leak=1
    else
        echo "  ok (no direct CUDA NEEDED): $(basename "$lib")"
    fi
done
if [ "$base_leak" -ne 0 ]; then
    echo >&2
    echo "FAIL: a base/providers-shared library directly links a CUDA SONAME." >&2
    echo "  libonnxruntime1.22 / libonnxruntime-providers-shared must install and" >&2
    echo "  run on a CUDA-less host; a direct NEEDED CUDA link breaks that promise." >&2
    exit 1
fi

echo
echo "OK: CUDA EP links the expected CUDA 12 / cuDNN 9 majors; base libs are CUDA-free."
