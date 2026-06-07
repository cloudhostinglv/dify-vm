#!/usr/bin/env bash
# firstboot.sh — one-shot first-boot provisioning for the Dify per-client VM.
# Runs ONCE via dify-firstboot.service. Idempotent; disables itself at the end.
#
# Dify is special: it has no compose of ours — provision.sh clones Dify's upstream
# ~11-container stack + overlays config. We orchestrate:
#   1. derive PANEL_DOMAIN; write the Dify .env.overlay (DOMAIN, generated SECRET_KEY,
#      nginx on host :8080 / SSL port moved OFF 8443, https off, optional avots).
#   2. run provision.sh -> brings up the Dify stack (nginx on 127.0.0.1:8080).
#   3. bring up panel-compose.yml -> our panel (127.0.0.1:8081) + host-network Caddy
#      (:443 -> Dify, :8443 -> panel, :80 ACME).
#   4. disable this oneshot.
# Dify login + model provider are configured inside Dify's console (it's a builder;
# the avots provider wiring is best-effort/manual — see provision.sh).

set -euo pipefail

APP_DIR="/opt/dify-vm"
ENV_FILE="${APP_DIR}/.env"                 # compose-level: PANEL_PASSWORD/DOMAIN
DIFY_DIR="${APP_DIR}/state"                # provision.sh clones upstream under here
OVERLAY_FILE="${DIFY_DIR}/.env.overlay"
PANEL_COMPOSE="${APP_DIR}/panel-compose.yml"
PANEL_UID="${PANEL_UID:-1000}"; PANEL_GID="${PANEL_GID:-1000}"

log() { printf '[firstboot %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[firstboot ERROR] %s\n' "$*" >&2; exit 1; }

cd "${APP_DIR}" || die "missing ${APP_DIR}"
touch "${ENV_FILE}"; chmod 0600 "${ENV_FILE}"
mkdir -p "${DIFY_DIR}"

# shellcheck disable=SC1090
set -a && . "${ENV_FILE}" && set +a || true

# --- 1. Derive PANEL_DOMAIN if blank ------------------------------------------------
if [ -z "${PANEL_DOMAIN:-}" ]; then
  IP="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -n1)"
  [ -n "${IP}" ] || IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "${IP}" ] || die "could not determine primary IPv4 to derive PANEL_DOMAIN"
  O3="$(printf '%s' "${IP}" | cut -d. -f3)"; O4="$(printf '%s' "${IP}" | cut -d. -f4)"
  PANEL_DOMAIN="vps-${O3}-${O4}.cloudhosting.lv"
  log "Derived PANEL_DOMAIN=${PANEL_DOMAIN} from IP ${IP}"
  if grep -q '^PANEL_DOMAIN=' "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=${PANEL_DOMAIN}|" "${ENV_FILE}"
  else
    printf 'PANEL_DOMAIN=%s\n' "${PANEL_DOMAIN}" >> "${ENV_FILE}"
  fi
else
  log "PANEL_DOMAIN already set: ${PANEL_DOMAIN}"
fi
export PANEL_DOMAIN

# --- 2. Write the Dify overlay (preserve SECRET_KEY across re-runs) ------------------
SECRET_KEY=""
[ -f "${OVERLAY_FILE}" ] && SECRET_KEY="$(sed -n 's/^SECRET_KEY=\(.*\)$/\1/p' "${OVERLAY_FILE}" | head -n1)"
[ -n "${SECRET_KEY}" ] || SECRET_KEY="$(openssl rand -base64 42 | tr -d '\n')"
umask 077
cat > "${OVERLAY_FILE}" <<EOF
SECRET_KEY=${SECRET_KEY}
DOMAIN=${PANEL_DOMAIN}
AVOTS_API_KEY=${AVOTS_API_KEY:-}
AVOTS_BASE_URL=https://api.avots.ai/openai/v1
AVOTS_MODEL=anthropic/claude-opus-4.8
AVOTS_MODEL_CONTEXT=200000
NGINX_HTTPS_ENABLED=false
EXPOSE_NGINX_PORT=8080
EXPOSE_NGINX_SSL_PORT=8444
FORCE_VERIFYING_SIGNATURE=false
PLUGIN_MAX_PACKAGE_SIZE=524288000
NGINX_CLIENT_MAX_BODY_SIZE=100M
EOF
log "Wrote ${OVERLAY_FILE} (Dify nginx on :8080; SSL port 8444 so it won't touch panel :8443)"

# --- 3. Bring up the Dify upstream stack --------------------------------------------
log "Running provision.sh (clone + start Dify upstream stack)…"
chmod +x "${APP_DIR}/provision.sh"
DIFY_DIR="${DIFY_DIR}" bash "${APP_DIR}/provision.sh"

# --- 4. Panel side-stack (panel + host-network Caddy) -------------------------------
mkdir -p "${APP_DIR}/paneldata"
chown -R "${PANEL_UID}:${PANEL_GID}" "${APP_DIR}/paneldata"
chmod 0700 "${APP_DIR}/paneldata"
log "Bringing up the panel + Caddy side-stack…"
docker compose -f "${PANEL_COMPOSE}" pull
docker compose -f "${PANEL_COMPOSE}" up -d

# --- 4b. Install the host-side software updater (panel "Update software" button) -----
# The panel (unprivileged) writes ./paneldata/.update-request; this host updater
# git-pulls dify-vm + docker compose -f panel-compose.yml pull/up. NOTE: this updates
# OUR panel side-stack + config; Dify's own upstream stack (under state/) updates via
# Dify's own channel, not here.
log "Installing updater units"
APPLIER_LIB="/usr/local/lib/cloudhosting"
install -d -m 0755 "${APPLIER_LIB}"
install -m 0755 "${APP_DIR}/applier/update.sh" "${APPLIER_LIB}/update.sh"
cp "${APP_DIR}/applier/cloudhosting-updater.path"    /etc/systemd/system/
cp "${APP_DIR}/applier/cloudhosting-updater.service" /etc/systemd/system/
cat > /etc/cloudhosting-panel.env <<EOF
PRODUCT=dify
COMPOSE_FILE=${PANEL_COMPOSE}
COMPOSE_PROJECT_DIR=${APP_DIR}
REPO_DIR=${APP_DIR}
DATA_DIR=${APP_DIR}/paneldata
UPDATE_BRANCH=main
EOF
chmod 0644 /etc/cloudhosting-panel.env
systemctl daemon-reload
systemctl enable --now cloudhosting-updater.path
log "Updater enabled (watching ${APP_DIR}/paneldata/.update-request)"
"${APPLIER_LIB}/update.sh" --stamp-only || log "WARN: initial version stamp failed"

# --- 5. Disable this oneshot --------------------------------------------------------
log "Disabling dify-firstboot.service (provisioning complete)"
systemctl disable dify-firstboot.service 2>/dev/null || true

log "First boot complete. Panel: https://${PANEL_DOMAIN}:8443  ·  Dify: https://${PANEL_DOMAIN}/install (first run: create admin)"
