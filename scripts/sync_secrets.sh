#!/bin/bash
set -euo pipefail

namespace="clixx-prod"
secret_name="clixx-secrets"
ssm_prefix="/stack/clixx"

declare -A db_map=(
  [dbname]=DB_NAME
  [db_user]=DB_USER
  [db_password]=DB_PASSWORD
  [db_host]=DB_HOST
)

args=(create secret generic "$secret_name" -n "$namespace")

for ssm_key in "${!db_map[@]}"; do
  value=$(aws ssm get-parameter --name "${ssm_prefix}/${ssm_key}" \
    --with-decryption --query 'Parameter.Value' --output text)
  args+=(--from-literal="${db_map[$ssm_key]}=${value}")
done

kubectl "${args[@]}" --dry-run=client -o yaml | kubectl apply -f -
echo "clixx-secrets synced in ${namespace}"