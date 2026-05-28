#!/usr/bin/env bash
# run-build.sh — local build orchestrator for one (recipe, target) pair.
#
# Runs the full pipeline on a single host:
#   1. fetch upstream source (verify SHA, extract, apply patches)
#   2. build with target-specific flags
#   3. test (if declared in target.yaml)
#   4. package tarball (always)
#   5. package deb (if "deb" is in target.packaging.formats)
#
# Designed for manual invocation on hosts that aren't GitHub Actions
# runners (Jetson, macOS dev box, etc.). Equivalent in behavior to the
# build-target.yml reusable workflow, just driven by a developer shell.
#
# Usage:
#   shared/run-build.sh <recipe.yaml> <target_dir> [build_number]
#
# Example:
#   shared/run-build.sh recipes/1.22.1.yaml targets/linux-arm64-jp62-cuda126 3
#
# Outputs land under:
#   <repo>/work/<target_key>/dist/
#       onnxruntime-<target_key>.tar.gz
#       onnxruntime-<target_key>.tar.gz.sha256
#       deb/*.deb
#       deb/*.deb.sha256

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    cat <<USAGE >&2
usage: $0 <recipe.yaml> <target_dir> [build_number]
example: $0 recipes/1.22.1.yaml targets/linux-arm64-jp62-cuda126 3

The build_number defaults to 1. Increment it for re-builds of the same
upstream version (e.g., to enable a flag, fix a packaging bug). It is
stamped into BUILD_INFO.txt and the package version string.
USAGE
    exit 2
fi

RECIPE_ARG="$1"
TARGET_ARG="$2"
BUILD_NUMBER="${3:-1}"

# Resolve to absolute paths up front so subsequent cd's don't break refs.
RECIPE="$(cd "$(dirname "$RECIPE_ARG")" && pwd)/$(basename "$RECIPE_ARG")"
TARGET_DIR="$(cd "$TARGET_ARG" && pwd)"
TARGET_YAML="$TARGET_DIR/target.yaml"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

[ -f "$RECIPE" ] || { echo "ERROR: recipe not found: $RECIPE" >&2; exit 1; }
[ -f "$TARGET_YAML" ] || { echo "ERROR: target.yaml not found: $TARGET_YAML" >&2; exit 1; }
[ -x "$TARGET_DIR/build.sh" ] || { echo "ERROR: $TARGET_DIR/build.sh missing or not executable" >&2; exit 1; }

command -v yq >/dev/null || {
    cat >&2 <<MSG
ERROR: yq (mikefarah's Go version) not on PATH.
Install with: sudo wget -qO /usr/local/bin/yq \\
    https://github.com/mikefarah/yq/releases/latest/download/yq_linux_\$(dpkg --print-architecture) \\
    && sudo chmod +x /usr/local/bin/yq
MSG
    exit 1
}

TARGET_KEY="$(yq -r '.key' "$TARGET_YAML")"
WORKDIR="${WORKDIR:-$REPO_ROOT/work/$TARGET_KEY}"
SOURCE_DIR="$WORKDIR/source"
DIST_DIR="$WORKDIR/dist"

cat <<HEAD
== run-build ==
recipe       : $RECIPE
target       : $TARGET_DIR
target_key   : $TARGET_KEY
build_number : $BUILD_NUMBER
workdir      : $WORKDIR

HEAD

mkdir -p "$WORKDIR"

# ---- Stage 1: fetch source ------------------------------------------------
echo "== Stage 1/5: fetch source =="
"$REPO_ROOT/shared/fetch-source.sh" "$RECIPE" "$WORKDIR"

# ---- Stage 2: build -------------------------------------------------------
echo
echo "== Stage 2/5: build =="
export SOURCE_DIR
export RECIPE
"$TARGET_DIR/build.sh"

# ---- Stage 3: test --------------------------------------------------------
echo
echo "== Stage 3/5: test =="
TEST="$(yq -r '.test' "$TARGET_YAML")"
if [ "$TEST" = "null" ] || [ -z "$TEST" ]; then
    echo "(no test declared in target.yaml — skipping)"
else
    # Defense-in-depth: test path must live under shared/ or targets/.
    case "$TEST" in
        shared/*|targets/*) ;;
        *) echo "ERROR: test path must be under shared/ or targets/: $TEST" >&2; exit 1 ;;
    esac
    bash "$REPO_ROOT/$TEST"
fi

# ---- Stage 4: package tarball --------------------------------------------
echo
echo "== Stage 4/5: package tarball =="
export TARGET_YAML
export BUILD_NUMBER
export DIST_DIR
"$REPO_ROOT/shared/package-tarball.sh"

# ---- Stage 5: package deb (optional) -------------------------------------
echo
echo "== Stage 5/5: package deb =="
FORMATS="$(yq -r '.packaging.formats | join(",")' "$TARGET_YAML")"
case ",$FORMATS," in
    *,deb,*)
        if command -v dpkg-deb >/dev/null; then
            "$REPO_ROOT/shared/package-deb.sh"
        else
            echo "WARN: dpkg-deb not on PATH — skipping deb packaging (this host can't build .deb)" >&2
            echo "      To build .debs here, install dpkg-dev: sudo apt install dpkg-dev" >&2
        fi
        ;;
    *)
        echo "(deb not in formats — skipping)"
        ;;
esac

# ---- Summary --------------------------------------------------------------
cat <<DONE

== All done ==
Artifacts:
$(ls -1 "$DIST_DIR"/*.tar.gz "$DIST_DIR"/*.sha256 2>/dev/null | sed 's/^/  /' || true)
$(ls -1 "$DIST_DIR"/deb/*.deb "$DIST_DIR"/deb/*.sha256 2>/dev/null | sed 's/^/  /' || true)

To attach these to a release on EdgeFirstAI/packaging:

  # Create the release shell once (any host, run once per release):
  gh release create <tag> --repo EdgeFirstAI/packaging \\
      --draft --title "EdgeFirst ONNX Runtime <tag>" --notes "..."

  # On each build host, upload the produced artifacts:
  gh release upload <tag> --repo EdgeFirstAI/packaging \\
      $DIST_DIR/*.tar.gz \\
      $DIST_DIR/*.sha256 \\
      $DIST_DIR/deb/*.deb \\
      $DIST_DIR/deb/*.sha256

  # When all expected assets are attached:
  gh release edit <tag> --repo EdgeFirstAI/packaging --draft=false

DONE
