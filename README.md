# EdgeFirstAI/packaging

Vendor-curated binary distributions of a small set of ML/AI runtime libraries, packaged specifically for the deployment and development platforms EdgeFirst targets and that aren't already easy to install from upstream or the platform's BSP.

This is **not** a general-purpose package manager. It is a convenience layer: pre-built packages that save EdgeFirst deployments and engineers the effort of compiling from source. Updates land at a slower cadence than upstream — we pick stable points and ship them for a long time. If you'd rather build the libraries yourself, or your platform's BSP already provides what you need, you don't need this repository at all.

Distributions are published in two forms:

1. **APT repository** at `https://repo.edgefirst.ai/apt/` for Debian, Ubuntu, or JetPack hosts — one-line install via `apt`.
2. **GitHub Releases** at [`EdgeFirstAI/packaging/releases`](https://github.com/EdgeFirstAI/packaging/releases) — immutable per-release tarballs and `.deb` files for offline/airgapped installs, direct downloads, non-apt platforms.

## Packages

### onnxruntime

Portable builds of [Microsoft ONNX Runtime](https://github.com/microsoft/onnxruntime).

**Gap filled.** Microsoft's official ORT binaries either skip the platforms EdgeFirst deploys to entirely (no Jetson CUDA build is published) or require host OS versions newer than our deployment baseline (the official Linux GPU build assumes a glibc newer than `manylinux2014` provides, ruling out a large swath of long-support deployment OSes). These EdgeFirst builds target the platforms we ship, built against a deployment-baseline ABI.

Supported targets:

| Target key | Hardware | OS baseline | Execution Providers |
|---|---|---|---|
| `linux-x86_64` | Any x86-64 Linux | Ubuntu 22.04 / glibc 2.35 | CPU |
| `linux-aarch64` | Any aarch64 Linux (ARM servers, Pi, non-CUDA Jetson) | Ubuntu 22.04 / glibc 2.35 | CPU |
| `linux-aarch64-jp62-cuda126` | Jetson Orin Nano Super / Orin NX | L4T R36.4.x / JetPack 6.2 | CUDA 12.6 |

**The packages are layered so CUDA is optional.** The base library (`libonnxruntime1.22`) and the execution-provider loader (`libonnxruntime-providers-shared`) carry **no CUDA linkage** and are built once per architecture — so `apt install libonnxruntime1.22` works on any x86-64 or aarch64 host, with or without CUDA. The CUDA execution provider ships as a separate package (`libonnxruntime-providers-cuda-jetson-jp62`) that layers on top for Jetson; installing it pulls in the shared base. No `-dev`/headers package is shipped (consumption is via `dlopen`; headers are in the tarball). A desktop/datacenter x86-64 CUDA execution provider is planned (see [ARCHITECTURE.md](ARCHITECTURE.md) open issues).

### tflite

Portable builds of the [TensorFlow Lite C API](https://github.com/tensorflow/tensorflow/tree/master/tensorflow/lite/c).

**Gap filled.** TensorFlow Lite is generally provided by the embedded BSPs we target (NXP i.MX, etc.) but not on Jetson or desktop workstations. Where third-party binary releases do exist for those platforms, they typically wrap the C++ library and don't expose the C API that `edgefirst-tflite` consumes. These builds provide the C API directly across the platforms EdgeFirst uses for both deployment and engineering.

Supported targets:

| Target key | Hardware | Build | Library |
|---|---|---|---|
| `linux-x86_64` | Any x86-64 Linux | CPU-only (CMake) | `libtensorflowlite_c.so` |
| `linux-aarch64` | Any aarch64 Linux (Jetson, Pi, ARM servers) | CPU-only (CMake) | `libtensorflowlite_c.so` |

These reproduce the libraries historically published at [`EdgeFirstAI/tflite-rs/releases/tflite-v2.19.0`](https://github.com/EdgeFirstAI/tflite-rs/releases/tag/tflite-v2.19.0) (still valid for existing consumers) under this repo's recipe/target conventions. macOS and Windows are not provided here — those platforms are well served by ONNX Runtime in EdgeFirst deployments. See [`packages/tflite/README.md`](packages/tflite/README.md) for details.

Additional packages and targets are added as concrete gaps are identified. If you need a target that isn't currently provided, please open an issue.

## Installation via APT (Debian / Ubuntu / JetPack)

> [!NOTE]
> The APT signing key must be uploaded to `https://repo.edgefirst.ai/apt/edgefirst-archive-keyring.gpg` before these commands work. See [TESTING.md](TESTING.md) "One-time setup: GPG signing key" for the upload step. Once the key is published, the commands below are permanent for consumers.

One-time setup of the APT repository:

```bash
# Import the EdgeFirst repository signing key
curl -fsSL https://repo.edgefirst.ai/apt/edgefirst-archive-keyring.gpg \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/edgefirst.gpg

# Add the repository to apt sources
echo "deb [signed-by=/etc/apt/keyrings/edgefirst.gpg arch=$(dpkg --print-architecture)] https://repo.edgefirst.ai/apt/ stable main" \
  | sudo tee /etc/apt/sources.list.d/edgefirst.list

sudo apt update
```

Then install whatever you need:

```bash
# ONNX Runtime, CPU only (x86-64 or aarch64) — no CUDA required
sudo apt install libonnxruntime1.22

# ONNX Runtime CUDA execution provider for Jetson Orin (JetPack 6.2).
# Pulls in libonnxruntime1.22 + libonnxruntime-providers-shared automatically.
sudo apt install libonnxruntime-providers-cuda-jetson-jp62

# TensorFlow Lite C API (x86-64 or aarch64), runtime
sudo apt install libtensorflowlite-c
```

> [!NOTE]
> **No `-dev` packages are shipped** for either library. EdgeFirst consumes
> both ONNX Runtime and TensorFlow Lite via runtime loading (`dlopen` / the
> Rust `ort` crate), so no C/C++ headers or link-time `-dev` package are
> needed. Omitting `libonnxruntime-dev` also avoids a name collision with the
> `libonnxruntime-dev` that newer distros (Ubuntu 24.04+ / Debian) ship. If
> you need headers, they are included in each release tarball under `include/`.
>
> ONNX Runtime ships a **version-specific soname** (`libonnxruntime.so.1.22`,
> not the bare `libonnxruntime.so.1`) so this older 1.22 build is only loaded
> by an explicit version lookup, never picked up generically in place of a
> newer system onnxruntime.

For ONNX Runtime, APT resolves `libonnxruntime1.22` and `libonnxruntime-providers-shared` as transitive dependencies of the CUDA provider package. CUDA/cuDNN/L4T system libraries are satisfied by JetPack or your distro's CUDA packages — the base library has no CUDA dependency, so a CUDA-less host installs only `libonnxruntime1.22`.

## Installation via GitHub Release tarball

For offline/airgapped hosts, or platforms not served by the APT repo:

```bash
TAG=onnxruntime-1.22.1-3
TARGET=linux-aarch64-jp62-cuda126
BASE=https://github.com/EdgeFirstAI/packaging/releases/download/$TAG

# Download and verify
wget $BASE/onnxruntime-$TARGET.tar.gz
wget $BASE/onnxruntime-$TARGET.tar.gz.sha256
sha256sum -c onnxruntime-$TARGET.tar.gz.sha256

# Extract
tar -xzf onnxruntime-$TARGET.tar.gz
cd onnxruntime-*-edgefirst*-$TARGET

# Make the libraries discoverable
export LD_LIBRARY_PATH="$PWD/lib:${LD_LIBRARY_PATH:-}"
# Or, if your consumer uses dlopen-based loading (e.g., the Rust ort crate),
# point it at the version-specific soname (no unversioned libonnxruntime.so is
# shipped — see the packaging note above):
export ORT_DYLIB_PATH="$PWD/lib/libonnxruntime.so.1.22"
```

## Installation via direct .deb download

If APT is available but you'd rather pin to a specific release without adding the repo:

```bash
TAG=onnxruntime-1.22.1-3
ARCH=arm64
BASE=https://github.com/EdgeFirstAI/packaging/releases/download/$TAG

for pkg in libonnxruntime1.22 libonnxruntime-providers-shared \
           libonnxruntime-providers-cuda-jetson-jp62; do
    wget $BASE/${pkg}_*${ARCH}.deb
done
sudo apt install ./libonnxruntime*.deb
```

## Tarball contents

Each `<package>-<target>.tar.gz` unpacks into a directory of the form `<package>-<ver>-edgefirst<n>-<target>/`, containing:

| Path | Contents |
|---|---|
| `lib/` | Shared libraries (SONAME chain preserved where applicable) |
| `include/` | C/C++ API headers |
| `LICENSE` | Upstream license |
| `ThirdPartyNotices.txt` | If upstream ships one |
| `BUILD_INFO.txt` | Toolchain + source provenance |

## Debian package layout

For libraries with execution-provider plugins (ONNX Runtime), releases ship these `.deb` files per target:

| Package | Contents | Approx. size |
|---|---|---|
| `lib<name><soname>` | Main library + SONAME symlinks. No accelerator linkage. | tens of MB |
| `lib<name>-providers-shared` | EP loader framework. | <1 MB |
| `lib<name>-providers-<ep>-<target>` | EP plugin, tied to a specific accelerator version + sm_arch. | varies |

No `-dev` package is shipped (consumption is `dlopen`-only; headers ride in the tarball). EP-plugin packages use `Provides:` and `Conflicts:` so multiple EP variants for the same library coexist as separate `.deb` files but only one is installed at a time on a given host. For libraries without plugins (TensorFlow Lite C), the split collapses to a single `lib<name>` runtime package.

## Tag and version scheme

Releases are tagged `<package>-<upstream_ver>-<build_n>`, e.g. `onnxruntime-1.22.1-3`. The build number increments when packaging or compilation flags change without an upstream version bump.

## Integrity verification

Each archive has a `.sha256` sidecar:

```bash
sha256sum -c onnxruntime-linux-aarch64-jp62-cuda126.tar.gz.sha256
sha256sum -c libonnxruntime1.22_1.22.1-edgefirst3_arm64.deb.sha256
```

`BUILD_INFO.txt` (inside each tarball, and at `/usr/share/doc/<pkg>/BUILD_INFO.txt` for installed Debian packages) records the upstream tag, upstream source tarball SHA256, build host toolchain versions, and packaging commit.

## License

Build scripts and packaging metadata in this repository: MIT.

Each upstream library carries its own license, distributed inside the package — see `LICENSE` (and `ThirdPartyNotices.txt` where applicable) in each tarball or under `/usr/share/doc/<pkg>/copyright` for installed Debian packages.

---

For build, test, and release workflow documentation, see [TESTING.md](TESTING.md). For the design conventions of the recipe/target split, the package naming rules, and the four-package Debian layout rationale, see [ARCHITECTURE.md](ARCHITECTURE.md).
