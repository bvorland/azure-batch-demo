#!/bin/bash
# build-and-push-docker.sh
#
# Helper script to build and push Docker image to Azure Container Registry
# Usage: ./build-and-push-docker.sh <acr-name> [<image-tag>]

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <acr-name> [<image-tag>]"
  echo "Example: $0 myacr latest"
  exit 1
fi

ACR_NAME=$1
IMAGE_TAG=${2:-latest}
IMAGE_NAME="batch-gpu-pytorch"

echo "Building Docker image..."
docker build -f Dockerfile.gpu -t ${IMAGE_NAME}:${IMAGE_TAG} .

echo "Logging in to ACR..."
az acr login --name ${ACR_NAME}

echo "Tagging image for ACR..."
docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}

echo "Pushing image to ACR..."
docker push ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}

echo "Image successfully pushed to ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"
