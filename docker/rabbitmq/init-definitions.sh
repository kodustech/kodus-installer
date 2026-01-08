#!/bin/sh
set -e

rabbitmq-server &
server_pid=$!

echo "Waiting for RabbitMQ to start..."
rabbitmqctl wait --pid "$server_pid" --timeout 60

echo "RabbitMQ started. Creating vhosts..."

rabbitmqctl add_vhost kodus-ai || true
rabbitmqctl add_vhost kodus-ast || true

rabbitmqctl set_permissions -p kodus-ai "$RABBITMQ_DEFAULT_USER" ".*" ".*" ".*"
rabbitmqctl set_permissions -p kodus-ast "$RABBITMQ_DEFAULT_USER" ".*" ".*" ".*"

echo "Vhosts created and permissions assigned."

wait "$server_pid"
