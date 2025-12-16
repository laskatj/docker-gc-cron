#!/bin/bash

set -e

IMAGE_NAME="localhost:5003/docker-gc:latest"

echo "Building Docker image: ${IMAGE_NAME}"
docker build -t "${IMAGE_NAME}" .

echo "Pushing Docker image to registry: ${IMAGE_NAME}"
docker push "${IMAGE_NAME}"

echo "Build and push completed successfully!"

