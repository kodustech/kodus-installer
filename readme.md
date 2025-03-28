<div align="center">

![Kodus Logo](https://kodus.io/wp-content/uploads/2023/11/Kodus-logo-light.png.webp)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

</div>

## Kodus Installer 

This repository contains the configuration needed to deploy Kodus in your own infrastructure. It's a more flexible alternative to [kodus-cli](https://github.com/kodustech/kodus-cli), providing greater control over system configuration and deployment.

## 🚀 Features

- Complete Kodus environment deployment
- Customizable configuration
- Monitoring with Prometheus and Grafana
- RabbitMQ integration
- Multiple database support (PostgreSQL and MongoDB)
- Isolated Docker environment

## 🛠️ Prerequisites

- Docker
- Docker Compose
- Git

## 🔧 Installation

1. Clone the repository:
```bash
git clone https://github.com/your-username/kodus-deploy-test.git
cd kodus-deploy-test
```

2. Set up environment variables:
```bash
cp .env.example .env
# Edit the .env file with your configurations
```

3. Start the services:
```bash
docker-compose up -d
```

## 📦 Available Services

- **kodus-web**: Application frontend
- **kodus-orchestrator**: Application backend
- **rabbitmq**: Message broker
- **db_kodus_postgres**: PostgreSQL database
- **db_kodus_mongodb**: MongoDB database
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
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 📞 Support

For support, email support@kodus.io or open an issue in the repository.

---

<div align="center">
Made with ❤️ by the Kodus Team
</div>
