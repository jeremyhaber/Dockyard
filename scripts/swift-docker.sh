#!/bin/bash
# Runs the official Swift toolchain (Docker image swift:latest) against the current directory.
# Install for a cloud session: ln -sf "$PWD/scripts/swift-docker.sh" /usr/local/bin/swift
pgrep -x dockerd >/dev/null || { nohup dockerd >/tmp/dockerd.log 2>&1 & for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done; }
mkdir -p /root/.swift-docker-cache
IMAGE=dockyard-swift:latest
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build --network host -t "$IMAGE" -f "$(dirname "$(readlink -f "$0")")/swift.Dockerfile" "$(dirname "$(readlink -f "$0")")" >&2
env_args=()
for v in $(compgen -e | grep '^DOCKYARD_'); do env_args+=(-e "$v"); done
exec docker run --rm -i --network host \
  -v /home/user:/home/user -v /root/.swift-docker-cache:/root/.cache \
  -v /root/.ccr/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro \
  -e HTTPS_PROXY -e HTTP_PROXY -e NO_PROXY -e https_proxy -e http_proxy -e no_proxy \
  "${env_args[@]}" -w "$PWD" "$IMAGE" swift "$@"
