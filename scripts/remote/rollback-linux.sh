#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${1:?service name required}"
SYSTEMD_UNIT="${2:?systemd unit required}"
HEALTH_URL="${3:?health url required}"

BASE_DIR="/opt/hanomi/${SERVICE_NAME}"
CURRENT_LINK="${BASE_DIR}/current"
PREVIOUS_FILE="${BASE_DIR}/previous"

log() {
  echo "[$(date -Is)] [$SERVICE_NAME] $*"
}

health_check() {
  local url="$1"
  for i in $(seq 1 12); do
    if curl --fail --silent --show-error --max-time 3 "$url" >/dev/null; then
      log "health check passed"
      return 0
    fi
    sleep 5
  done
  return 1
}

if [[ ! -f "$PREVIOUS_FILE" ]]; then
  log "previous release file missing: $PREVIOUS_FILE"
  exit 1
fi

PREVIOUS_RELEASE="$(cat "$PREVIOUS_FILE")"

if [[ -z "$PREVIOUS_RELEASE" || ! -d "$PREVIOUS_RELEASE" ]]; then
  log "previous release is invalid: $PREVIOUS_RELEASE"
  exit 1
fi

ln -sfn "$PREVIOUS_RELEASE" "$CURRENT_LINK"
systemctl restart "$SYSTEMD_UNIT"
health_check "$HEALTH_URL"
log "rollback completed to $PREVIOUS_RELEASE"
