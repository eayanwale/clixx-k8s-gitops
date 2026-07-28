#!/bin/bash
set -euo pipefail

namespace="clixx-prod"
region="us-east-1"
repo="111111111111.dkr.ecr.us-east-1.amazonaws.com/clixx-repository"

aws ecr get-login-password --region "$region" \
  | docker login --username AWS --password-stdin "$repo"

kubectl create secret generic ecr-registry-key \
  --from-file=.dockerconfigjson="$HOME/.docker/config.json" \
  --type=kubernetes.io/dockerconfigjson \
  -n "$namespace" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "ecr-registry-key refreshed in ${namespace}"
