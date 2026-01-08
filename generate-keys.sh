#!/bin/bash

set -e

if [ ! -x "./scripts/generate-secrets.sh" ]; then
    echo "Error: ./scripts/generate-secrets.sh not found or not executable."
    exit 1
fi

./scripts/generate-secrets.sh
