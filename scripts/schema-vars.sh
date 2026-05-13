#!/usr/bin/env bash
# AUTO-GENERATED from kodus-ai/.env.schema. Do NOT edit by hand.
# Sourced by scripts/install.sh, scripts/doctor.sh, scripts/generate-secrets.sh
# Run `yarn env:generate --apply --installer` in kodus-ai to regenerate.

# Vars the installer must see set before booting the stack.
# Derived from `@required` in the schema (self-hosted audience).
KODUS_REQUIRED_VARS=(
    API_PG_DB_PASSWORD
    API_MG_DB_PASSWORD
    WORKER_ROLE
    API_JWT_SECRET
    API_JWT_REFRESH_SECRET
    API_CRYPTO_KEY
    CODE_MANAGEMENT_SECRET
    WEB_NEXTAUTH_SECRET
    NEXTAUTH_SECRET
)

# Secrets the installer can mint unattended.
# Format: VAR=method  (hex32 | base64-32 | base64url-32 | mirror:OTHER_VAR)
# Derived from `kodus: autogen=...` in the schema.
KODUS_AUTOGEN_SECRETS=(
    "API_PG_DB_PASSWORD=hex32"
    "API_MG_DB_PASSWORD=hex32"
    "API_JWT_SECRET=base64-32"
    "API_JWT_REFRESH_SECRET=base64-32"
    "API_CRYPTO_KEY=hex32"
    "CODE_MANAGEMENT_SECRET=hex32"
    "CODE_MANAGEMENT_WEBHOOK_TOKEN=base64url-32"
    "WEB_NEXTAUTH_SECRET=mirror:NEXTAUTH_SECRET"
    "API_MCP_MANAGER_JWT_SECRET=base64-32"
    "API_MCP_MANAGER_ENCRYPTION_SECRET=hex32"
    "NEXTAUTH_SECRET=base64-32"
)
