#!/usr/bin/env bash
# scripts/collect-diagnostics.sh
# Collects a redacted support bundle for a Kodus Helm deployment (K8s/OpenShift)
# so operators can share it with Kodus support. Read-only. Secret VALUES are
# never included — only key names and non-sensitive config.
#
# Usage: ./scripts/collect-diagnostics.sh [-n namespace] [-r release] [-o output-dir]
#
# Every file goes through the shared redactor (scripts/redact-lib.sh) before it
# is archived. Docker Compose installs: scripts/collect-diagnostics-compose.sh.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/redact-lib.sh
. "$SCRIPT_DIR/redact-lib.sh"
RELEASE="kodus"; NS=""; OUT_DIR="${TMPDIR:-/tmp}"
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NS="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    -o|--output)    OUT_DIR="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 [-n namespace] [-r release] [-o output-dir]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }
[ -z "$NS" ] && NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null); [ -z "$NS" ] && NS=default
K="kubectl -n $NS"

# The bundle is for support, not for other users of this machine.
umask 077
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo bundle)
OUT="kodus-diagnostics-${NS}-${STAMP}"
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/kodus-diagnostics.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT
DIR="$WORKDIR/$OUT"
mkdir -p "$DIR"
redact() { kodus_redact; }

echo "Collecting into $DIR ..."
{ kubectl version 2>/dev/null; echo "namespace: $NS  release: $RELEASE"; } | redact > "$DIR/00-meta.txt"
command -v helm >/dev/null 2>&1 && helm -n "$NS" status "$RELEASE" 2>&1 | redact > "$DIR/01-helm-status.txt"
$K get all,pvc,ingress,networkpolicy,configmap -o wide 2>&1 | redact > "$DIR/02-resources.txt"
$K get events --sort-by=.lastTimestamp 2>&1 | redact > "$DIR/03-events.txt"
$K describe pods 2>&1 | redact > "$DIR/04-describe-pods.txt"

# ConfigMap with secret-ish keys blanked; Secrets = KEY NAMES ONLY (never values).
$K get configmap "${RELEASE}-config" -o yaml 2>/dev/null | redact > "$DIR/05-configmap.redacted.yaml"
echo "# secret keys present (values intentionally omitted):" > "$DIR/06-secret-keys.txt"
$K get secret "${RELEASE}-secrets" -o jsonpath='{range .data.*}{"\n"}{end}' >/dev/null 2>&1
$K get secret "${RELEASE}-secrets" -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null >> "$DIR/06-secret-keys.txt"

# Logs per app pod (redacted, tail-bounded).
mkdir -p "$DIR/logs"
for p in $($K get pods -l app.kubernetes.io/part-of=kodus -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  $K logs "$p" --all-containers --tail=500 2>&1 | redact > "$DIR/logs/${p}.log"
done

# Pino/OTel-aware: the app logs are structured (Pino). Surface ONLY error/warn/
# fatal entries regardless of wording — Pino JSON levels (warn=40, error=50,
# fatal=60) or pretty labels — so a "Validation Failed"/"HttpError" doesn't hide
# behind a keyword grep. This is where the real failures live.
grep -rhaE '"level":(4[0-9]|5[0-9]|6[0-9])|\b(ERROR|WARN|FATAL)\b|HttpError|Validation Failed|Unhandled' "$DIR/logs" 2>/dev/null \
  | grep -viE '/health|kube-probe' | redact | tail -400 > "$DIR/08-errors-warnings.txt"
# Correlate a single request across services with:  grep -rh '<requestId>' logs/
echo "# Tip: trace one request across services — grep -rh \"<requestId>\" logs/" > "$DIR/09-how-to-trace.txt"

# Doctor snapshot (if present).
[ -x "$SCRIPT_DIR/doctor-k8s.sh" ] && "$SCRIPT_DIR/doctor-k8s.sh" -n "$NS" -r "$RELEASE" --verbose 2>&1 | kodus_strip_ansi | redact > "$DIR/07-doctor.txt"

# Every file, once more: whatever a step above wrote unfiltered is caught here.
kodus_redact_tree "$DIR"

TARBALL="${OUT_DIR%/}/${OUT}.tar.gz"
if ! tar -czf "$TARBALL" -C "$WORKDIR" "$OUT"; then
  echo "Could not write $TARBALL"; exit 1
fi
echo ""
echo "Support bundle: $TARBALL"
echo "Secret values are redacted, but check what is inside before you share it: tar -xzf $TARBALL"
