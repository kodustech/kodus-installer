#!/usr/bin/env bash
# scripts/validate-chart-schema.sh
# Anti-drift guard: verifies the Helm chart's secret handling matches the
# schema manifest generated from kodus-ai/.env.schema (charts/kodus/schema.generated.yaml).
# Catches the class of bug that broke the community charts — a hex secret
# generated as base64 (API_CRYPTO_KEY "must be 32 bytes in hexadecimal"), or a
# required secret renamed/dropped.
#
# Usage: ./scripts/validate-chart-schema.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
GEN="charts/kodus/schema.generated.yaml"
SEC="charts/kodus/templates/secrets.yaml"
ENVT="charts/kodus-common/templates/_env.tpl"
fail=0

for f in "$GEN" "$SEC" "$ENVT"; do
  [ -f "$f" ] || { echo -e "${RED}missing $f${NC}"; exit 1; }
done

extract_keys() { grep -oE '"[A-Z0-9_]+"' | tr -d '"'; }

# hex32 secret keys, per the schema.
HEX32=$(sed -n '/^  autogen:/,$p' "$GEN" | grep -E '^    [A-Z0-9_]+: hex32$' | sed -E 's/^    ([A-Z0-9_]+):.*/\1/')
# schema required secrets.
REQ=$(sed -n '/^  required:/,/^  optional:/p' "$GEN" | grep -E '^    - ' | sed 's/^    - //')

# The chart's two secret-format generation lists (hex range first, base64 next).
CHART_HEX=$(grep -E 'range \$k := \(list ' "$SEC" | sed -n '1p' | extract_keys)
CHART_B64=$(grep -E 'range \$k := \(list ' "$SEC" | sed -n '2p' | extract_keys)
# The chart's required (non-optional) app secrets — first list in appSecretsEnv.
APP_REQ=$(grep -E 'range \$key := list "API_JWT_SECRET"' "$ENVT" | head -1 | extract_keys)

echo -e "${YELLOW}== Secret format (hex vs base64) ==${NC}"
for k in $CHART_HEX; do
  if echo "$HEX32" | grep -qx "$k"; then
    echo -e "  ${GREEN}✔${NC} $k generated as hex — schema: hex32"
  else
    echo -e "  ${RED}✘${NC} $k is in the chart's HEX list but the schema does not mark it hex32"; fail=1
  fi
done
for k in $CHART_B64; do
  if echo "$HEX32" | grep -qx "$k"; then
    echo -e "  ${RED}✘${NC} $k is generated as base64 but the schema requires hex32 — this WILL crash the app"; fail=1
  else
    echo -e "  ${GREEN}✔${NC} $k generated as base64 — schema: not hex32"
  fi
done

echo -e "${YELLOW}== Required app secrets wired & named correctly ==${NC}"
for k in $APP_REQ; do
  if echo "$REQ" | grep -qx "$k"; then
    echo -e "  ${GREEN}✔${NC} $k is a valid required secret in the schema"
  else
    echo -e "  ${RED}✘${NC} $k is wired in the chart but is NOT a required secret in the schema (renamed/removed upstream?)"; fail=1
  fi
done

echo ""
if [ "$fail" -ne 0 ]; then
  echo -e "${RED}Chart drifted from the schema.${NC} Regenerate charts/kodus/schema.generated.yaml"
  echo "(pnpm run env:generate --apply --installer in kodus-ai) and reconcile the chart."
  exit 1
fi
echo -e "${GREEN}Chart is in sync with the schema.${NC}"
