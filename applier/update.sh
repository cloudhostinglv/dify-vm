#!/usr/bin/env bash
# update.sh — host-side SOFTWARE UPDATER for a CloudHosting AI-appliance VM.
#
# The web panel (UNPRIVILEGED) can only `touch <data>/.update-request`. This script
# runs ON THE HOST (systemd path unit cloudhosting-updater.path) and is the only
# thing allowed to git-pull the VM repo + drive docker compose. It mirrors apply.sh
# (which only RESTARTS the agent); this one UPDATES code + images:
#   git reset --hard origin/<branch>   # config + any bumped agent/product image pin
#   docker compose pull                 # new panel image (moving tag) + bumped pins
#   docker compose up -d                # recreate with the new images
#   stamp <data>/.deploy-version.json   # so the panel can show the deployed version
#
# This is GENERIC across products — config comes from /etc/cloudhosting-panel.env:
#   PRODUCT, COMPOSE_FILE, DATA_DIR, REPO_DIR (opt), COMPOSE_PROJECT_DIR (opt),
#   UPDATE_BRANCH (opt, default main). Same file the applier reads. Idempotent.
#
# `update.sh --stamp-only` writes the version file WITHOUT changing anything
# (firstboot calls this so the panel knows the current version immediately).
#
# NOTE: agent/product image PINS only move when we bump them in the VM repo and push
# (deliberate pinning). So an update brings the VM to exactly what git says — never a
# blind registry-latest. data/ and .env are gitignored, so reset --hard won't touch
# the panel-written config or secrets.

set -euo pipefail

ENV_FILE="${PANEL_APPLIER_ENV:-/etc/cloudhosting-panel.env}"
# shellcheck disable=SC1090
[ -f "${ENV_FILE}" ] && . "${ENV_FILE}"

PRODUCT="${PRODUCT:-openclaw}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/${PRODUCT}-vm/docker-compose.yml}"
REPO_DIR="${REPO_DIR:-$(dirname "${COMPOSE_FILE}")}"
DATA_DIR="${DATA_DIR:-${REPO_DIR}/data}"
PROJECT_DIR="${COMPOSE_PROJECT_DIR:-${REPO_DIR}}"
BRANCH="${UPDATE_BRANCH:-main}"
APPLIER_LIB="/usr/local/lib/cloudhosting"

log() { printf '[updater %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[updater ERROR] %s\n' "$*" >&2; exit 1; }

stamp_version() {
  local sha short
  sha="$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
  short="$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  mkdir -p "${DATA_DIR}"
  printf '{"vm_sha":"%s","vm_short":"%s","branch":"%s","at":"%s"}\n' \
    "${sha}" "${short}" "${BRANCH}" "$(date -u +%FT%TZ)" > "${DATA_DIR}/.deploy-version.json"
  # the panel (uid 1000) reads this file
  chown 1000:1000 "${DATA_DIR}/.deploy-version.json" 2>/dev/null || true
  chmod 0644 "${DATA_DIR}/.deploy-version.json" 2>/dev/null || true
}

# Stamp-only mode (firstboot): just record the current version, change nothing.
if [ "${1:-}" = "--stamp-only" ]; then
  [ -d "${REPO_DIR}/.git" ] || log "WARN: no git checkout at ${REPO_DIR}; stamping unknown."
  stamp_version
  log "Stamped deploy version from ${REPO_DIR}."
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "docker not found on host."
docker compose version >/dev/null 2>&1 || die "docker compose v2 required."
command -v git >/dev/null 2>&1 || die "git not found on host."
[ -d "${REPO_DIR}/.git" ] || die "no git checkout at ${REPO_DIR}."
[ -f "${COMPOSE_FILE}" ] || die "COMPOSE_FILE not found: ${COMPOSE_FILE}."

git config --global --add safe.directory "${REPO_DIR}" 2>/dev/null || true

log "PRODUCT=${PRODUCT} repo=${REPO_DIR} branch=${BRANCH} compose=${COMPOSE_FILE}"
log "Fetching + resetting to origin/${BRANCH} (config + image pins; data/ + .env are gitignored)…"
git -C "${REPO_DIR}" fetch --all --quiet || die "git fetch failed."
git -C "${REPO_DIR}" reset --hard "origin/${BRANCH}" || die "git reset failed."

# Self-update the installed applier/updater scripts (their logic may have changed).
# Atomic install means the currently-running shell keeps its old inode — safe. Units
# are re-copied best-effort (PathChanged paths are stable; a daemon-reload suffices).
if [ -d "${REPO_DIR}/applier" ]; then
  install -d -m 0755 "${APPLIER_LIB}"
  for s in update.sh apply.sh; do
    [ -f "${REPO_DIR}/applier/${s}" ] && install -m 0755 "${REPO_DIR}/applier/${s}" "${APPLIER_LIB}/${s}" || true
  done
  cp "${REPO_DIR}/applier/"cloudhosting-*.path "${REPO_DIR}/applier/"cloudhosting-*.service /etc/systemd/system/ 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
fi

log "Pulling images (panel moving tag + any bumped pins)…"
docker compose --project-directory "${PROJECT_DIR}" -f "${COMPOSE_FILE}" pull

log "Recreating containers with the new images…"
docker compose --project-directory "${PROJECT_DIR}" -f "${COMPOSE_FILE}" up -d

stamp_version
rm -f "${DATA_DIR}/.update-request" 2>/dev/null || true
log "Update complete (now at $(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?'))."
