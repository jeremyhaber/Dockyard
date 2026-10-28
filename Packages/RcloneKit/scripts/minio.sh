#!/usr/bin/env bash
# Starts or stops a throwaway MinIO (S3-compatible) server for the integration tests.
#   scripts/minio.sh up|down|status
# Then: DOCKYARD_INTEGRATION=1 DOCKYARD_LIBRCLONE=<path to librclone> swift test
# Credentials are test-only and bound to localhost.
set -euo pipefail

NAME=dockyard-test-minio
IMAGE=bitnamilegacy/minio:latest  # minio/minio is no longer published on Docker Hub
PORT=9000
ACCESS_KEY=dockyard
SECRET_KEY=dockyard-test-secret

case "${1:-}" in
  up)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" -p "127.0.0.1:$PORT:9000" \
      -e MINIO_ROOT_USER="$ACCESS_KEY" -e MINIO_ROOT_PASSWORD="$SECRET_KEY" \
      "$IMAGE" >/dev/null
    for _ in $(seq 1 60); do
      if curl -fsS "http://127.0.0.1:$PORT/minio/health/live" >/dev/null 2>&1; then
        echo "MinIO ready on :$PORT"
        exit 0
      fi
      sleep 1
    done
    echo "MinIO did not become ready" >&2
    exit 1
    ;;
  down)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo "MinIO stopped"
    ;;
  status)
    docker ps --filter "name=$NAME" --format '{{.Names}} {{.Status}}'
    ;;
  *)
    echo "usage: $0 up|down|status" >&2
    exit 2
    ;;
esac
