#!/usr/bin/env bash
# common.sh — helpers shared by fetch-source.sh, package-tarball.sh,
# package-deb.sh, and run-build.sh. Source, do not exec:
#
#   . "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Assumes the caller has already set `set -euo pipefail`.

# require_cmd <cmd> [install-hint]
#   Aborts with a uniform "ERROR: <cmd> not on PATH" message if the
#   command isn't available. Optional second arg adds an install hint.
require_cmd() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command -v "$cmd" >/dev/null; then
        if [ -n "$hint" ]; then
            echo "ERROR: $cmd not on PATH ($hint)" >&2
        else
            echo "ERROR: $cmd not on PATH" >&2
        fi
        exit 1
    fi
}

# require_sha256
#   Cross-platform sha256 prerequisite: Linux has sha256sum, macOS has
#   shasum. We need exactly one.
require_sha256() {
    if ! command -v sha256sum >/dev/null && ! command -v shasum >/dev/null; then
        echo "ERROR: sha256sum/shasum not on PATH" >&2
        exit 1
    fi
}

# sha256_hex <file>
#   Print only the hex digest of <file>. Works on Linux (sha256sum) and
#   macOS (shasum -a 256). Callers format the output however they need.
sha256_hex() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# sha256_line <file>
#   Print "<hex>  <basename>" — byte-identical to `sha256sum <basename>`
#   when run from <file>'s directory. Use for .sha256 sidecar files so
#   `sha256sum -c` works regardless of which OS produced the sidecar.
sha256_line() {
    local f="$1"
    if command -v sha256sum >/dev/null; then
        ( cd "$(dirname "$f")" && sha256sum "$(basename "$f")" )
    else
        ( cd "$(dirname "$f")" && shasum -a 256 "$(basename "$f")" )
    fi
}

# yq_or <default> <expr> <file>
#   Run `yq -r <expr> <file>`. If yq returns "null" or empty, print the
#   default instead. Centralizes the `X="$(yq ...)"; [ "$X" = "null" ] ...`
#   pattern that otherwise multiplies across scripts.
yq_or() {
    local default="$1" expr="$2" file="$3"
    local val
    val="$(yq -r "$expr" "$file")"
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        printf '%s' "$default"
    else
        printf '%s' "$val"
    fi
}

# load_recipe_identity <RECIPE> <TARGET_YAML> <SOURCE_DIR>
#   Sets the canonical recipe+target identity globals used by both
#   package-tarball.sh and package-deb.sh:
#       UPSTREAM_REPO, UPSTREAM_TAG, UPSTREAM_SHA, UPSTREAM_NAME
#       PKG_NAME, PKG_VERSION
#       TARGET_KEY
#       LICENSE_SPDX
#       BUILD_OUTPUT   (recipe.build_layout.output_dir with ${config} substituted)
#
#   Reads CONFIG from the environment (default "Release") for the
#   output_dir template substitution. Aborts on a malformed version_from
#   spec or a missing required field.
load_recipe_identity() {
    local recipe="$1" target_yaml="$2" source_dir="$3"
    local config="${CONFIG:-Release}"

    UPSTREAM_REPO="$(yq -r '.upstream.repo' "$recipe")"
    UPSTREAM_TAG="$(yq -r '.upstream.tag' "$recipe")"
    UPSTREAM_SHA="$(yq -r '.upstream.source_sha256' "$recipe")"
    # Published package name = the directory under packages/ (the parent of
    # recipes/), NOT the upstream repo basename. These coincide for
    # onnxruntime (packages/onnxruntime <- microsoft/onnxruntime) but diverge
    # when one upstream repo ships several packages: packages/tflite is built
    # from tensorflow/tensorflow, and must publish as "tflite", not
    # "tensorflow". See ARCHITECTURE.md "Naming conventions". Falls back to
    # the upstream basename if the recipe isn't under the expected layout.
    local pkg_dir
    if pkg_dir="$(cd "$(dirname "$recipe")/.." 2>/dev/null && pwd)"; then
        PKG_NAME="$(basename "$pkg_dir")"
    else
        PKG_NAME="$(basename "$UPSTREAM_REPO")"
    fi
    # upstream_name is optional (rare: published pkg dir != upstream project
    # name). Empty falls back to the upstream basename; mirrors the original
    # `[ -z "$X" ] && X="$PKG_NAME"` pattern.
    UPSTREAM_NAME="$(yq -r '.upstream.upstream_name // ""' "$recipe")"
    [ -z "$UPSTREAM_NAME" ] && UPSTREAM_NAME="$PKG_NAME"
    TARGET_KEY="$(yq -r '.key' "$target_yaml")"
    LICENSE_SPDX="$(yq -r '.build_layout.license // "Unknown"' "$recipe")"

    local version_from
    version_from="$(yq -r '.build_layout.version_from // "tag"' "$recipe")"
    case "$version_from" in
        file:*)
            local version_file="${version_from#file:}"
            [ -f "$source_dir/$version_file" ] \
                || { echo "ERROR: version file not found: $source_dir/$version_file" >&2; exit 1; }
            PKG_VERSION="$(tr -d '[:space:]' < "$source_dir/$version_file")"
            ;;
        tag)
            PKG_VERSION="${UPSTREAM_TAG#v}"
            ;;
        *)
            echo "ERROR: unsupported version_from: $version_from (expected 'file:<path>' or 'tag')" >&2
            exit 1
            ;;
    esac

    local output_tmpl
    output_tmpl="$(yq -r '.build_layout.output_dir' "$recipe")"
    BUILD_OUTPUT="$source_dir/${output_tmpl//\$\{config\}/$config}"
}

# header_count <recipe>
#   Print the number of entries in build_layout.headers (0 if absent).
header_count() {
    yq -r '.build_layout.headers // [] | length' "$1"
}

# header_src_dest <recipe> <index>
#   Print "<src>\t<dest>" for headers[index]. A header entry is either:
#     - a string  "<src>"            -> dest = basename(src)   (flatten)
#     - a mapping  {src:.., dest:..} -> dest preserves subdirs (e.g. tflite
#       needs include/tensorflow/lite/c/ rather than a flat include/).
#   The string form keeps onnxruntime's existing flatten-by-basename layout;
#   the mapping form lets a package ship a nested include tree.
header_src_dest() {
    local recipe="$1" i="$2" src dest
    src="$(yq -r ".build_layout.headers[$i].src // \"\"" "$recipe")"
    if [ -n "$src" ] && [ "$src" != "null" ]; then
        dest="$(yq -r ".build_layout.headers[$i].dest // \"\"" "$recipe")"
        if [ -z "$dest" ] || [ "$dest" = "null" ]; then
            dest="$(basename "$src")"
        fi
    else
        src="$(yq -r ".build_layout.headers[$i]" "$recipe")"
        dest="$(basename "$src")"
    fi
    printf '%s\t%s' "$src" "$dest"
}

# stage_header <source_dir> <src> <dest> <include_root>
#   Copy $source_dir/$src to $include_root/$dest, creating intermediate
#   directories so nested dests (tensorflow/lite/c/foo.h) are preserved.
#   Missing source headers are skipped silently (different builds/recipes
#   expose different optional headers), matching the prior `[ -f ] && cp`.
stage_header() {
    local source_dir="$1" src="$2" dest="$3" inc_root="$4"
    if [ -f "$source_dir/$src" ]; then
        mkdir -p "$inc_root/$(dirname "$dest")"
        cp "$source_dir/$src" "$inc_root/$dest"
    fi
}
