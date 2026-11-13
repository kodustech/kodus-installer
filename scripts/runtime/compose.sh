#!/usr/bin/env bash
# docker compose over docker-compose.yml + docker-compose.runtime.yml with the
# `runtime` profile and the settings scripts/runtime/install.sh generated.
#   scripts/runtime/compose.sh ps
#   scripts/runtime/compose.sh logs -f runtime-hub
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
rt_compose "$@"
