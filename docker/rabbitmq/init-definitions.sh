#!/bin/sh
set -e

rabbitmq-server &
server_pid=$!

echo "Waiting for RabbitMQ to start..."
rabbitmqctl wait --pid "$server_pid" --timeout 60

echo "RabbitMQ started. Creating vhost..."

rabbitmqctl add_vhost kodus-ai || true

rabbitmqctl set_permissions -p kodus-ai "$RABBITMQ_DEFAULT_USER" ".*" ".*" ".*"

echo "Vhost created and permissions assigned."

wait "$server_pid"
