# tflite package — scaffold

Status: **not yet wired up.** This directory is a placeholder for the next TensorFlow Lite C API release, which will be cut from this packaging repo rather than from `EdgeFirstAI/tflite-rs/releases/`.

## Current state

- `recipes/2.19.0.yaml` — recipe stub with upstream URL + `PIN_ON_FIRST_FETCH`. `build_defaults` and `build_layout` are TODO.
- No `targets/` directory yet — per-target `build.sh` + `target.yaml` get added when the pipeline goes live. Expected target keys, matching the existing `tflite-rs` release shape:
  - `linux-x86_64`
  - `linux-aarch64`
  - `macos-arm64`
  - `windows-x86_64`

## Why it's a stub today

The existing `tflite-v2.19.0` artifacts at [EdgeFirstAI/tflite-rs/releases/tag/tflite-v2.19.0](https://github.com/EdgeFirstAI/tflite-rs/releases/tag/tflite-v2.19.0) remain valid for current consumers (Rust `edgefirst-tflite`, `edgefirst-tflite-library` PyPI package, etc.). There is no value in re-publishing them under this repo. When upstream cuts a new TensorFlow release worth shipping, we'll populate the recipe and target build scripts here, build from scratch, and the new artifacts come out of `EdgeFirstAI/packaging` releases + the apt repo.

## What needs to land before this directory is functional

1. **`recipes/<ver>.yaml`** — complete `build_defaults` with bazel flags, complete `build_layout` (bazel-bin output paths, header list, license), `submodules: false`, etc.
2. **`targets/<key>/build.sh`** — per-platform bazel invocation, one each for linux-x86_64, linux-aarch64, macos-arm64, windows-x86_64.
3. **`targets/<key>/target.yaml`** — packaging definitions, including `packaging.deb.binaries` for the Linux targets (`libtensorflowlite-c2` for the SONAME-versioned main package, `libtensorflowlite-c-dev` for headers).
4. **`shared/tests/`** — at minimum a load test that opens the library via `dlopen` and resolves `TfLiteInterpreterCreate`.
5. **Decide on Windows packaging** — current `tflite-rs` ships a `.zip` for Windows, not a `.tar.gz`. The shared `package-tarball.sh` only emits `.tar.gz`; if we want `.zip` for Windows, add `package-zip.sh` and wire it into `run-build.sh` based on `target.os == "windows"`.
