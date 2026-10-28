#!/bin/bash
# Runs the Swift toolchain in Docker (image dockyard-swift:latest, built from scripts/swift.Dockerfile) against the current directory.
# The image is built when missing and rebuilt whenever the Dockerfile changes (tracked by a hash label).
# Install for a cloud session: ln -sf "$PWD/scripts/swift-docker.sh" /usr/local/bin/swift
pgrep -x dockerd >/dev/null || { nohup dockerd >/tmp/dockerd.log 2>&1 & for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done; }
mkdir -p /root/.swift-docker-cache
here="$(dirname "$(readlink -f "$0")")"
IMAGE=dockyard-swift:latest
hash="$(sha256sum "$here/swift.Dockerfile" | cut -c1-16)"
if [ "$(docker image inspect -f '{{index .Config.Labels "dockyard.dockerfile"}}' "$IMAGE" 2>/dev/null)" != "$hash" ]; then
  echo "Building $IMAGE ..." >&2
  docker build --network host -q --label "dockyard.dockerfile=$hash" -t "$IMAGE" -f "$here/swift.Dockerfile" "$here" >&2 || exit 1
fi
env_args=()
for v in $(compgen -e | grep '^DOCKYARD_'); do env_args+=(-e "$v"); done
exec docker run --rm -i --network host \
  -v /home/user:/home/user -v /root/.swift-docker-cache:/root/.cache \
  -v /root/.ccr/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro \
  -e HTTPS_PROXY -e HTTP_PROXY -e NO_PROXY -e https_proxy -e http_proxy -e no_proxy \
  "${env_args[@]}" -w "$PWD" "$IMAGE" swift "$@"
