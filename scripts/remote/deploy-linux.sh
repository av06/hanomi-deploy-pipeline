#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${1:?service name required}"
RELEASE_ID="${2:?release id required}"
ARTIFACT_PATH="${3:?artifact path required}"
SYSTEMD_UNIT="${4:?systemd unit required}"
HEALTH_URL="${5:?health url required}"

BASE_DIR="/opt/hanomi/${SERVICE_NAME}"
RELEASES_DIR="${BASE_DIR}/releases"
NEW_RELEASE_DIR="${RELEASES_DIR}/${RELEASE_ID}"
CURRENT_LINK="${BASE_DIR}/current"
PREVIOUS_FILE="${BASE_DIR}/previous"

log() {
  echo "[$(date -Is)] [$SERVICE_NAME] $*"
}

health_check() {
  local url="$1"
  local attempts="${2:-18}"
  local sleep_seconds="${3:-5}"

  for i in $(seq 1 "$attempts"); do
    if curl --fail --silent --show-error --max-time 3 "$url" >/dev/null; then
      log "health check passed on attempt ${i}"
      return 0
    fi
    log "health check attempt ${i}/${attempts} failed; retrying in ${sleep_seconds}s"
    sleep "$sleep_seconds"
  done

  return 1
}

rollback() {
  log "attempting rollback"
  if [[ -f "$PREVIOUS_FILE" ]]; then
    local previous
    previous="$(cat "$PREVIOUS_FILE")"
    if [[ -n "$previous" && -d "$previous" ]]; then
      ln -sfn "$previous" "$CURRENT_LINK"
      systemctl restart "$SYSTEMD_UNIT"
      health_check "$HEALTH_URL" 12 5 || true
      log "rolled back to $previous"
      return 0
    fi
  fi

  log "no valid previous release found; manual intervention required"
  return 1
}

main() {
  log "starting deployment release=${RELEASE_ID} artifact=${ARTIFACT_PATH}"

  if [[ ! -f "$ARTIFACT_PATH" ]]; then
    log "artifact not found: $ARTIFACT_PATH"
    exit 1
  fi

  mkdir -p "$RELEASES_DIR"
  rm -rf "$NEW_RELEASE_DIR"
  mkdir -p "$NEW_RELEASE_DIR"

  if [[ -L "$CURRENT_LINK" ]]; then
    readlink -f "$CURRENT_LINK" > "$PREVIOUS_FILE"
    log "previous release: $(cat "$PREVIOUS_FILE")"
  else
    : > "$PREVIOUS_FILE"
    log "no previous release found"
  fi

  tar -xzf "$ARTIFACT_PATH" -C "$NEW_RELEASE_DIR"
  chown -R root:root "$NEW_RELEASE_DIR"

  ln -sfn "$NEW_RELEASE_DIR" "$CURRENT_LINK"
  log "current switched to $NEW_RELEASE_DIR"

  systemctl restart "$SYSTEMD_UNIT"
  log "systemd unit restarted: $SYSTEMD_UNIT"

  if ! health_check "$HEALTH_URL"; then
    log "health check failed after deployment"
    rollback
    exit 1
  fi

  # Keep only the last 5 releases, but never delete current or previous.
  local previous_release=""
  if [[ -s "$PREVIOUS_FILE" ]]; then
    previous_release="$(cat "$PREVIOUS_FILE")"
  fi

  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
    | sort -rn \
    | awk 'NR>5 {print $2}' \
    | while IFS= read -r release_dir; do
        if [[ "$release_dir" != "$NEW_RELEASE_DIR" && "$release_dir" != "$previous_release" ]]; then
          rm -rf "$release_dir"
        fi
      done

  log "deployment completed successfully"
}

main "$@"
