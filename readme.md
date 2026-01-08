<div align="center">

<img src="https://kodus.io/wp-content/uploads/2025/04/kodusinstaller.png" alt="Kodus Installer Banner">

</div>

## Kodus Installer 

This repository contains the configuration needed to deploy Kodus in your own infrastructure.

## 🛠️ Prerequisites

- Docker
- Docker Compose
- Git

## 🔧 Installation

`./scripts/install.sh`

For a full walkthrough on deploying, check out our docs: https://docs.kodus.io/how_to_deploy/en/deploy_kodus/generic_vm

Upgrading from 1.x? See `MIGRATION.md`.

## External Databases or RabbitMQ

If you already have PostgreSQL/MongoDB or RabbitMQ, you can disable the local containers and point Kodus to the external services.

Example `.env`:
```bash
USE_LOCAL_DB=false
USE_LOCAL_RABBITMQ=false

API_PG_DB_HOST=your-postgres-host
API_PG_DB_PORT=5432
API_MG_DB_HOST=your-mongodb-host
API_MG_DB_PORT=27017

API_RABBITMQ_URI=amqp://user:pass@your-rabbitmq-host:5672/kodus-ai
```

When set to `false`, the installer skips starting local services and related health checks.

## Troubleshooting

Start with the doctor script to pinpoint common setup issues: `./scripts/doctor.sh`

Common fixes:
- Docker daemon not running: `docker info`
- Ports already in use: `3000`, `3001`, `3101`, `3332`, `5432`, `9140`, `27017`, `5672`, `15672`, `15692`
- `.env` missing or invalid: copy `.env.example` and fill required vars
- RabbitMQ connection errors: ensure `API_RABBITMQ_URI` matches `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS`, and vhost `kodus-ai`
- Database errors: confirm Postgres/Mongo credentials, then rerun `./scripts/setup-db.sh`
- Service crash or boot loop: check logs with `docker compose logs -f api` (or `worker`, `webhooks`, `rabbitmq`)

## Service Architecture

```mermaid
flowchart LR
  user((User)) --> web[kodus-web]
  web --> api[api]
  web --> webhooks[webhooks]
  api --> mcp[kodus-mcp-manager]
  api --> rabbitmq[(rabbitmq)]
  worker[worker] --> rabbitmq
  api --> pg[(db_kodus_postgres)]
  api --> mongo[(db_kodus_mongodb)]
  mcp --> pg
  webhooks --> pg
  webhooks --> mongo
```

## 📦 Available Services

- **kodus-web**: Application frontend
- **api**: Application API
- **worker**: Background jobs
- **webhooks**: Webhooks service
- **kodus-mcp-manager**: MCP manager service
- **rabbitmq**: Message broker
- **db_kodus_postgres**: PostgreSQL database
- **db_kodus_mongodb**: MongoDB database
- **migration**: One-off migrations runner
- **prometheus**: Monitoring system
- **grafana**: Metrics visualization dashboard

## 🔐 Security

- All credentials are managed through environment variables
- Secure inter-service communication
- Container isolation
- Dedicated Docker networks

## 🤝 Contributing

Contributions are always welcome! Please read the contribution guidelines before submitting a pull request.

1. Fork the project
2. Create your Feature Branch (`git checkout -b feat/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feat/amazing-feature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 📞 Support

For support, email support@kodus.io or open an issue in the repository.

---

<div align="center">
Made with ❤️ by the Kodus Team
</div>
