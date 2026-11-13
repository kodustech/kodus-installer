#!/usr/bin/env bash
# Backs up the Kody Runtime's part of a Kodus install (docs/runtime.md, "Backup
# and restore"):
#   <out>/kodus_runtime.dump    the Runtime database (Runs, claims, cells, events)
#   <out>/kodus_openbao.dump    OpenBao's storage: every org secret, encrypted
#                               under the unseal key
#   <out>/runtime-state.tar.gz  runtime/state without the unseal key: passwords,
#                               the CAs and their keys, AppRole ids, settings
#   <out>/MANIFEST              release, date, SHA-256 of each file
#   <unseal-key-out>            OpenBao's unseal key, written apart on purpose:
#                               with it the vault dump opens, without it it never
#                               does. Keep it where the dumps are not.
# The product database (and its runtime_secrets metadata) is the product's own
# backup; the evidence volume (30 days of screenshots and logs) is not saved
# unless --with-evidence.
#
# Usage: scripts/runtime/backup.sh --out <dir> --unseal-key-out <file> [--with-evidence]
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

OUT='' KEY_OUT='' EVIDENCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=${2:?}; shift 2 ;;
        --unseal-key-out) KEY_OUT=${2:?}; shift 2 ;;
        --with-evidence) EVIDENCE=1; shift ;;
        -h | --help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) rt_die "unknown argument $1" ;;
    esac
done
[ -n "$OUT" ] && [ -n "$KEY_OUT" ] || rt_die "--out and --unseal-key-out are both required"
[ -s "$RT_STATE/openbao/server/unseal.key" ] || rt_die "no Runtime install in $RT_STATE"
umask 077
mkdir -p "$OUT"
OUT_ABS=$(cd "$OUT" && pwd)
KEY_DIR=$(mkdir -p "$(dirname "$KEY_OUT")" && cd "$(dirname "$KEY_OUT")" && pwd)
case "$KEY_DIR/" in
    "$OUT_ABS"/*) rt_die "--unseal-key-out must be outside --out: the key and the vault dump never travel together" ;;
esac

for db in kodus_runtime kodus_openbao; do
    rt_info "Dumping $db..."
    RUNTIME_INIT_MODE=dump RUNTIME_INIT_DB=$db rt_compose run --rm -T -e RUNTIME_INIT_DB="$db" runtime-init >"$OUT/$db.dump"
    [ -s "$OUT/$db.dump" ] || rt_die "the dump of $db is empty"
done
tar -C "$RT_STATE" --exclude ./openbao/server/unseal.key -czf "$OUT/runtime-state.tar.gz" .
cp "$RT_STATE/openbao/server/unseal.key" "$KEY_OUT"
chmod 600 "$KEY_OUT"
if [ "$EVIDENCE" = 1 ]; then
    rt_info "Archiving the evidence volume..."
    docker run --rm -v kodus-runtime-evidence:/e:ro "$(rt_image any holder)" tar -C /e -czf - . >"$OUT/runtime-evidence.tar.gz"
fi
{
    echo "release=$(rt_env_get "$RT_STATE/compose.env" KODUS_RUNTIME_RELEASE)"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    (cd "$OUT" && for f in *.dump *.tar.gz; do [ -f "$f" ] && echo "sha256 $(openssl dgst -sha256 -r "$f" | cut -d' ' -f1) $f"; done)
    echo "unseal-key sha256 $(openssl dgst -sha256 -r "$KEY_OUT" | cut -d' ' -f1) (stored apart)"
} >"$OUT/MANIFEST"
rt_ok "Runtime backup in $OUT; unseal key in $KEY_OUT."
rt_warn "store the unseal key apart from the dumps (another vault, another bucket): it is the only way to read kodus_openbao.dump"
