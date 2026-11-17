#!/usr/bin/env bash
# Tests cell-host.sh's offline release bundle (--release-bundle) on this
# machine, in a temporary directory: no root, no Docker, no systemd, no
# network (Linux or macOS; needs OpenSSL 3 or later for ed25519). The
# bundle under testdata/cell-bundle was made by kodus-ai's
# `release-sign bundle` code (internal/releasesig) with a test key, so this
# also checks that the Go signer and this verifier agree on the format.
#   - a bundle signed with a pinned key verifies offline, as a directory or
#     a tar of one; one changed byte, a missing artifact, an edited BUNDLE,
#     an unpinned key or another release than asked is refused before any
#     image is loaded;
#   - its release index refuses the bundle once expired, or when it is older
#     than the index the host accepted; install records the index it took;
#   - each image is loaded from its OCI archive and must resolve by digest
#     (else the containerd image store is named), and is what the cell's
#     image overrides then point at; --registry-mirror refuses a push that
#     changes the digest;
#   - install takes runsc and the binaries from the bundle; upgrade hands the
#     bundle's release/ to `cell update -from`.
# Usage: scripts/runtime/test-cell-host-bundle.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CH="$HERE/cell-host.sh"
FIXTURE="$HERE/testdata/cell-bundle"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT

pass=0 fail=0
t() {
    local name=$1
    shift
    if "$@" >"$TMP/out" 2>&1; then
        pass=$((pass + 1)); printf 'ok    %s\n' "$name"
    else
        fail=$((fail + 1)); printf 'FAIL  %s\n' "$name"; sed 's/^/      /' "$TMP/out" | tail -20
    fi
}
has() { grep -qF -- "$1" "$2" || { echo "no \"$1\" in $2:"; cat "$2"; return 1; }; }
hasnt() { ! grep -qF -- "$1" "$2" || { echo "\"$1\" in $2:"; cat "$2"; return 1; }; }

# 2026-11-17T00:00:00Z: a day after the fixture's index was issued.
NOW=1794873600
HOLDER=docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

# A host: a stub docker that records its calls, and release v1 installed
# whose stub cell records `cell update`.
new_host() {
    H="$TMP/host-$1"
    mkdir -p "$H/bin" "$H/opt/kodus-cell/releases/v1-aaaaaaaaaaaa/bin" "$H/etc/kodus/cell"
    ln -sfn /opt/kodus-cell/releases/v1-aaaaaaaaaaaa "$H/opt/kodus-cell/current"
    cat >"$H/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "$1 ${2:-}" in
    "image inspect") exit "${STUB_INSPECT:-0}" ;;
    "push "*) echo "bundle: digest: ${STUB_PUSH_DIGEST:-sha256:0000000000000000000000000000000000000000000000000000000000000000} size: 1" ;;
esac
EOF
    cat >"$H/opt/kodus-cell/releases/v1-aaaaaaaaaaaa/bin/cell" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
EOF
    chmod 755 "$H/bin/docker" "$H/opt/kodus-cell/releases/v1-aaaaaaaaaaaa/bin/cell"
    cp -R "$FIXTURE/bundle" "$H/bundle"
    export DOCKER_LOG="$H/docker.log" STUB_LOG="$H/cell.log"
    : >"$DOCKER_LOG"
    : >"$STUB_LOG"
}

# in_script: runs CALL with cell-host.sh's functions on host H, the pinned
# key of the fixture and the clock at NOW; output in $H/script.out.
in_script() {
    (
        set --
        export KODUS_CELL_ROOT=$H KODUS_CELL_DOCKER=$H/bin/docker KODUS_CELL_SYSTEMCTL=systemctl
        export KODUS_CELL_RELEASE_KEYS=${KEYS:-$FIXTURE/cell-release.pub} KODUS_CELL_NOW=${CLOCK:-$NOW} KODUS_CELL_ARCH=x86_64
        # shellcheck source=cell-host.sh
        . "$CH"
        "${CALL[@]}"
    ) >"$H/script.out" 2>&1
}
refused() { ! in_script; }
VERIFY=(eval 'RELEASE_BUNDLE=$KODUS_CELL_ROOT/bundle; prepare_release_bundle install; load_bundle_images')

echo "== a signed bundle verifies offline"
new_host ok
CALL=(eval 'RELEASE_BUNDLE=$KODUS_CELL_ROOT/bundle; prepare_release_bundle install; load_bundle_images; printf "%s|%s|%s|%s\n" "$RELEASE" "$GVISOR_ARCHIVE" "$CELL_BIN_DIR" "$KODUS_RUNTIME_HOLDER_IMAGE" >"$KODUS_CELL_ROOT/vars"; ls "$CELL_BIN_DIR" >"$KODUS_CELL_ROOT/bins"')
t "the Go-signed bundle verifies with the pinned key" in_script
t "it names its release and key" has "Bundle of release v1.4.0 verified offline (key 65b60673d6ed884b): 1 images, 1 gVisor archives." "$H/script.out"
t "the release comes from the bundle" has "v1.4.0|" "$H/vars"
t "runsc installs from the bundle's archive for this arch" has "/gvisor/x86_64/gvisor.tar.bz2|" "$H/vars"
t "the image is loaded from its OCI archive" has "load -i $H/bundle/images/holder.oci.tar" "$DOCKER_LOG"
t "and must resolve by its pinned digest" has "image inspect $HOLDER" "$DOCKER_LOG"
t "the cell's holder image is the pinned reference" has "|$HOLDER" "$H/vars"
t "the binaries are named as the installer installs them" sh -c 'for b in cell egress injector observer reaper; do grep -qx "$b" "$0" || exit 1; done' "$H/bins"
t "nothing is pulled" hasnt "pull" "$DOCKER_LOG"

new_host tar
(cd "$H" && tar -cf bundle.tar bundle)
rm -rf "$H/bundle"
CALL=(eval 'RELEASE_BUNDLE=$KODUS_CELL_ROOT/bundle.tar; prepare_release_bundle install')
t "a tar of the bundle verifies the same" in_script

echo "== a bundle that does not verify loads nothing"
new_host tampered
printf 'x' >>"$H/bundle/images/holder.oci.tar"
CALL=("${VERIFY[@]}")
t "one changed byte of an image is refused" refused
t "the refusal names the file and its sha256" has "images/holder.oci.tar: sha256" "$H/script.out"
t "no image was loaded" hasnt "load" "$DOCKER_LOG"

new_host missing
rm "$H/bundle/gvisor/x86_64/gvisor.tar.bz2"
t "a missing artifact is refused" refused
t "named as missing" has "gvisor/x86_64/gvisor.tar.bz2 is listed but missing" "$H/script.out"

new_host edited
sed -i.bak 's/alpine/evilpine/' "$H/bundle/BUNDLE" && rm "$H/bundle/BUNDLE.bak"
t "an edited BUNDLE does not verify" refused
t "the signature is what fails" has "BUNDLE.sig does not verify against BUNDLE" "$H/script.out"

new_host binary
printf 'x' >>"$H/bundle/release/cell-linux-amd64"
t "a changed binary is refused" refused

new_host wrongkey
printf 'kodus-cell-release-key %s\n' "$(printf '%032d' 0 | openssl base64 -A)" >"$H/other.pub"
KEYS="$H/other.pub" t "a bundle signed with a key the host does not pin is refused" refused
t "named as not pinned" has "signed with key 65b60673d6ed884b, which is not pinned" "$H/script.out"

new_host nokeys
: >"$H/none.pub"
KEYS="$H/none.pub" t "with no key pinned nothing verifies" refused

new_host release
CALL=(eval 'RELEASE=v1.5.0; RELEASE_BUNDLE=$KODUS_CELL_ROOT/bundle; prepare_release_bundle install')
t "a bundle of another release than asked is refused" refused
t "it names both" has "it holds release v1.4.0, not v1.5.0" "$H/script.out"

new_host both
CALL=(eval 'FROM=/srv/r; RELEASE_BUNDLE=$KODUS_CELL_ROOT/bundle; prepare_release_bundle upgrade')
t "--release-bundle with --from is refused" refused

echo "== the release index inside"
new_host expired
CALL=("${VERIFY[@]}")
CLOCK=1830000000 t "an expired index refuses the bundle" refused
t "named as expired" has "release index expired" "$H/script.out"
t "and nothing was loaded" hasnt "load" "$DOCKER_LOG"

new_host older
printf '{\n  "issued": "2026-12-01T00:00:00Z",\n  "revokedKeys": []\n}\n' >"$H/opt/kodus-cell/release-index.state"
t "an index older than the host's is refused" refused
t "named as older" has "is older than the one this host accepted (2026-12-01T00:00:00Z)" "$H/script.out"

new_host revoked
printf '{\n  "issued": "2026-11-01T00:00:00Z",\n  "revokedKeys": [\n    "65b60673d6ed884b"\n  ]\n}\n' >"$H/opt/kodus-cell/release-index.state"
t "a key the host has seen revoked is refused" refused

new_host state
printf '{\n  "issued": "2026-11-01T00:00:00Z",\n  "revokedKeys": [\n    "1111111111111111"\n  ]\n}\n' >"$H/opt/kodus-cell/release-index.state"
CALL=(eval 'RELEASE_BUNDLE=$KODUS_CELL_ROOT/bundle; prepare_release_bundle install; save_bundle_index')
t "a newer index is accepted and recorded" in_script
t "the host keeps the index's issue time" has '"issued": "2026-11-16T00:00:00Z"' "$H/opt/kodus-cell/release-index.state"
t "and every key it saw revoked" has '"1111111111111111"' "$H/opt/kodus-cell/release-index.state"

echo "== Docker that discards digests, and a registry mirror"
new_host nodigest
CALL=("${VERIFY[@]}")
STUB_INSPECT=1 t "an image that does not resolve by digest after load stops the install" refused
t "the containerd image store is named" has "containerd-snapshotter" "$H/script.out"

new_host mirror
CALL=(eval 'REGISTRY_MIRROR=mirror.local:5000; RELEASE_BUNDLE=$KODUS_CELL_ROOT/bundle; prepare_release_bundle install; load_bundle_images')
t "a push that changes the digest is refused" refused
t "pushed under the source repository path" has "push mirror.local:5000/library/alpine:3.20" "$DOCKER_LOG"
new_host mirror-ok
STUB_PUSH_DIGEST=sha256:${HOLDER##*sha256:} t "a push that keeps the digest passes" in_script

echo "== upgrade goes through cell update"
new_host upgrade
CALL=(eval 'RELEASE_BUNDLE=$KODUS_CELL_ROOT/bundle; prepare_release_bundle upgrade; cell_update_release "$FROM"')
t "the upgrade's cell update runs" in_script
t "cell update gets the bundle's release/ and its release" has "-from $H/bundle/release -release v1.4.0" "$STUB_LOG"
t "with the cell's config for the preflight and the rollback window" has "-preflight-config $H/etc/kodus/cell/cell.yaml -rollback-window 10m" "$STUB_LOG"

echo "== usage"
t "install and upgrade name --release-bundle" sh -c '"$0" --help | grep -q -- "--release-bundle PATH"' "$CH"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
