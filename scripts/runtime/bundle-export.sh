#!/usr/bin/env bash
# Exports every image and kit a Kody Runtime release runs into one OCI layout,
# with the same digests, for an air-gapped install (docs/runtime.md, "Offline
# bundle"). Images are copied with every platform of their index
# (skopeo copy --all --preserve-digests), so a digest pinned in
# runtime/images.lock resolves the same in the customer's registry.
# skopeo (Apache-2.0) runs as its own unmodified container.
#
#   <out>/oci/            the OCI layout; each image under its component name
#   <out>/images.tsv      component, source reference, digest
#   <out>/files/gvisor/   gvisor.tar.bz2 of each architecture (runtime/gvisor.tsv)
#   <out>/runtime/        compatibility.tsv, images.lock, gvisor.tsv
#   <out>/SHA256SUMS
#
# Usage: scripts/runtime/bundle-export.sh --release <product release> --out <dir> [--only c1,c2] [--no-gvisor]
# An unpublished component fails the export unless KODUS_RUNTIME_<C>_IMAGE
# names a registry reference for it (a local-only image cannot keep its digest).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SKOPEO_IMAGE=${KODUS_SKOPEO_IMAGE:-quay.io/skopeo/stable:v1.20.0@sha256:47853bb9fb24202af9110531ebd6e43c5f97701254ca290596640290d17942f4}
RELEASE='' OUT='' ONLY='' GVISOR=1
while [ $# -gt 0 ]; do
    case "$1" in
        --release) RELEASE=${2:?}; shift 2 ;;
        --out) OUT=${2:?}; shift 2 ;;
        --only) ONLY=${2:?}; shift 2 ;;
        --no-gvisor) GVISOR=0; shift ;;
        -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) rt_die "unknown argument $1" ;;
    esac
done
[ -n "$RELEASE" ] && [ -n "$OUT" ] || rt_die "--release and --out are required"
rt_require_cmds docker openssl curl
CELL_RELEASE=$(rt_cell_release_for "$RELEASE" "${KODUS_RUNTIME_CELL_RELEASE:-}")
[ -n "$CELL_RELEASE" ] || rt_die "no cell release fits $RELEASE"
mkdir -p "$OUT/oci" "$OUT/runtime"
OUT=$(cd "$OUT" && pwd)

wanted() { [ -z "$ONLY" ] || case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
skopeo() { docker run --rm --network host -v "$OUT:/bundle" ${REGISTRY_AUTH_FILE:+-v "$REGISTRY_AUTH_FILE:/auth.json:ro" -e REGISTRY_AUTH_FILE=/auth.json} "$SKOPEO_IMAGE" "$@"; }

printf '#component\tsource\tdigest\n' >"$OUT/images.tsv"
export_one() { # export_one COMPONENT RELEASE [optional]
    local ref digest got
    wanted "$1" || return 0
    ref=$(rt_image "$2" "$1" "${3:-}")
    if [ -z "$ref" ]; then
        rt_warn "$1: not published for $2, left out"
        return 0
    fi
    case "$ref" in
        *@sha256:*) digest=sha256:${ref##*@sha256:} ;;
        *) rt_die "$1: $ref is not pinned by digest; an offline bundle carries digests only" ;;
    esac
    rt_info "$1  $ref"
    # skopeo takes a digest or a tag, not both.
    skopeo copy --quiet --all --preserve-digests "docker://$(rt_repo "$ref")@$digest" "oci:/bundle/oci:$1"
    got=sha256:$(skopeo inspect --raw "oci:/bundle/oci:$1" | openssl dgst -sha256 -r | cut -d' ' -f1)
    [ "$got" = "$digest" ] || rt_die "$1: the layout holds $got, not $digest"
    printf '%s\t%s\t%s\n' "$1" "$ref" "$digest" >>"$OUT/images.tsv"
}

for c in hub worker openbao; do export_one "$c" "$RELEASE"; done
for c in cell builder holder helper registry; do export_one "$c" "$CELL_RELEASE"; done
for c in sandbox browser microvm-kit; do export_one "$c" "$CELL_RELEASE" optional; done

cp "$RT_COMPAT" "$RT_LOCK" "$RT_GVISOR" "$OUT/runtime/"
if [ "$GVISOR" = 1 ]; then
    rel=$(rt_rows "$RT_GVISOR" | awk -F '\t' 'NR == 1 { print $1 }')
    for arch in x86_64 aarch64; do
        sha=$(rt_rows "$RT_GVISOR" | awk -F '\t' -v r="$rel" -v a="$arch" '$1 == r && $2 == a { print $3 }')
        mkdir -p "$OUT/files/gvisor/$rel/$arch"
        curl -fsSL --retry 3 -o "$OUT/files/gvisor/$rel/$arch/gvisor.tar.bz2" \
            "https://storage.googleapis.com/gvisor/releases/release/$rel/$arch/gvisor.tar.bz2"
        got=$(openssl dgst -sha512 -r "$OUT/files/gvisor/$rel/$arch/gvisor.tar.bz2" | cut -d' ' -f1)
        [ "$got" = "$sha" ] || rt_die "gVisor $rel $arch does not match runtime/gvisor.tsv"
    done
fi
sums=$(cd "$OUT" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while read -r f; do
    printf '%s  %s\n' "$(openssl dgst -sha256 -r "$f" | cut -d' ' -f1)" "${f#./}"
done)
printf '%s\n' "$sums" >"$OUT/SHA256SUMS"
rt_ok "Bundle for $RELEASE (cell $CELL_RELEASE) in $OUT."
