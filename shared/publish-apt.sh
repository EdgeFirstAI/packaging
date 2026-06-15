#!/usr/bin/env bash
# publish-apt.sh — upload one or more .deb files to the EdgeFirst APT
# repository on S3, GPG-sign the metadata, then invalidate the CloudFront
# cache so consumers see the new index immediately.
#
# Modeled on the adis-uav-meta pipeline pattern: deb-s3 manages the
# apt-ftparchive equivalent (regenerates Packages.gz, Release, InRelease
# with GPG sig) and uses S3 lock files for concurrency safety. CloudFront
# in front of S3 serves consumers at https://repo.edgefirst.ai/apt/.
#
# Usage:
#   publish-apt.sh <deb> [<deb>...]
#
# Required env (typically set by CI secrets or a local-shell helper):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   — S3 write + CloudFront invalidate
#   APT_GPG_KEY_ID                              — GPG fingerprint used by deb-s3 --sign
#   The matching private key must be importable via the local gpg keyring.
#
# Optional env (with defaults matching our infrastructure):
#   EDGEFIRST_APT_BUCKET            (default: edgefirst-repo)
#   EDGEFIRST_APT_PREFIX            (default: apt)
#   EDGEFIRST_APT_REGION            (default: us-west-2)
#   EDGEFIRST_APT_CODENAME          (default: stable)
#   EDGEFIRST_APT_VISIBILITY        (default: private — the edgefirst-repo
#                                    bucket blocks public ACLs and is served
#                                    via CloudFront OAC, so deb-s3 must NOT try
#                                    to set public-read ACLs. Matches the ADIS
#                                    private+OAC pattern.)
#   EDGEFIRST_CLOUDFRONT_DIST_ID    (required for the invalidation step;
#                                    set to "skip" to skip invalidation,
#                                    useful for testing without touching prod)

set -euo pipefail

if [ "$#" -lt 1 ]; then
    cat <<USAGE >&2
usage: $0 <deb> [<deb>...]
example: $0 work/linux-aarch64-jp62-cuda126/dist/deb/*.deb

required env:
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
  APT_GPG_KEY_ID  (fingerprint; the matching private key must be in the gpg keyring)
  EDGEFIRST_CLOUDFRONT_DIST_ID  (or "skip" to omit the invalidation step)
USAGE
    exit 2
fi

DEBS=("$@")
for d in "${DEBS[@]}"; do
    [ -f "$d" ] || { echo "ERROR: not a file: $d" >&2; exit 1; }
    case "$d" in *.deb) ;; *) echo "ERROR: not a .deb: $d" >&2; exit 1 ;; esac
done

: "${APT_GPG_KEY_ID:?APT_GPG_KEY_ID not set (gpg fingerprint for deb-s3 --sign)}"
: "${EDGEFIRST_CLOUDFRONT_DIST_ID:?EDGEFIRST_CLOUDFRONT_DIST_ID not set (use 'skip' to omit invalidation)}"

S3_BUCKET="${EDGEFIRST_APT_BUCKET:-edgefirst-repo}"
S3_PREFIX="${EDGEFIRST_APT_PREFIX:-apt}"
S3_REGION="${EDGEFIRST_APT_REGION:-us-west-2}"
CODENAME="${EDGEFIRST_APT_CODENAME:-stable}"
VISIBILITY="${EDGEFIRST_APT_VISIBILITY:-private}"

command -v deb-s3 >/dev/null || { echo "ERROR: deb-s3 not on PATH (gem install deb-s3)" >&2; exit 1; }
command -v aws    >/dev/null || { echo "ERROR: aws CLI not on PATH" >&2; exit 1; }
command -v gpg    >/dev/null || { echo "ERROR: gpg not on PATH" >&2; exit 1; }

# Sanity: confirm the signing key is actually in the keyring.
gpg --list-secret-keys "$APT_GPG_KEY_ID" >/dev/null 2>&1 \
    || { echo "ERROR: gpg secret key '$APT_GPG_KEY_ID' not found in keyring." >&2; \
         echo "Import with: echo \$APT_GPG_PRIVATE_KEY | base64 -d | gpg --batch --import" >&2; \
         exit 1; }

# All .debs in a single upload must agree on architecture (deb-s3 takes one
# --arch flag per invocation). Group inputs by architecture and run deb-s3
# once per group.
declare -A BY_ARCH
for d in "${DEBS[@]}"; do
    a="$(dpkg --info "$d" 2>/dev/null | awk '/^ Architecture:/{print $2; exit}')"
    [ -n "$a" ] || { echo "ERROR: cannot read Architecture from $d" >&2; exit 1; }
    BY_ARCH["$a"]+="$d "
done

echo "== publish-apt =="
echo "bucket    : s3://$S3_BUCKET/$S3_PREFIX/"
echo "region    : $S3_REGION"
echo "codename  : $CODENAME"
echo "visibility: $VISIBILITY"
echo "gpg key   : $APT_GPG_KEY_ID"
echo "uploads   : ${#DEBS[@]} .deb across ${#BY_ARCH[@]} arch(es) (${!BY_ARCH[*]})"
echo

for ARCH in "${!BY_ARCH[@]}"; do
    # shellcheck disable=SC2086 disable=SC2206
    DEBS_FOR_ARCH=( ${BY_ARCH[$ARCH]} )
    echo "-- arch=$ARCH (${#DEBS_FOR_ARCH[@]} packages) --"
    deb-s3 upload --lock \
        --bucket "$S3_BUCKET" \
        --prefix "$S3_PREFIX" \
        --codename "$CODENAME" \
        --arch "$ARCH" \
        --s3-region "$S3_REGION" \
        --sign "$APT_GPG_KEY_ID" \
        --visibility "$VISIBILITY" \
        "${DEBS_FOR_ARCH[@]}"
done

# CloudFront in front of S3 caches the metadata files (Packages.gz, Release,
# InRelease) by default. New uploads aren't visible to consumers until either
# the cache TTL expires (typically 1 hour) or we explicitly invalidate.
# Invalidate the dists/ tree — narrow enough to avoid wasting invalidations.
#
# Invalidate BOTH the metadata tree (dists/) AND the package pool (pool/).
# dists/ is always mutated by an upload. pool/ objects are normally immutable
# (a new version = a new filename, never cached before), so in steady state
# only dists/ strictly needs invalidating. BUT if a build is re-cut at the
# SAME version with different content (e.g. a packaging fix during release
# prep), the pool object is OVERWRITTEN at an already-cached path — CloudFront
# then serves the STALE deb whose hash no longer matches the fresh Packages
# index, and apt fails with a hash/filesize mismatch. Invalidating pool/ too
# (cheap: one wildcard = one path) makes re-cuts safe. Best practice remains
# to bump the build number rather than overwrite, but don't rely on it.
#
# IMPORTANT: deb-s3 upload above has already mutated the APT repository
# metadata. If the CloudFront invalidation fails, the repo is updated but
# consumers may see stale metadata/debs until the CF cache TTL expires. This
# is logged as a warning (not fatal) so the operator can retry the
# invalidation separately without re-running the upload.
if [ "$EDGEFIRST_CLOUDFRONT_DIST_ID" = "skip" ]; then
    echo
    echo "(EDGEFIRST_CLOUDFRONT_DIST_ID=skip — not invalidating CloudFront)"
else
    echo
    echo "-- CloudFront invalidation --"
    if ! aws cloudfront create-invalidation \
            --distribution-id "$EDGEFIRST_CLOUDFRONT_DIST_ID" \
            --paths "/${S3_PREFIX}/dists/*" "/${S3_PREFIX}/pool/*"; then
        echo "WARN: CloudFront invalidation failed. The APT repository was" >&2
        echo "  successfully updated on S3, but consumers may see stale" >&2
        echo "  metadata or .debs until the CloudFront cache TTL expires" >&2
        echo "  (typically ~1 hour). To retry the invalidation manually:" >&2
        echo "  aws cloudfront create-invalidation \\" >&2
        echo "      --distribution-id $EDGEFIRST_CLOUDFRONT_DIST_ID \\" >&2
        echo "      --paths '/${S3_PREFIX}/dists/*' '/${S3_PREFIX}/pool/*'" >&2
    fi
fi

echo
echo "== Done =="
echo "Published to https://repo.edgefirst.ai/${S3_PREFIX}/ codename=$CODENAME"
