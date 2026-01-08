# Migration Guide: 1.x -> 2.0

This release introduces breaking changes in the installer stack. Use this guide
to upgrade safely.

## Breaking changes

- API split into services: `api`, `worker`, `webhooks` (replaces `kodus-orchestrator`)
- RabbitMQ is now required and uses a custom image (plugins + metrics)
- MCP manager service added (`kodus-mcp-manager`)
- New required environment variables for RabbitMQ and MCP
- Default API container name changed to `kodus_api`

## Upgrade steps

1) Back up your data volumes
```bash
# Example: snapshot or backup these volumes if you use them
docker volume ls | grep -E 'pgdata|mongodbdata|rabbitmq-data-prod'
```

2) Stop the current stack
```bash
docker compose down
```

3) Update the repository
```bash
git pull
```

4) Update your `.env`
Add or update the following variables:
```bash
WEBHOOKS_PORT=3332

RABBITMQ_HOSTNAME=rabbitmq
RABBITMQ_DEFAULT_USER=kodus
RABBITMQ_DEFAULT_PASS=kodus
API_RABBITMQ_URI=amqp://kodus:kodus@rabbitmq:5672/kodus-ai
API_RABBITMQ_ENABLED=true

API_MCP_SERVER_ENABLED=true
API_KODUS_SERVICE_MCP_MANAGER=http://kodus-mcp-manager:3101
API_KODUS_MCP_SERVER_URL=http://localhost:3001/mcp

# Optional: align API container name
GLOBAL_API_CONTAINER_NAME=kodus_api
```

5) Start the new stack
```bash
./scripts/install.sh
```

6) Run diagnostics if needed
```bash
./scripts/doctor.sh
```

## Notes

- If you referenced the old container name (`kodus-orchestrator`) in reverse
  proxies, monitoring, or scripts, update it to `api` or `kodus_api`.
- Ports used by new services: `3101` and `9140` (MCP manager), `15692` (RabbitMQ metrics).
