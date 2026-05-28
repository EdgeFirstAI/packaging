#!/usr/bin/env bash
# package-deb.sh — produce Debian binary packages from a built tree.
#
# Generic across upstream packages. Generates the debian/ tree on-the-fly
# from target.yaml + recipe metadata and invokes dpkg-deb directly to
# build each binary package. We don't use dpkg-buildpackage / debhelper
# because we're wrapping pre-built artifacts, not building from a source
# package. dpkg-deb is the right tool for that.
#
# Inputs (env):
#   SOURCE_DIR    — extracted source (provides include/, LICENSE)
#   RECIPE        — recipe yaml (build_layout, upstream metadata, license)
#   TARGET_YAML   — target yaml (key, arch, packaging.deb.binaries)
#   BUILD_NUMBER  — EdgeFirst build counter (default 1)
#   DIST_DIR      — where to write .deb files (default $SOURCE_DIR/../dist)
#   CONFIG        — Release|Debug (default Release)

set -euo pipefail

: "${SOURCE_DIR:?SOURCE_DIR not set}"
: "${RECIPE:?RECIPE not set}"
: "${TARGET_YAML:?TARGET_YAML not set}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST_DIR="${DIST_DIR:-$(dirname "$SOURCE_DIR")/dist}"
CONFIG="${CONFIG:-Release}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_cmd yq
require_cmd dpkg-deb "apt install dpkg-dev"
require_sha256

# Sets UPSTREAM_REPO, UPSTREAM_TAG, UPSTREAM_SHA, UPSTREAM_NAME,
# PKG_NAME, PKG_VERSION, TARGET_KEY, LICENSE_SPDX, BUILD_OUTPUT.
load_recipe_identity "$RECIPE" "$TARGET_YAML" "$SOURCE_DIR"
DEB_VERSION="${PKG_VERSION}-edgefirst${BUILD_NUMBER}"

ARCH="$(yq -r '.arch' "$TARGET_YAML")"
case "$ARCH" in
    arm64) TRIPLET="aarch64-linux-gnu" ;;
    amd64) TRIPLET="x86_64-linux-gnu" ;;
    *)     echo "ERROR: unsupported arch: $ARCH" >&2; exit 1 ;;
esac
LIB_INSTALL_DIR="usr/lib/$TRIPLET"
INC_INSTALL_DIR="usr/include"

DEB_OUT_DIR="$DIST_DIR/deb"
mkdir -p "$DEB_OUT_DIR"

# All headers from the recipe's build_layout.headers (used when a binary's
# contents glob is "include/*"). Use portable while-read instead of mapfile
# so this script survives on bash 3.x environments if ever invoked there.
RECIPE_HEADERS=()
while IFS= read -r _h; do
    RECIPE_HEADERS+=("$_h")
done < <(yq -r '.build_layout.headers // [] | .[]' "$RECIPE")

BIN_COUNT="$(yq -r '.packaging.deb.binaries | length' "$TARGET_YAML")"
if [ "$BIN_COUNT" = "null" ] || [ -z "$BIN_COUNT" ] || [ "$BIN_COUNT" -eq 0 ]; then
    echo "WARN: packaging.deb.binaries is empty or missing in $TARGET_YAML — no .deb packages to build." >&2
    exit 0
fi
echo "== package-deb =="
echo "package    : $PKG_NAME"
echo "version    : $DEB_VERSION"
echo "arch       : $ARCH ($TRIPLET)"
echo "binaries   : $BIN_COUNT package(s) defined in target.yaml"
echo "output     : $DEB_OUT_DIR"
echo

for i in $(seq 0 $((BIN_COUNT - 1))); do
    PKG="$(yq -r ".packaging.deb.binaries[$i].name" "$TARGET_YAML")"
    # depends may be absent for a package with no runtime requirements.
    # `null | join(", ")` in yq returns "" which is safe; the conditional
    # below also guards against a literal "null" string.
    DEPS="$(yq -r ".packaging.deb.binaries[$i].depends // [] | join(\", \")" "$TARGET_YAML")"
    PROVIDES="$(yq_or "" ".packaging.deb.binaries[$i].provides // \"\"" "$TARGET_YAML")"
    CONFLICTS="$(yq_or "" ".packaging.deb.binaries[$i].conflicts // \"\"" "$TARGET_YAML")"
    REPLACES="$(yq_or "" ".packaging.deb.binaries[$i].replaces // \"\"" "$TARGET_YAML")"

    echo "-- $PKG --"
    PKG_ROOT="$DEB_OUT_DIR/${PKG}_${DEB_VERSION}_${ARCH}"
    rm -rf "$PKG_ROOT"
    mkdir -p "$PKG_ROOT/DEBIAN" "$PKG_ROOT/$LIB_INSTALL_DIR" "$PKG_ROOT/$INC_INSTALL_DIR"

    # `contents:` can be either a scalar string or a list of strings.
    # Detect type to pick the right yq extraction.
    # Use portable while-read instead of mapfile (bash 4+ only).
    CONTENTS=()
    if yq -e ".packaging.deb.binaries[$i].contents | type == \"!!str\"" "$TARGET_YAML" >/dev/null 2>&1; then
        CONTENTS=( "$(yq -r ".packaging.deb.binaries[$i].contents" "$TARGET_YAML")" )
    else
        while IFS= read -r _c; do
            CONTENTS+=("$_c")
        done < <(yq -r ".packaging.deb.binaries[$i].contents[]" "$TARGET_YAML")
    fi

    for pattern in "${CONTENTS[@]}"; do
        case "$pattern" in
            lib/*)
                src_glob="$BUILD_OUTPUT/${pattern#lib/}"
                dest="$PKG_ROOT/$LIB_INSTALL_DIR"
                # shellcheck disable=SC2086
                for f in $src_glob; do
                    [ -e "$f" ] || continue
                    cp -P "$f" "$dest/"
                done
                ;;
            "include/*")
                # Copy ALL headers from recipe.build_layout.headers.
                dest="$PKG_ROOT/$INC_INSTALL_DIR"
                for h in "${RECIPE_HEADERS[@]}"; do
                    [ -f "$SOURCE_DIR/$h" ] && cp "$SOURCE_DIR/$h" "$dest/"
                done
                ;;
            include/*)
                # Copy a specific header (relative to $SOURCE_DIR).
                dest="$PKG_ROOT/$INC_INSTALL_DIR"
                src_path="$SOURCE_DIR/${pattern#include/}"
                [ -f "$src_path" ] && cp "$src_path" "$dest/"
                ;;
            *)
                echo "WARN: unsupported contents pattern (lib/* or include/* only): $pattern" >&2
                continue
                ;;
        esac
    done

    INSTALLED_SIZE_KB="$(du -sk "$PKG_ROOT" | cut -f1)"

    {
        echo "Package: $PKG"
        echo "Version: $DEB_VERSION"
        echo "Architecture: $ARCH"
        echo "Maintainer: EdgeFirst AI <sebastien@au-zone.com>"
        echo "Installed-Size: $INSTALLED_SIZE_KB"
        [ -n "$DEPS" ] && [ "$DEPS" != "null" ] && echo "Depends: $DEPS"
        [ -n "$PROVIDES" ] && echo "Provides: $PROVIDES"
        [ -n "$CONFLICTS" ] && echo "Conflicts: $CONFLICTS"
        [ -n "$REPLACES" ] && echo "Replaces: $REPLACES"
        echo "Section: libs"
        echo "Priority: optional"
        echo "Multi-Arch: same"
        echo "Homepage: https://github.com/EdgeFirstAI/packaging"
        echo "Description: $UPSTREAM_NAME $PKG_VERSION (EdgeFirst build $BUILD_NUMBER) for $TARGET_KEY"
        echo " Redistributable binary build of $UPSTREAM_REPO ($UPSTREAM_TAG)"
        echo " for the $TARGET_KEY target tuple. See"
        echo " /usr/share/doc/$PKG/BUILD_INFO.txt for full build provenance."
    } > "$PKG_ROOT/DEBIAN/control"

    mkdir -p "$PKG_ROOT/usr/share/doc/$PKG"
    {
        echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
        echo "Upstream-Name: $UPSTREAM_NAME"
        echo "Source: https://github.com/$UPSTREAM_REPO"
        echo
        echo "Files: *"
        echo "Copyright: upstream contributors"
        echo "License: $LICENSE_SPDX"
    } > "$PKG_ROOT/usr/share/doc/$PKG/copyright"
    [ -f "$SOURCE_DIR/LICENSE" ] && cp "$SOURCE_DIR/LICENSE" "$PKG_ROOT/usr/share/doc/$PKG/copyright.upstream"

    {
        echo "$PKG ($DEB_VERSION) unstable; urgency=medium"
        echo
        echo "  * EdgeFirst build $BUILD_NUMBER of upstream $UPSTREAM_NAME $PKG_VERSION"
        echo "    for $TARGET_KEY."
        echo
        echo " -- EdgeFirst AI <sebastien@au-zone.com>  $(date -R)"
    } | gzip -n9 > "$PKG_ROOT/usr/share/doc/$PKG/changelog.Debian.gz"

    # Stamp build provenance from the tarball stage dir (same content).
    STAGE_NAME="${PKG_NAME}-${PKG_VERSION}-edgefirst${BUILD_NUMBER}-${TARGET_KEY}"
    [ -f "$DIST_DIR/$STAGE_NAME/BUILD_INFO.txt" ] && \
        cp "$DIST_DIR/$STAGE_NAME/BUILD_INFO.txt" \
           "$PKG_ROOT/usr/share/doc/$PKG/BUILD_INFO.txt" 2>/dev/null || true

    dpkg-deb --root-owner-group --build -Z xz "$PKG_ROOT" "$DEB_OUT_DIR/" >/dev/null
    DEB_FILE="$DEB_OUT_DIR/${PKG}_${DEB_VERSION}_${ARCH}.deb"
    [ -f "$DEB_FILE" ] || { echo "ERROR: dpkg-deb did not produce $DEB_FILE" >&2; exit 1; }
    SHA="$(sha256_hex "$DEB_FILE")"
    echo "$SHA  $(basename "$DEB_FILE")" > "$DEB_FILE.sha256"

    echo "  built: $(basename "$DEB_FILE") ($(du -h "$DEB_FILE" | cut -f1)) sha256=$SHA"

    rm -rf "$PKG_ROOT"
done

echo
echo "== Done =="
# Glob failure (no .deb produced) is an error, not something to swallow.
# shellcheck disable=SC2012
DEB_LIST=("$DEB_OUT_DIR/"*.deb)
if [ ! -f "${DEB_LIST[0]}" ]; then
    echo "ERROR: no .deb files were produced in $DEB_OUT_DIR — check for earlier warnings" >&2
    exit 1
fi
ls -lh "${DEB_LIST[@]}"
