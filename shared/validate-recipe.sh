#!/usr/bin/env bash
# validate-recipe.sh — fast-fail pre-flight check for a recipe + target pair.
#
# Runs before fetch-source.sh so operators learn about YAML or path problems
# in seconds rather than after a 30-90 minute build.
#
# Usage:
#   shared/validate-recipe.sh <recipe.yaml> <target_dir>
#
# Exit 0 = inputs look valid; proceed with the build.
# Exit 1 = one or more errors found; fix before re-running.
#
# Checks performed:
#   Recipe:
#     1. Required scalar fields are present and non-null
#     2. source_url is non-empty
#     3. source_sha256 is either a 64-hex-char SHA256 or PIN_ON_FIRST_FETCH
#     4. build_layout.output_dir contains only allowed placeholders (${config})
#     5. build_layout.libraries.main is a non-empty non-null string
#     6. build_layout.version_from is either "tag" or "file:<path>"
#     7. patches[] entries reference files that actually exist under REPO_ROOT
#
#   Target:
#     8. Required scalar fields are present and non-null
#     9. arch is one of the known values (arm64, amd64)
#    10. test path (if declared) begins with shared/ or targets/ and the file exists
#    11. packaging.formats contains at least one known format (tarball, deb, zip)
#    12. If "deb" is in formats, packaging.deb.binaries[] entries each have
#        required fields (name, contents)
#
#   Cross-check:
#   13. If target arch has a known triplet (arm64 -> aarch64-linux-gnu, etc.),
#       report it so the operator can verify it matches the build host.
#
# This script intentionally does NOT require the source tree to be present
# (no network access, no download). It only reads local YAML and local files.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <recipe.yaml> <target_dir>" >&2
    echo "example: $0 packages/onnxruntime/recipes/1.22.1.yaml packages/onnxruntime/targets/linux-arm64-jp62-cuda126" >&2
    exit 2
fi

RECIPE_ARG="$1"
TARGET_ARG="$2"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

RECIPE="$(cd "$(dirname "$RECIPE_ARG")" && pwd)/$(basename "$RECIPE_ARG")"
TARGET_DIR="$(cd "$TARGET_ARG" && pwd)"
TARGET_YAML="$TARGET_DIR/target.yaml"

ERRORS=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

err() {
    echo "  ERROR: $*" >&2
    ERRORS=$((ERRORS + 1))
}

warn() {
    echo "  WARN:  $*" >&2
}

check_field() {
    # check_field <label> <value>
    # Fails if value is empty or the string "null".
    local label="$1" val="$2"
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        err "$label is missing or null"
    fi
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

[ -f "$RECIPE" ] || { echo "ERROR: recipe not found: $RECIPE" >&2; exit 1; }
[ -f "$TARGET_YAML" ] || { echo "ERROR: target.yaml not found: $TARGET_YAML" >&2; exit 1; }
[ -x "$TARGET_DIR/build.sh" ] || { err "$TARGET_DIR/build.sh missing or not executable"; }

if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: yq (mikefarah's Go version) not on PATH — cannot validate YAML." >&2
    exit 1
fi

echo "== validate-recipe =="
echo "recipe  : $RECIPE"
echo "target  : $TARGET_YAML"
echo

# ---------------------------------------------------------------------------
# Section 1: Recipe checks
# ---------------------------------------------------------------------------

echo "-- recipe --"

UPSTREAM_REPO="$(yq -r '.upstream.repo // ""' "$RECIPE")"
UPSTREAM_TAG="$(yq -r '.upstream.tag // ""' "$RECIPE")"
UPSTREAM_URL="$(yq -r '.upstream.source_url // ""' "$RECIPE")"
UPSTREAM_SHA="$(yq -r '.upstream.source_sha256 // ""' "$RECIPE")"

check_field "upstream.repo" "$UPSTREAM_REPO"
check_field "upstream.tag" "$UPSTREAM_TAG"

# Check 2: source_url
if [ -z "$UPSTREAM_URL" ] || [ "$UPSTREAM_URL" = "null" ]; then
    err "upstream.source_url is missing or null"
elif ! echo "$UPSTREAM_URL" | grep -qE '^https?://'; then
    err "upstream.source_url does not look like a URL: $UPSTREAM_URL"
fi

# Check 3: source_sha256 — must be 64 hex chars or PIN_ON_FIRST_FETCH
if [ -z "$UPSTREAM_SHA" ] || [ "$UPSTREAM_SHA" = "null" ]; then
    err "upstream.source_sha256 is missing or null (use PIN_ON_FIRST_FETCH for first fetch)"
elif [ "$UPSTREAM_SHA" = "PIN_ON_FIRST_FETCH" ]; then
    warn "source_sha256 is PIN_ON_FIRST_FETCH — OK for a first run, but commit the pinned value afterward."
elif ! echo "$UPSTREAM_SHA" | grep -qE '^[0-9a-f]{64}$'; then
    err "upstream.source_sha256 does not look like a SHA256 hex digest: $UPSTREAM_SHA"
fi

# Check 4: build_layout.output_dir
OUTPUT_DIR="$(yq -r '.build_layout.output_dir // ""' "$RECIPE")"
if [ -z "$OUTPUT_DIR" ] || [ "$OUTPUT_DIR" = "null" ]; then
    err "build_layout.output_dir is missing or null"
else
    # Strip the one allowed placeholder and check for remaining '$' signs.
    stripped="${OUTPUT_DIR//\$\{config\}/}"
    if echo "$stripped" | grep -q '\$'; then
        err "build_layout.output_dir contains unknown placeholder (only \${config} is supported): $OUTPUT_DIR"
    fi
fi

# Check 5: build_layout.libraries.main
MAIN_GLOB="$(yq -r '.build_layout.libraries.main // ""' "$RECIPE")"
if [ -z "$MAIN_GLOB" ] || [ "$MAIN_GLOB" = "null" ]; then
    err "build_layout.libraries.main is missing or null — no main library glob defined"
fi

# Check 6: build_layout.version_from
VERSION_FROM="$(yq -r '.build_layout.version_from // "tag"' "$RECIPE")"
case "$VERSION_FROM" in
    tag)
        ;;
    file:*)
        VERSION_FILE="${VERSION_FROM#file:}"
        if [ -z "$VERSION_FILE" ]; then
            err "build_layout.version_from has empty path after 'file:'"
        fi
        # We don't have the source tree yet, so just validate the syntax here.
        ;;
    *)
        err "build_layout.version_from has unsupported value: $VERSION_FROM (expected 'tag' or 'file:<path>')"
        ;;
esac

# Check 7: patches[] files exist
PATCH_COUNT="$(yq -r '.patches | length' "$RECIPE")"
if [ "$PATCH_COUNT" -gt 0 ]; then
    for j in $(seq 0 $((PATCH_COUNT - 1))); do
        P="$(yq -r ".patches[$j]" "$RECIPE")"
        if [ -z "$P" ] || [ "$P" = "null" ]; then
            err "patches[$j] is null or empty"
        elif [ ! -f "$REPO_ROOT/$P" ]; then
            err "patches[$j] file not found: $REPO_ROOT/$P"
        fi
    done
fi

# Check: build_layout.license is present (warn only — Unknown is allowed)
LICENSE="$(yq -r '.build_layout.license // ""' "$RECIPE")"
if [ -z "$LICENSE" ] || [ "$LICENSE" = "null" ]; then
    warn "build_layout.license is not set — will default to 'Unknown' in Debian copyright"
fi

# ---------------------------------------------------------------------------
# Section 2: Target checks
# ---------------------------------------------------------------------------

echo "-- target --"

TARGET_KEY="$(yq -r '.key // ""' "$TARGET_YAML")"
ARCH="$(yq -r '.arch // ""' "$TARGET_YAML")"
OS="$(yq -r '.os // ""' "$TARGET_YAML")"

check_field "key" "$TARGET_KEY"
check_field "arch" "$ARCH"
check_field "os" "$OS"

# Check 9: arch must be a known value
case "$ARCH" in
    arm64|amd64|x86_64|arm|riscv64) ;;
    null|"") ;;  # already caught by check_field above
    *) err "arch '$ARCH' is not a recognized dpkg architecture (expected arm64, amd64, …)" ;;
esac

# Check 10: test path
TEST="$(yq -r '.test // ""' "$TARGET_YAML")"
if [ -n "$TEST" ] && [ "$TEST" != "null" ]; then
    case "$TEST" in
        shared/*|targets/*)
            TEST_ABS="$REPO_ROOT/$TEST"
            if [ ! -f "$TEST_ABS" ]; then
                err "test script declared in target.yaml not found: $TEST_ABS"
            elif [ ! -x "$TEST_ABS" ]; then
                err "test script is not executable: $TEST_ABS"
            fi
            # Path traversal check: resolve and confirm it stays inside the repo.
            if command -v realpath >/dev/null 2>&1; then
                TEST_REAL="$(realpath "$TEST_ABS" 2>/dev/null || echo "$TEST_ABS")"
            else
                TEST_REAL="$(cd "$(dirname "$TEST_ABS")" && pwd)/$(basename "$TEST_ABS")"
            fi
            case "$TEST_REAL" in
                "$REPO_ROOT"/shared/*|"$REPO_ROOT"/targets/*) ;;
                *) err "test path resolves outside shared/ or targets/ (path traversal?): $TEST" ;;
            esac
            ;;
        *)
            err "test path must begin with shared/ or targets/: $TEST"
            ;;
    esac
fi

# Check 11: packaging.formats
FORMATS="$(yq -r '.packaging.formats // [] | join(",")' "$TARGET_YAML")"
if [ -z "$FORMATS" ]; then
    err "packaging.formats is empty or missing — at least one format (tarball, deb) is required"
else
    for fmt in $(echo "$FORMATS" | tr ',' ' '); do
        case "$fmt" in
            tarball|deb|zip) ;;
            *) err "packaging.formats contains unrecognized format: $fmt" ;;
        esac
    done
fi

# Check 12: if deb is in formats, validate binaries[]
case ",$FORMATS," in
    *,deb,*)
        BIN_COUNT="$(yq -r '.packaging.deb.binaries | length' "$TARGET_YAML")"
        if [ "$BIN_COUNT" = "null" ] || [ -z "$BIN_COUNT" ] || [ "$BIN_COUNT" -eq 0 ]; then
            err "packaging.formats includes 'deb' but packaging.deb.binaries is empty or missing"
        else
            for k in $(seq 0 $((BIN_COUNT - 1))); do
                BIN_NAME="$(yq -r ".packaging.deb.binaries[$k].name // \"\"" "$TARGET_YAML")"
                BIN_CONTENTS="$(yq -r ".packaging.deb.binaries[$k].contents // \"\"" "$TARGET_YAML")"
                if [ -z "$BIN_NAME" ] || [ "$BIN_NAME" = "null" ]; then
                    err "packaging.deb.binaries[$k].name is missing or null"
                fi
                if [ -z "$BIN_CONTENTS" ] || [ "$BIN_CONTENTS" = "null" ]; then
                    err "packaging.deb.binaries[$k] ($BIN_NAME) has no contents field"
                fi
                # Validate Debian package name syntax (lowercase alphanum and hyphens,
                # must start with a letter, >= 2 chars).
                if ! echo "$BIN_NAME" | grep -qE '^[a-z][a-z0-9.+-]{1,}$'; then
                    err "packaging.deb.binaries[$k].name '$BIN_NAME' is not a valid Debian package name"
                fi
            done
        fi
        ;;
esac

# Check 13: arch triplet info (informational only)
case "$ARCH" in
    arm64)  echo "  info: arch=arm64 -> triplet=aarch64-linux-gnu, uname=aarch64" ;;
    amd64)  echo "  info: arch=amd64 -> triplet=x86_64-linux-gnu, uname=x86_64" ;;
esac

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
if [ "$ERRORS" -gt 0 ]; then
    echo "VALIDATION FAILED: $ERRORS error(s) found. Fix the issues above before building." >&2
    exit 1
else
    echo "Validation OK — recipe and target look well-formed."
fi
