#!/usr/bin/env bash
# Pushes an offline bundle (scripts/runtime/bundle-export.sh) into the
# customer's registry with the same digests, then checks each one. Every image
# lands at <registry>/<its source repository path>, so with
# KODUS_RUNTIME_REGISTRY=<registry> the installer pulls the digests pinned in
# runtime/images.lock from there (scripts/runtime/lib.sh rt_image).
#
# Usage: scripts/runtime/bundle-import.sh --bundle <dir> --registry <host[:port][/prefix]> [--insecure]
#   REGISTRY_AUTH_FILE   a containers-auth.json with credentials for the registry
#   --insecure           plain HTTP / unverified TLS (a lab registry only)
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SKOPEO_IMAGE=${KODUS_SKOPEO_IMAGE:-quay.io/skopeo/stable:v1.20.0@sha256:47853bb9fb24202af9110531ebd6e43c5f97701254ca290596640290d17942f4}
BUNDLE='' REGISTRY='' TLS=true
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle) BUNDLE=${2:?}; shift 2 ;;
        --registry) REGISTRY=${2:?}; shift 2 ;;
        --insecure) TLS=false; shift ;;
        -h | --help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) rt_die "unknown argument $1" ;;
    esac
done
[ -n "$BUNDLE" ] && [ -n "$REGISTRY" ] || rt_die "--bundle and --registry are required"
[ -f "$BUNDLE/images.tsv" ] || rt_die "$BUNDLE is not a bundle (no images.tsv)"
rt_require_cmds docker openssl
BUNDLE=$(cd "$BUNDLE" && pwd)
REGISTRY=${REGISTRY%/}

(cd "$BUNDLE" && while read -r sum f; do
    [ "$(openssl dgst -sha256 -r "$f" | cut -d' ' -f1)" = "$sum" ] || rt_die "$f does not match SHA256SUMS"
done <SHA256SUMS)
rt_ok "Bundle files match SHA256SUMS."

skopeo() { docker run --rm --network host -v "$BUNDLE:/bundle:ro" ${REGISTRY_AUTH_FILE:+-v "$REGISTRY_AUTH_FILE:/auth.json:ro" -e REGISTRY_AUTH_FILE=/auth.json} "$SKOPEO_IMAGE" "$@"; }

rt_rows "$BUNDLE/images.tsv" | while IFS=$'\t' read -r component src digest; do
    repo=$(rt_repo "$src")
    repo=${repo#*/}
    hex=${digest#sha256:}
    # A tag only so the registry keeps it; everything pulls by digest.
    dest="$REGISTRY/$repo:kodus-$component-${hex:0:12}"
    rt_info "$component -> $REGISTRY/$repo@$digest"
    skopeo copy --quiet --all --preserve-digests --dest-tls-verify="$TLS" "oci:/bundle/oci:$component" "docker://$dest"
    got=sha256:$(skopeo inspect --raw --tls-verify="$TLS" "docker://$REGISTRY/$repo@$digest" | openssl dgst -sha256 -r | cut -d' ' -f1)
    [ "$got" = "$digest" ] || rt_die "$component: the registry serves $got for $digest"
done
rt_ok "Imported. On the control plane and every cell host: export KODUS_RUNTIME_REGISTRY=$REGISTRY"
