# tflite package

Portable builds of the [TensorFlow Lite C API](https://github.com/tensorflow/tensorflow/tree/master/tensorflow/lite/c) (`libtensorflowlite_c`), packaged for the Linux platforms EdgeFirst targets.

These builds reproduce — under this packaging repo's conventions — the artifacts historically published at [`EdgeFirstAI/tflite-rs/releases`](https://github.com/EdgeFirstAI/tflite-rs/releases/tag/tflite-v2.19.0), which remain valid for existing consumers (`edgefirst-tflite` Rust crate, `edgefirst-tflite-library` PyPI package). New releases are cut from here.

## Targets

| Target key | Directory | Arch | Notes |
|---|---|---|---|
| `linux-x86_64` | `targets/linux-amd64/` | amd64 | CPU-only, any same-ABI x86-64 Linux |
| `linux-aarch64` | `targets/linux-arm64/` | arm64 | CPU-only, any same-ABI aarch64 Linux (Jetson, Pi, ARM servers) |

macOS and Windows are **not** provided here — those platforms are well served by ONNX Runtime in EdgeFirst deployments. The `tflite-rs` release additionally shipped `macos-arm64` and `windows-x86_64`; if those are ever needed from this repo, see `ARCHITECTURE.md` "Cross-platform packaging".

## Build system

CMake, **not** bazel. Upstream ships a self-contained CMake project at `tensorflow/lite/c/` that builds just the C API. The per-target `build.sh` runs the equivalent of:

```bash
cmake -S tensorflow/lite/c -B _build \
    -DCMAKE_BUILD_TYPE=Release \
    -DTFLITE_C_BUILD_SHARED_LIBS=ON \
    -DTFLITE_ENABLE_XNNPACK=OFF
cmake --build _build --config Release --parallel 2
```

(Only the full TensorFlow build uses bazel; the C API CMake project does not, so none of the bazel-specific `build_layout` concerns apply.)

## Layout notes

- **Flat, unversioned `.so`.** TFLite's CMake sets no SONAME minor-version chain — there is a single `libtensorflowlite_c.so`, no symlinks. The Debian split is therefore two packages, not four: `libtensorflowlite-c` (the library) and `libtensorflowlite-c-dev` (headers). Because the library is unversioned, the runtime `.so` doubles as the linker target, so `-dev` ships only headers.
- **Nested include tree.** The four public headers ship at `include/tensorflow/lite/c/` (preserving the path consumers `#include`), not flattened. Since TF 2.14 the canonical header content lives under `tensorflow/lite/core/c/`; the recipe stages that content at the historical `tensorflow/lite/c/` path via the `headers: [{src, dest}]` form. See `recipes/2.19.0.yaml`.

## Building

```bash
shared/run-build.sh \
    packages/tflite/recipes/2.19.0.yaml \
    packages/tflite/targets/linux-amd64 \
    1
```

See [TESTING.md](../../TESTING.md) for the full build/test/release workflow and [ARCHITECTURE.md](../../ARCHITECTURE.md) for the recipe/target design.
