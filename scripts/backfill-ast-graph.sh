#!/usr/bin/env bash
# Backfill AST graphs for repositories that were selected before this
# instance had AST graph support. Runs the kodus-ai `ast:backfill:prod`
# CLI inside the running `api` container.
#
# Idempotent: repos already at READY are skipped, BUILDING ones are never
# re-enqueued. Re-running is safe.
#
# Usage:
#   ./scripts/backfill-ast-graph.sh                        # all teams
#   ./scripts/backfill-ast-graph.sh --org <id>             # one org
#   ./scripts/backfill-ast-graph.sh --org <id> --team <id> # one team
#   ./scripts/backfill-ast-graph.sh --force                # also rebuild READY graphs
#   ./scripts/backfill-ast-graph.sh --limit 50             # cap jobs per team
#   ./scripts/backfill-ast-graph.sh --dry-run              # list teams, enqueue nothing

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo -e "${RED}Error: Docker Compose is not installed.${NC}"
    exit 1
fi

# `api` is the canonical service name in docker-compose.yml. The
# CLI ships in the same image as `api` (same Dockerfile target chain),
# and exec-ing into `api` avoids contending with the running `worker`.
SERVICE=${KODUS_AST_BACKFILL_SERVICE:-api}

if [ -z "$($DOCKER_COMPOSE ps -q "$SERVICE" 2>/dev/null)" ]; then
    echo -e "${RED}Error: service '${SERVICE}' is not running. Start the stack first with ./scripts/install.sh${NC}"
    exit 1
fi

echo -e "${YELLOW}Running AST graph backfill via ${SERVICE}...${NC}"
$DOCKER_COMPOSE exec -T "$SERVICE" yarn ast:backfill:prod "$@"
echo -e "${GREEN}Backfill enqueue done. Builds run in the background — tail logs with:${NC}"
echo "  $DOCKER_COMPOSE logs -f worker | grep -i ast-graph"
