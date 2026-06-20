# tflite package

Portable builds of [TensorFlow Lite](https://github.com/tensorflow/tensorflow/tree/master/tensorflow/lite), packaged for the Linux platforms EdgeFirst targets. Two shared libraries are shipped:

- **C API** — `libtensorflowlite_c.so` (flat, unversioned), built from upstream's self-contained `tensorflow/lite/c/` CMake project.
- **C++ runtime** — `libtensorflow-lite.so.2.19.0` (versioned SONAME), built from `tensorflow/lite/` with a small CMake patch (see below).

Both are built with **XNNPACK enabled**. The consumers load these via `dlopen` (the [`edgefirst-tflite`](https://github.com/EdgeFirstAI/tflite-rs) Rust crate, the `edgefirst-tflite-library` PyPI package, and the Studio profiler) — nothing links them at compile time. The C++ lib exists primarily so `edgefirst-tflite`'s discovery has a versioned `libtensorflow-lite.so.2.19.0` to fall back to, matching the NXP BSP naming.

These C API builds reproduce — under this packaging repo's conventions — the artifacts historically published at [`EdgeFirstAI/tflite-rs/releases`](https://github.com/EdgeFirstAI/tflite-rs/releases/tag/tflite-v2.19.0), **except XNNPACK is now ON** (the profiler's default CPU path is the XNNPACK delegate). New releases are cut from here.

## Targets

| Target key | Directory | Arch | Runner | Notes |
|---|---|---|---|---|
| `linux-x86_64` | `targets/linux-amd64/` | amd64 | `ubuntu-22.04-xlarge` | CPU-only, any same-ABI x86-64 Linux |
| `linux-aarch64` | `targets/linux-arm64/` | arm64 | `ubuntu-22.04-arm-xlarge` | CPU-only, any same-ABI aarch64 Linux (Jetson, Pi, ARM servers) |

The `-xlarge` runners are used from the start: building both libraries is memory-hungry and the C++ shared-object link can OOM a standard ~7 GB runner. The 22.04 image family preserves the glibc 2.35 deployment baseline.

macOS and Windows are **not** provided here — those platforms are well served by ONNX Runtime in EdgeFirst deployments. The `tflite-rs` release additionally shipped `macos-arm64` and `windows-x86_64`; if those are ever needed from this repo, see `ARCHITECTURE.md` "Cross-platform packaging".

## Build system

CMake, **not** bazel. The per-target `build.sh` builds both projects and stages both libraries into `_build/` (the single `build_layout.output_dir`):

```bash
# C API -> libtensorflowlite_c.so
cmake -S tensorflow/lite/c -B _build \
    -DCMAKE_BUILD_TYPE=Release \
    -DTFLITE_C_BUILD_SHARED_LIBS=ON \
    -DTFLITE_ENABLE_XNNPACK=ON
cmake --build _build --config Release --parallel 8

# C++ -> libtensorflow-lite.so.2.19.0 (+ libtensorflow-lite.so)
cmake -S tensorflow/lite -B _build_cpp \
    -DCMAKE_BUILD_TYPE=Release \
    -DTFLITE_BUILD_SHARED_LIB=ON \
    -DTFLITE_ENABLE_XNNPACK=ON
cmake --build _build_cpp --config Release --parallel 8 --target tensorflow-lite
# build.sh then copies _build_cpp/libtensorflow-lite.so* into _build/
```

### The C++ shared-library patch

Upstream `tensorflow/lite/CMakeLists.txt` at v2.19.0 only builds the full C++ library as a static `.a` and has no shared-lib option. `patches/2.19.0/0001-cmake-shared-cpp-lib.patch` (applied by `shared/fetch-source.sh`) adds a `TFLITE_BUILD_SHARED_LIB` option that:

- builds `tensorflow-lite` as `SHARED`;
- restricts exported symbols to the TFLite C/C++ API via the in-tree `tflite_version_script.lds` (so abseil/protobuf/XNNPACK are not re-exported), with `-Wl,--no-undefined`;
- sets `VERSION`/`SOVERSION` to `2.19.0`, producing `libtensorflow-lite.so.2.19.0` — the exact versioned name `edgefirst-tflite` discovery probes.

The patch is a no-op unless `-DTFLITE_BUILD_SHARED_LIB=ON` is passed. It mirrors the equivalent changes carried in NXP's `tensorflow-imx` fork.

## Layout notes

- **Two Debian packages, no `-dev`.** The split is `libtensorflowlite-c` (the C API `.so`) and `libtensorflow-lite2.19` (the versioned C++ `.so` chain; the soversion is embedded in the package name, mirroring `libonnxruntime1.22`, so a future soversion can co-install). **No `-dev` package is shipped** — EdgeFirst consumes TFLite via `dlopen`, not at compile time.
- **Headers.** Only the four public C API headers ship, inside the release tarball under `include/tensorflow/lite/c/` (preserving the path consumers `#include`). Since TF 2.14 the canonical header content lives under `tensorflow/lite/core/c/`; the recipe stages that content at the historical `tensorflow/lite/c/` path via the `headers: [{src, dest}]` form. **No C++ headers** are packaged — no consumer links the C++ API.
- **SONAME.** The C API `.so` is flat/unversioned (TFLite's C API CMake sets no SONAME chain). The C++ `.so` is versioned at build time by the patch's `SOVERSION`; the recipe does **not** use the `version_soname` post-build helper.

## Building

```bash
shared/run-build.sh \
    packages/tflite/recipes/2.19.0.yaml \
    packages/tflite/targets/linux-amd64 \
    1
```

See [TESTING.md](../../TESTING.md) for the full build/test/release workflow and [ARCHITECTURE.md](../../ARCHITECTURE.md) for the recipe/target design.
