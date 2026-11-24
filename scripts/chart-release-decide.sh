#!/usr/bin/env bash
# scripts/chart-release-decide.sh — should this run of chart-release.yml publish?
#
# A tag push and a manual dispatch always go on to the release job, which keeps
# its own checks (tag matches Chart.yaml, version not already published).
#
# A push to main that touched charts/kodus/Chart.yaml publishes only when the
# chart `version` moved in that push. That is the moment a release was decided:
# bump-app-version.yml opens exactly such a PR for every Kodus release, and before
# this script the publish still waited for someone to push a chart-v* tag by hand
# after the merge — which is how 0.3.5–0.3.7 never reached the registry (#2673).
#
#   version moved                → release
#   version same, appVersion moved → FAIL: a Kodus release that no chart carries
#   version same, nothing else   → skip (comments, annotations)
#
# Usage (CI):   EVENT=push REF=refs/heads/main BEFORE=<sha> scripts/chart-release-decide.sh
# Usage (local): same, from a checkout where BEFORE is reachable.
# Writes release=true|false and version=X.Y.Z to $GITHUB_OUTPUT when set.

set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

CHART="charts/kodus/Chart.yaml"
EVENT="${EVENT:?EVENT is required}"
REF="${REF:-}"
BEFORE="${BEFORE:-}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

field() { # field <name> <file contents on stdin>
  grep -E "^$1:" | head -1 | awk '{print $2}' | tr -d '"'
}

VERSION=$(field version < "$CHART")
APP_VERSION=$(field appVersion < "$CHART")
[ -n "$VERSION" ] || { echo "::error file=$CHART::no version in $CHART"; exit 1; }

decide() {
  echo "release=$1" >> "$OUT"
  echo "version=$VERSION" >> "$OUT"
  echo "decision: release=$1 version=$VERSION ($2)"
}

if [ "$EVENT" != "push" ] || [[ "$REF" == refs/tags/* ]]; then
  decide true "$EVENT ${REF:-}"
  exit 0
fi

# A brand-new branch has no previous commit to compare against.
if [ -z "$BEFORE" ] || [ "$BEFORE" = "0000000000000000000000000000000000000000" ]; then
  decide true "no previous commit to compare"
  exit 0
fi

if ! OLD=$(git show "$BEFORE:$CHART" 2>/dev/null); then
  decide true "$CHART did not exist at $BEFORE"
  exit 0
fi
OLD_VERSION=$(printf '%s\n' "$OLD" | field version)
OLD_APP_VERSION=$(printf '%s\n' "$OLD" | field appVersion)

if [ "$OLD_VERSION" != "$VERSION" ]; then
  decide true "version $OLD_VERSION -> $VERSION"
  exit 0
fi

if [ "$OLD_APP_VERSION" != "$APP_VERSION" ]; then
  echo "::error file=$CHART::appVersion moved $OLD_APP_VERSION -> $APP_VERSION but the chart version stayed $VERSION, which is already decided. Helm users would never receive Kodus $APP_VERSION. Bump the chart version (patch: the chart itself did not change)."
  exit 1
fi

decide false "Chart.yaml changed but version and appVersion did not"
