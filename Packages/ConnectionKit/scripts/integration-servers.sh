#!/usr/bin/env bash
# Starts or stops throwaway SFTP and FTP servers for the integration tests.
#   scripts/integration-servers.sh up|down|status
# Run the tests afterwards with: DOCKYARD_INTEGRATION=1 swift test
# Credentials below are test-only and bound to localhost.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$PKG_DIR/.integration"
KEY_DIR="$STATE_DIR/keys"

SSH_PORT=2222
FTP_PORT=2121        # pure-ftpd: MLSD, explicit TLS, EPSV
FTP_LIST_PORT=2122   # vsftpd: no MLSD, exercises the LIST fallback
USER_NAME=dockyard
USER_PASS=dockyard-test-pw
KEY_PASSPHRASE=dockyard-key-pw

SSH_IMAGE=linuxserver/openssh-server:latest
FTP_IMAGE=stilliard/pure-ftpd:latest
VSFTPD_IMAGE=fauria/vsftpd:latest

containers=(dockyard-test-sftp dockyard-test-ftp dockyard-test-vsftpd)

up() {
  mkdir -p "$KEY_DIR"
  chmod 700 "$KEY_DIR"
  keygen() { # file name, passphrase, ssh-keygen type args...
    local name=$1 pass=$2; shift 2
    [ -f "$KEY_DIR/$name" ] || docker run --rm --entrypoint ssh-keygen -v "$KEY_DIR:/keys" "$SSH_IMAGE" \
      -q -N "$pass" -C dockyard-test "$@" -f "/keys/$name"
  }
  keygen id_ed25519 "" -t ed25519
  keygen id_ed25519_enc "$KEY_PASSPHRASE" -t ed25519
  keygen id_rsa "" -t rsa -b 3072
  docker run --rm --entrypoint chown -v "$KEY_DIR:/keys" "$SSH_IMAGE" -R "$(id -u):$(id -g)" /keys
  if [ ! -f "$KEY_DIR/pure-ftpd.pem" ]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 30 -subj "/CN=localhost" \
      -keyout "$KEY_DIR/pure-ftpd.pem" -out "$KEY_DIR/pure-ftpd.crt" 2>/dev/null
    cat "$KEY_DIR/pure-ftpd.crt" >> "$KEY_DIR/pure-ftpd.pem"
  fi
  chmod 644 "$KEY_DIR"/pure-ftpd.pem

  down >/dev/null 2>&1 || true

  local pubkeys
  pubkeys="$(cat "$KEY_DIR/id_ed25519.pub" "$KEY_DIR/id_ed25519_enc.pub" "$KEY_DIR/id_rsa.pub")"
  docker run -d --name dockyard-test-sftp -p "127.0.0.1:$SSH_PORT:2222" \
    -e PUID=1000 -e PGID=1000 -e USER_NAME="$USER_NAME" -e USER_PASSWORD="$USER_PASS" \
    -e PASSWORD_ACCESS=true -e PUBLIC_KEY="$pubkeys" "$SSH_IMAGE" >/dev/null

  docker run -d --name dockyard-test-ftp -p "127.0.0.1:$FTP_PORT:21" -p 127.0.0.1:30000-30009:30000-30009 \
    -e PUBLICHOST=127.0.0.1 -e FTP_USER_NAME="$USER_NAME" -e FTP_USER_PASS="$USER_PASS" \
    -e FTP_USER_HOME=/home/dockyard -e FTP_PASSIVE_PORTS=30000:30009 \
    -v "$KEY_DIR/pure-ftpd.pem:/etc/ssl/private/pure-ftpd.pem:ro" \
    -e ADDED_FLAGS="--tls=1" "$FTP_IMAGE" \
    /run.sh -c 5 -C 5 -l puredb:/etc/pure-ftpd/pureftpd.pdb -E -j >/dev/null  # image default minus -R, which blocks chmod

  docker run -d --name dockyard-test-vsftpd -p "127.0.0.1:$FTP_LIST_PORT:21" -p 127.0.0.1:30100-30109:30100-30109 \
    -e FTP_USER="$USER_NAME" -e FTP_PASS="$USER_PASS" -e PASV_ADDRESS=127.0.0.1 \
    -e PASV_MIN_PORT=30100 -e PASV_MAX_PORT=30109 -e LOG_STDOUT=1 "$VSFTPD_IMAGE" >/dev/null

  wait_for_port "$SSH_PORT" SSH
  wait_for_port "$FTP_PORT" FTP
  wait_for_port "$FTP_LIST_PORT" vsftpd
  echo "Servers are up. Run: DOCKYARD_INTEGRATION=1 swift test"
}

wait_for_port() {
  for _ in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then sleep 2; return 0; fi
    sleep 1
  done
  echo "Timed out waiting for $2 on port $1" >&2
  return 1
}

down() {
  docker rm -f "${containers[@]}" >/dev/null 2>&1 || true
  echo "Servers stopped."
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) docker ps --filter name=dockyard-test --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' ;;
  *) echo "usage: $0 up|down|status" >&2; exit 2 ;;
esac
