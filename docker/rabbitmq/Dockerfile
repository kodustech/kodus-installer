FROM rabbitmq:4.2.2-management

# Install plugins that are not bundled in the official image.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends wget ca-certificates python3; \
    wget -O /usr/local/bin/rabbitmqadmin https://raw.githubusercontent.com/rabbitmq/rabbitmq-server/v4.2.2/deps/rabbitmq_management/bin/rabbitmqadmin; \
    chmod +x /usr/local/bin/rabbitmqadmin; \
    wget -O /opt/rabbitmq/plugins/rabbitmq_delayed_message_exchange.ez \
      https://github.com/rabbitmq/rabbitmq-delayed-message-exchange/releases/download/v4.2.0/rabbitmq_delayed_message_exchange-4.2.0.ez; \
    rabbitmq-plugins enable --offline \
      rabbitmq_delayed_message_exchange \
      rabbitmq_management \
      rabbitmq_prometheus; \
    rm -rf /var/lib/apt/lists/*

# Provide default configuration artifacts for local development.
COPY rabbitmq.conf /etc/rabbitmq/rabbitmq.conf
COPY init-definitions.sh /usr/local/bin/init-definitions.sh
RUN chmod +x /usr/local/bin/init-definitions.sh
