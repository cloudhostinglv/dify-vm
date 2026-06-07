#!/usr/bin/env bash
# firstboot.sh — one-shot first-boot provisioning for the Dify per-client VM.
# Runs ONCE via dify-firstboot.service. Idempotent; disables itself at the end.
#
# Vanilla product: Dify runs its OWN upstream stack on its OWN standard port, with
# NO CloudHosting panel/Caddy layer. provision.sh clones Dify's upstream ~11-container
# stack + overlays our per-VM config. Steps:
#   1. derive DOMAIN; write the Dify .env.overlay (generated SECRET_KEY, http base URL,
#      nginx on the standard :80, https off, optional avots for the manual wiring hint).
#   2. run provision.sh -> brings up the Dify stack (nginx on host :80).
#   3. disable this oneshot.
# Dify login + model provider are configured inside Dify's console at /install
# (avots = OpenAI-API-compatible provider; see provision.sh for the wiring hint).
#
# NOTE: served over plain HTTP on :80 (no TLS here, by design). Put a TLS terminator
# in front if you want HTTPS (and flip APP_BASE_URL/NGINX_HTTPS_ENABLED).

set -euo pipefail

APP_DIR="/opt/dify-vm"
ENV_FILE="${APP_DIR}/.env"                 # holds PANEL_DOMAIN (+ optional AVOTS_API_KEY)
DIFY_DIR="${APP_DIR}/state"                # provision.sh clones upstream under here
OVERLAY_FILE="${DIFY_DIR}/.env.overlay"

log() { printf '[firstboot %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[firstboot ERROR] %s\n' "$*" >&2; exit 1; }

cd "${APP_DIR}" || die "missing ${APP_DIR}"
touch "${ENV_FILE}"; chmod 0600 "${ENV_FILE}"
mkdir -p "${DIFY_DIR}"

# shellcheck disable=SC1090
set -a && . "${ENV_FILE}" && set +a || true

# --- 1. Derive PANEL_DOMAIN if blank (used for Dify's public URLs) ------------------
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
APP_BASE_URL=http://${PANEL_DOMAIN}
AVOTS_API_KEY=${AVOTS_API_KEY:-}
AVOTS_BASE_URL=https://api.avots.ai/openai/v1
AVOTS_MODEL=anthropic/claude-opus-4.8
AVOTS_MODEL_CONTEXT=200000
NGINX_HTTPS_ENABLED=false
EXPOSE_NGINX_PORT=80
EXPOSE_NGINX_SSL_PORT=443
FORCE_VERIFYING_SIGNATURE=false
PLUGIN_MAX_PACKAGE_SIZE=524288000
NGINX_CLIENT_MAX_BODY_SIZE=100M
EOF
log "Wrote ${OVERLAY_FILE} (Dify nginx on the standard :80, http base ${PANEL_DOMAIN})"

# --- 3. Bring up the Dify upstream stack --------------------------------------------
log "Running provision.sh (clone + start Dify upstream stack)…"
chmod +x "${APP_DIR}/provision.sh"
DIFY_DIR="${DIFY_DIR}" bash "${APP_DIR}/provision.sh"

# --- 4. Disable this oneshot --------------------------------------------------------
log "Disabling dify-firstboot.service (provisioning complete)"
systemctl disable dify-firstboot.service 2>/dev/null || true

log "First boot complete. Dify: http://${PANEL_DOMAIN}/install (first run: create admin)"
