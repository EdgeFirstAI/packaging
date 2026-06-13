# Project instructions

Guidance for AI coding assistants (GitHub Copilot, Claude Code, etc.) working in this repository.

## What this repo is

`EdgeFirstAI/packaging` produces **vendor-curated binary distributions** of a small set of ML/AI runtime libraries (ONNX Runtime, TensorFlow Lite C) for the specific platforms EdgeFirst deploys to — chiefly Jetson + JetPack. It is not a package manager and not a fork of upstream sources. There is no compiled code of its own: the repo is **Bash scripts + YAML metadata** that fetch an upstream release tarball, build it with platform-specific flags, and emit `.tar.gz` + `.deb` artifacts plus an APT repository.

The three long-form docs are the source of truth and worth reading before non-trivial work:
- `README.md` — consumer-facing install instructions.
- `TESTING.md` — build/test/release workflow for maintainers (build host setup, the six-stage pipeline, release flow, APT publishing).
- `ARCHITECTURE.md` — *why* the recipe/target split exists, naming conventions, the four-package Debian rationale, cross-platform expansion plan.

## Core mental model: recipe + target = build

A build is the cross product of one **recipe** and one **target**. Keep this line straight — it is the single most important convention:

- **Recipe** (`packages/<pkg>/recipes/<version>.yaml`) = the *what*, per upstream version. Upstream URL + SHA256 pin, patches, `build_layout` (which libs/headers/docs to collect after build), license. One recipe per upstream tag.
- **Target** (`packages/<pkg>/targets/<key>/target.yaml` + `build.sh`) = the *where/how*, per `(os, arch, accelerator)`. Build flags, parallelism, runner labels, the Debian package split, post-build test, depends/provides/conflicts.

Adding a new platform for an existing version → **add a target**, don't touch the recipe. Adding a new upstream version → **add a recipe** (and usually duplicate each target). There is intentionally **no inheritance/default-target chain** — that is a rejected anti-pattern, not a missing feature. When unsure where a value belongs: "does every target build of this upstream version need this exact value?" yes → recipe, "depends on the target" → target. (`ARCHITECTURE.md` "Where the recipe ends and the target begins".)

## Commands

```bash
# Full end-to-end build of one (recipe, target) pair. Third arg = EdgeFirst
# build number (defaults to 1; bump for re-builds at the same upstream version).
shared/run-build.sh \
    packages/onnxruntime/recipes/1.22.1.yaml \
    packages/onnxruntime/targets/linux-arm64-jp62-cuda126 \
    3

# Stage 0 alone — fast YAML/path lint, fails in seconds. Run this after
# editing any recipe or target.yaml before kicking off a ~90 min build.
shared/validate-recipe.sh \
    packages/onnxruntime/recipes/1.22.1.yaml \
    packages/onnxruntime/targets/linux-arm64-jp62-cuda126

# Override build parallelism (memory-bound on Jetson; see TESTING.md).
PARALLEL=4 shared/run-build.sh <recipe> <target_dir> <n>
```

`run-build.sh` is the orchestrator. It runs six stages in order — **validate → fetch-source → build → test → package-tarball → package-deb** — each delegating to a `shared/*.sh` script. Artifacts land in `work/<target_key>/dist/` (gitignored; nothing under `work/` is ever committed). Release/publish steps (`gh release`, `publish-apt.sh`) can be run manually (documented in `TESTING.md` "Cutting a release") or on-demand via GitHub Actions.

The same pipeline runs in CI: **`.github/workflows/release.yml`** (dispatchable "Build & Release") discovers a package's targets and fans out **`.github/workflows/build-target.yml`** (reusable wrapper around `run-build.sh`) across them. Each target's `runs-on` is read from its `target.yaml` `runs_on:` field, and an optional `build.container:` runs the build inside a Docker image — so **adding a target needs no workflow edit**. All current targets build on GitHub-hosted runners: tflite directly on `ubuntu-22.04`/`-arm`, and the ONNX CUDA target on a **native-aarch64 `ubuntu-24.04-arm-xlarge` runner inside a pinned JetPack container** (nvcc compiles `sm_87` without a GPU — no physical Jetson needed). A `publish` input gates the draft-release + APT-publish path (needs AWS/GPG/CloudFront secrets). Third-party actions are hash-pinned (Au-Zone SPS). Pass dispatch inputs through `env:` in `run:` steps, never inline `${{ }}`.

There is no unit-test suite. The "test" stage runs a per-target **post-build verification** declared in `target.yaml`'s `test:` field. Because the CUDA build runs on a GPU-less runner, the ONNX test is `shared/tests/cuda-ep-abi.sh` — a static `readelf` check that the CUDA EP links the expected cuDNN 9 / CUDA 12 SONAME majors (catches the silent ABI break without a GPU). The runtime probe `cuda-ep-present.sh` is kept for manual on-Jetson validation; tflite uses a `dlopen` smoke test.

## Conventions that will bite you if missed

- **`yq` means mikefarah's Go version**, not the Python `yq`. All scripts assume Go-yq syntax (`yq -r '.foo'`). Installing the wrong one produces confusing failures.
- **`arm64` vs `aarch64` is deliberate, not a bug.** The target *directory* uses the dpkg spelling (`targets/linux-arm64-...`, what `dpkg --print-architecture` and `deb-s3 --arch` want); the published *key* inside `target.yaml` uses the uname spelling (`linux-aarch64-...`, what consumers `uname -m` to pick a tarball). Both audiences need their own spelling — **do not "unify" them.** (`ARCHITECTURE.md` marks this IMPORTANT.)
- The directory name under `packages/` is the **published package name**, which may differ from the upstream project (`packages/tflite/` ships one library out of `tensorflow/tensorflow`).
- Recipes pin `source_sha256: PIN_ON_FIRST_FETCH` initially; `fetch-source.sh` computes and writes back the real SHA on first fetch, then cross-checks forever after. A later upstream-archive change fails the build.
- **Stages communicate via exported env vars**, not arguments: `run-build.sh` exports `SOURCE_DIR`, `RECIPE`, `TARGET_YAML`, `BUILD_NUMBER`, `DIST_DIR`, and `CONFIG` for the downstream scripts and the target `build.sh`. Shared logic (identity globals, sha256 helpers, `yq_or`, `require_cmd`) lives in `shared/lib/common.sh` — source it, don't re-implement.
- `onnxruntime` packages are **layered so CUDA is optional**. The arch-generic base lib (`libonnxruntime1.22`), `-dev`, and `-providers-shared` are built **once per arch** by CPU targets (`targets/linux-amd64` → key `linux-x86_64`, `targets/linux-arm64` → key `linux-aarch64`) and carry no CUDA linkage. The Jetson target (`linux-arm64-jp62-cuda126`) packages **only** the CUDA EP `.deb` (its tarball still bundles everything). Do not re-add base/dev/providers-shared to the Jetson target's `packaging.deb.binaries` — that recreates a `libonnxruntime1.22_arm64.deb` collision with the CPU target. x86_64+CUDA is planned follow-up (ARCHITECTURE.md open issues). `package-deb.sh` substitutes `${binary:Version}`/`${source:Version}` itself (it calls `dpkg-deb` directly, not `dpkg-gencontrol`).
- `tflite` ships **Linux x86_64 + aarch64 only** (CPU-only, CMake build of the TFLite C API — *not* bazel). macOS/Windows are intentionally absent (served by ONNX Runtime). Its library is a **flat unversioned `.so`** (no SONAME chain), so its Debian split is two packages (`libtensorflowlite-c`, `libtensorflowlite-c-dev`), not four, and its headers ship as a **nested tree** under `include/tensorflow/lite/c/` via the recipe's `headers: [{src, dest}]` form.

## Per-project rules (from global config)

- Author is **Sébastien Taylor <sebastien@au-zone.com>** — never attribute commits/docs to the AI assistant.
- Sign commits and tags with `-s`.
- Never commit local planning/scratch files; `work/`, `venv/`, `plans/`, `.notes/`, `*.local.md` are gitignored for this reason.
- Treat documentation version bumps and changelog entries as user-gated: ask before bumping a doc version or recording a changelog.
