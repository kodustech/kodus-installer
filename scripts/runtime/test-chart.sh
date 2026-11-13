#!/usr/bin/env bash
# Static checks of charts/kodus-runtime (and of charts/kodus, which mounts its
# product Secrets), with no cluster:
#   - helm lint, with the defaults and with the test values;
#   - helm unittest (charts/kodus-runtime/tests, charts/kodus/tests);
#   - helm template, then kubeconform against the Kubernetes schemas;
#   - one render's generated values agree across the objects carrying them
#     (check-chart-render.py), and it holds no ClusterRole or binding;
#   - the chart's files/ are the installer's runtime/ files, unchanged.
# Needs helm (with the helm-unittest plugin) and kubeconform; python3.
#
# Usage: scripts/runtime/test-chart.sh [--kubernetes-version 1.33.0]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/charts/kodus-runtime"
K8S_VERSION=1.33.0
while [ $# -gt 0 ]; do
    case "$1" in
        --kubernetes-version) K8S_VERSION=${2:?}; shift 2 ;;
        -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
for c in helm kubeconform python3; do command -v "$c" >/dev/null || { echo "$c is required" >&2; exit 2; }; done
helm plugin list | grep -q '^unittest' || { echo "the helm-unittest plugin is required (helm plugin install https://github.com/helm-unittest/helm-unittest)" >&2; exit 2; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
ok() { printf 'ok      %s\n' "$*"; }
bad() { printf 'FAILED  %s\n' "$*"; fail=1; }

VALUES="$CHART/tests/values/ci.yaml"
if helm lint "$CHART" -f "$VALUES" >"$WORK/lint" 2>&1; then ok "helm lint (test values)"; else cat "$WORK/lint"; bad "helm lint (test values)"; fi
# The defaults name no image, database or broker: the render must fail and
# say which value is missing.
if helm template kr "$CHART" >/dev/null 2>"$WORK/defaults"; then
    bad "the defaults render without images"
elif grep -Eq '[a-zA-Z.]+ is required' "$WORK/defaults"; then
    ok "the defaults refuse to render, naming $(grep -Eo '[a-zA-Z.]+ is required' "$WORK/defaults" | head -1)"
else
    cat "$WORK/defaults"; bad "the defaults fail for another reason"
fi
if helm unittest "$CHART" >"$WORK/ut" 2>&1; then ok "helm unittest charts/kodus-runtime ($(grep -Eo 'Tests: +[0-9]+ passed' "$WORK/ut"))"; else cat "$WORK/ut"; bad "helm unittest charts/kodus-runtime"; fi
(cd "$ROOT/charts/kodus" && helm dependency build >/dev/null 2>&1) || true
if helm unittest "$ROOT/charts/kodus" >"$WORK/ut2" 2>&1; then ok "helm unittest charts/kodus ($(grep -Eo 'Tests: +[0-9]+ passed' "$WORK/ut2"))"; else cat "$WORK/ut2"; bad "helm unittest charts/kodus"; fi

for variant in default purge cell-only create-class; do
    args=(-f "$VALUES")
    case "$variant" in
        purge) args+=(--set controlPlane.purgeDataOnUninstall=true) ;;
        cell-only) args+=(--set controlPlane.enabled=false --set-file cell.hub.caPem="$CHART/files/openbao/initialize.hcl"
            --set cell.hub.url=wss://hub.example:3410/cells --set cell.openbao.addr=https://bao.example:8200
            --set-file cell.openbao.caPem="$CHART/files/openbao/initialize.hcl" --set cell.openbao.injectorRoleId=r --set cell.openbao.injectorSecretId=s) ;;
        create-class) args+=(--set cell.runtimeClass.create=true) ;;
    esac
    out="$WORK/render-$variant.yaml"
    if ! helm template kr "$CHART" -n kodus "${args[@]}" >"$out" 2>"$WORK/err"; then cat "$WORK/err"; bad "helm template ($variant)"; continue; fi
    if kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" "$out" >"$WORK/kc" 2>&1; then
        ok "kubeconform $K8S_VERSION ($variant): $(tail -1 "$WORK/kc")"
    else
        cat "$WORK/kc"; bad "kubeconform ($variant)"
    fi
    if grep -Eq '^kind: (ClusterRole|ClusterRoleBinding)$' "$out"; then bad "the render ($variant) grants something cluster-wide"; else ok "no ClusterRole or ClusterRoleBinding ($variant)"; fi
done
if python3 "$ROOT/scripts/runtime/check-chart-render.py" "$WORK/render-default.yaml" kr-kodus-runtime; then ok "generated values agree across the render"; else bad "generated values disagree"; fi

# files/ are copies the chart can read; the sources are the installer's.
while read -r copy src; do
    if cmp -s "$CHART/files/$copy" "$ROOT/$src"; then ok "files/$copy is $src"; else bad "files/$copy differs from $src (copy it again)"; fi
done <<EOT
db-init.sh scripts/runtime/db-init.sh
sql/runtime-roles.sql runtime/sql/runtime-roles.sql
sql/openbao-database.sql runtime/sql/openbao-database.sql
sql/runtime-reader-grants.sql runtime/sql/runtime-reader-grants.sql
sql/runtime-secrets-reader-grants.sql runtime/sql/runtime-secrets-reader-grants.sql
sql/runtime-uninstall.sql runtime/sql/runtime-uninstall.sql
openbao/initialize.hcl runtime/openbao/config/initialize.hcl
openbao/policies/kodus-runtime-api.hcl runtime/openbao/policies/kodus-runtime-api.hcl
openbao/policies/kodus-runtime-injector.hcl runtime/openbao/policies/kodus-runtime-injector.hcl
EOT
[ "$fail" = 0 ] && echo "PASSED charts/kodus-runtime static checks" || { echo "FAILED"; exit 1; }
