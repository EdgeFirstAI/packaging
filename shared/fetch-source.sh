#!/usr/bin/env bash
# fetch-source.sh — fetch an upstream tarball per recipe, verify its
# SHA256, extract, and apply any patches the recipe lists.
#
# Usage: fetch-source.sh <recipe.yaml> <dest_dir>
#
# Writes back the computed SHA256 to the recipe if it was unpinned
# ("PIN_ON_FIRST_FETCH") — the operator then commits that change so
# subsequent fetches verify rather than trust-on-first-use.
#
# Requires: yq (mikefarah/yq, NOT the python one), curl, sha256sum, tar, patch.

set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <recipe.yaml> <dest_dir>" >&2
    exit 2
fi

RECIPE="$1"
DEST="$2"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_cmd yq
require_cmd curl
require_sha256

URL="$(yq -r '.upstream.source_url' "$RECIPE")"
EXPECTED_SHA="$(yq -r '.upstream.source_sha256' "$RECIPE")"
TAG="$(yq -r '.upstream.tag' "$RECIPE")"
PATCH_COUNT="$(yq -r '.patches | length' "$RECIPE")"

[ "$URL" != "null" ] && [ -n "$URL" ] || { echo "ERROR: upstream.source_url missing from $RECIPE" >&2; exit 1; }

echo "== fetch-source =="
echo "recipe : $RECIPE"
echo "tag    : $TAG"
echo "url    : $URL"
echo "dest   : $DEST"
echo "patches: $PATCH_COUNT"
echo

mkdir -p "$DEST"
TARBALL="$DEST/upstream-source.tar.gz"

if [ -f "$TARBALL" ]; then
    echo "Tarball already present, verifying SHA before reuse..."
else
    curl -fL --retry 3 --retry-delay 5 -o "$TARBALL" "$URL"
fi

ACTUAL_SHA="$(sha256_hex "$TARBALL")"
echo "computed sha256: $ACTUAL_SHA"

if [ "$EXPECTED_SHA" = "PIN_ON_FIRST_FETCH" ] || [ "$EXPECTED_SHA" = "null" ] || [ -z "$EXPECTED_SHA" ]; then
    # First-time pin: write back into the recipe and warn the operator.
    # Guard: if the recipe file is not writable (e.g., a CI checkout with
    # read-only permissions), fail with an actionable message instead of
    # a cryptic "permission denied" from yq.
    if [ ! -w "$RECIPE" ]; then
        echo "ERROR: source_sha256 is unpinned (PIN_ON_FIRST_FETCH) but the recipe" >&2
        echo "  file is not writable: $RECIPE" >&2
        echo "  Fix: set source_sha256 to the SHA256 of the downloaded tarball, or" >&2
        echo "  make the recipe file writable so fetch-source.sh can pin it." >&2
        echo "  Computed SHA256: $ACTUAL_SHA" >&2
        exit 1
    fi
    yq -i ".upstream.source_sha256 = \"$ACTUAL_SHA\"" "$RECIPE"
    echo "WARN: source_sha256 was unpinned in $RECIPE." >&2
    echo "WARN: Pinned to $ACTUAL_SHA. Commit this change so subsequent fetches verify." >&2
elif [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "ERROR: SHA mismatch!" >&2
    echo "  expected: $EXPECTED_SHA" >&2
    echo "  got:      $ACTUAL_SHA" >&2
    echo "  upstream archive may have changed (GitHub recompresses on certain conditions)" >&2
    exit 1
else
    echo "sha256 verified against recipe pin"
fi

# GitHub source archives unpack to <repo>-<version>/; --strip-components=1
# drops that layer so $SRC_DIR has the source tree directly.
echo
echo "== extract =="
SRC_DIR="$DEST/source"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
# If tar fails (truncated or corrupt archive), remove the tarball so the next
# invocation re-downloads rather than reusing the bad file, then abort.
if ! tar -xzf "$TARBALL" -C "$SRC_DIR" --strip-components=1; then
    echo "ERROR: tar extraction failed (truncated or corrupt download?)" >&2
    echo "  Removing cached tarball so the next run re-downloads it." >&2
    rm -f "$TARBALL"
    rm -rf "$SRC_DIR"
    exit 1
fi
echo "extracted to $SRC_DIR"
echo "  $(find "$SRC_DIR" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ') top-level entries"

if [ "$PATCH_COUNT" -gt 0 ]; then
    echo
    echo "== apply patches =="
    for i in $(seq 0 $((PATCH_COUNT - 1))); do
        REL_PATH="$(yq -r ".patches[$i]" "$RECIPE")"
        ABS_PATH="$REPO_ROOT/$REL_PATH"
        [ -f "$ABS_PATH" ] || { echo "ERROR: patch not found: $ABS_PATH" >&2; exit 1; }
        echo "applying $REL_PATH"
        ( cd "$SRC_DIR" && patch -p1 < "$ABS_PATH" )
    done
fi

{
    echo "upstream_tag=$TAG"
    echo "upstream_url=$URL"
    echo "upstream_sha256=$ACTUAL_SHA"
    echo "recipe=$(realpath --relative-to="$REPO_ROOT" "$RECIPE" 2>/dev/null || echo "$RECIPE")"
    echo "patches_applied=$PATCH_COUNT"
    echo "fetched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DEST/SOURCE_INFO.txt"

echo
echo "== done =="
echo "source ready at: $SRC_DIR"
echo "info file:       $DEST/SOURCE_INFO.txt"
