# EdgeFirstAI/packaging

EdgeFirst's catch-all binary distribution repository. Portable builds of
ML/AI runtime libraries packaged for platforms upstream projects don't
ship binaries for: NVIDIA Jetson, additional Linux variants, macOS, Windows.

Distributions are published in two forms:

1. **APT repository** at `https://repo.edgefirst.ai/apt/` — for Debian /
   Ubuntu / JetPack hosts, one-line install via `apt`.
2. **GitHub Releases** at
   [`EdgeFirstAI/packaging/releases`](https://github.com/EdgeFirstAI/packaging/releases) —
   immutable per-release tarballs and `.deb` files for offline / airgapped
   installs, direct downloads, non-apt platforms.

## Packages

### onnxruntime

Portable builds of [Microsoft ONNX Runtime](https://github.com/microsoft/onnxruntime).

Supported targets:

| Target key | Hardware | OS | Execution Providers |
|---|---|---|---|
| `linux-aarch64-jp62-cuda126` | Jetson Orin Nano Super / Orin NX | L4T R36.4.7 / JetPack 6.2 | CPU, CUDA 12.6 |

### tflite

Portable builds of the [TensorFlow Lite C API](https://github.com/tensorflow/tensorflow/tree/master/tensorflow/lite/c).

*Scaffold only — packaging is not yet wired up in this repo.* Current
binaries for `tflite-v2.19.0` remain available at
[`EdgeFirstAI/tflite-rs/releases/tflite-v2.19.0`](https://github.com/EdgeFirstAI/tflite-rs/releases/tag/tflite-v2.19.0).
The next release will be cut from this repo.

---

Additional packages/targets are added as gaps are identified. If you need
a target that isn't currently provided, please open an issue.

## Installation via APT (Debian / Ubuntu / JetPack)

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
# ONNX Runtime for Jetson Orin (JetPack 6.2, CUDA 12.6)
sudo apt install libonnxruntime-providers-cuda-jetson-jp62

# (Headers, for compiling against ORT)
sudo apt install libonnxruntime-dev
```

APT resolves `libonnxruntime1.22` and `libonnxruntime-providers-shared`
as transitive dependencies. CUDA/cuDNN/L4T system libraries are
satisfied by JetPack or your distro's CUDA packages.

## Installation via GitHub Release tarball

For offline / airgapped hosts, or platforms not served by the APT repo:

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
# Or, if your consumer uses dlopen-based loading (e.g., the Rust ort crate):
export ORT_DYLIB_PATH="$PWD/lib/libonnxruntime.so"
```

## Installation via direct .deb download

If APT is available but you'd rather pin to a specific release without
adding the repo:

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

Each `<package>-<target>.tar.gz` unpacks into a directory:

```
<package>-<ver>-edgefirst<n>-<target>/
├── lib/                                   shared libraries (with SONAME chain)
├── include/                               C/C++ API headers
├── LICENSE
├── ThirdPartyNotices.txt                  (if upstream ships one)
└── BUILD_INFO.txt                         toolchain + source provenance
```

## Debian package layout

For libraries with execution-provider plugins (ONNX Runtime), releases
ship up to four `.deb` files per target:

| Package | Contents | Approx. size |
|---|---|---|
| `lib<name><soname>` | Main library + SONAME symlinks. No accelerator linkage. | tens of MB |
| `lib<name>-dev` | Headers + linker symlinks. Needed only to compile against the library. | <1 MB |
| `lib<name>-providers-shared` | EP loader framework. | <1 MB |
| `lib<name>-providers-<ep>-<target>` | EP plugin, tied to a specific accelerator version + sm_arch. | varies |

EP-plugin packages use `Provides:` + `Conflicts:` so multiple EP variants
for the same library coexist as separate `.deb` files but only one is
installed at a time on a given host. For libraries without plugins
(TensorFlow Lite C), the split collapses to just `lib<name><soname>` +
`lib<name>-dev`.

## Tag and version scheme

Releases are tagged `<package>-<upstream_ver>-<build_n>`, e.g.
`onnxruntime-1.22.1-3`. The build number increments when packaging or
compilation flags change without an upstream version bump.

## Integrity verification

Each archive has a `.sha256` sidecar:

```bash
sha256sum -c onnxruntime-linux-aarch64-jp62-cuda126.tar.gz.sha256
sha256sum -c libonnxruntime1.22_1.22.1-edgefirst3_arm64.deb.sha256
```

`BUILD_INFO.txt` (inside each tarball, and at
`/usr/share/doc/<pkg>/BUILD_INFO.txt` for installed Debian packages)
records the upstream tag, upstream source tarball SHA256, build host
toolchain versions, and packaging commit.

## License

Build scripts and packaging metadata in this repository: MIT.

Each upstream library carries its own license, distributed inside the
package — see `LICENSE` (and `ThirdPartyNotices.txt` where applicable)
in each tarball or under `/usr/share/doc/<pkg>/copyright` for installed
Debian packages.

---

For build, test, and release workflow documentation, see
[TESTING.md](TESTING.md).

For the design conventions of the recipe/target split, the package
naming rules, and the four-package Debian layout rationale, see
[ARCHITECTURE.md](ARCHITECTURE.md).
