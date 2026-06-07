#!/usr/bin/env bash
# provision.sh — first-boot provisioning for a single-tenant Dify VM backed by avots.ai.
#
# Idempotent: safe to re-run. Steps:
#   1. Clone Dify at a PINNED tag into dify-upstream/  (or reuse a baked checkout).
#   2. Build docker/.env from upstream .env.example + our per-VM overlay.
#   3. Bring the official ~11-container stack up with `docker compose up -d`.
#   4. Install the OpenAI-API-compatible model-provider plugin from a local
#      (offline) .difypkg if one is present.
#   5. BEST-EFFORT: register the avots provider via the authenticated console API.
#      If that fails (likely — the endpoint is internal/undocumented), print
#      clear manual console instructions instead.
#
# This is a PROVISIONING + OVERLAY script. We do NOT vendor Dify's giant compose;
# the supported path is Dify's own docker/docker-compose.yaml at a pinned tag.
#
# Usage:
#   sudo DIFY_DIR=/srv/avots-vm/dify bash provision.sh
# Per-VM values come from $DIFY_DIR/.env.overlay (written by cloud-init).

set -euo pipefail

# ---- Pinned version ----------------------------------------------------------
# Re-verify before baking a new image. As of 2026-06-05 the latest 1.14.x is
# 1.14.2 (released 2026-05-19). Do NOT jump to 2.0.0 for a baked image yet
# (unproven for this flow). 1.11.0+ is required anyway: earlier versions leaked
# provider API keys in plaintext to the frontend (CVE-2025-67732 /
# GHSA-phpv-94hg-fv9g) — exactly the avots key we store here.
DIFY_TAG="${DIFY_TAG:-1.14.2}"

# ---- Layout ------------------------------------------------------------------
DIFY_DIR="${DIFY_DIR:-/srv/avots-vm/dify}"
UPSTREAM_DIR="${DIFY_DIR}/dify-upstream"
DOCKER_DIR="${UPSTREAM_DIR}/docker"
OVERLAY_FILE="${DIFY_DIR}/.env.overlay"
# Offline plugin package, deps bundled via dify-plugin-repackaging. Bake this
# into the image. Glob so the exact filename/version need not be hardcoded.
PLUGIN_GLOB="${DIFY_DIR}/plugins/openai_api_compatible*.difypkg"

log() { printf '\n\033[1;34m[provision]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[provision:WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\n\033[1;31m[provision:ERR]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- Preconditions -----------------------------------------------------------
command -v docker >/dev/null || die "docker not installed"
docker compose version >/dev/null 2>&1 || die "docker compose v2 (>=2.24) required"
command -v git >/dev/null || die "git not installed"
command -v openssl >/dev/null || die "openssl not installed"
[ -f "${OVERLAY_FILE}" ] || die "missing overlay env: ${OVERLAY_FILE} (cloud-init should write it)"

# ---- Load overlay ------------------------------------------------------------
# shellcheck disable=SC1090
set -a; . "${OVERLAY_FILE}"; set +a

: "${DOMAIN:?DOMAIN must be set in ${OVERLAY_FILE}}"
AVOTS_API_KEY="${AVOTS_API_KEY:-}"
AVOTS_BASE_URL="${AVOTS_BASE_URL:-https://api.avots.ai/openai/v1}"
AVOTS_MODEL="${AVOTS_MODEL:-anthropic/claude-opus-4.8}"
AVOTS_MODEL_CONTEXT="${AVOTS_MODEL_CONTEXT:-200000}"
EXPOSE_NGINX_PORT="${EXPOSE_NGINX_PORT:-80}"
EXPOSE_NGINX_SSL_PORT="${EXPOSE_NGINX_SSL_PORT:-443}"

# ---- 1. Clone Dify at the pinned tag (idempotent) ----------------------------
# Alternative for golden images: bake the checkout at ${UPSTREAM_DIR} during
# image build and skip the clone (no network at first boot). The check below
# treats an existing checkout as already-baked.
if [ -d "${DOCKER_DIR}" ]; then
  log "Dify upstream already present at ${UPSTREAM_DIR} (baked or prior run) — skipping clone."
else
  log "Cloning Dify ${DIFY_TAG} into ${UPSTREAM_DIR} ..."
  git clone --depth 1 --branch "${DIFY_TAG}" \
    https://github.com/langgenius/dify.git "${UPSTREAM_DIR}"
fi
[ -f "${DOCKER_DIR}/docker-compose.yaml" ] || die "no docker-compose.yaml under ${DOCKER_DIR}"

# ---- 2. Build docker/.env from upstream example + per-VM overlay --------------
ENV_FILE="${DOCKER_DIR}/.env"
if [ ! -f "${ENV_FILE}" ]; then
  log "Creating ${ENV_FILE} from upstream .env.example"
  cp "${DOCKER_DIR}/.env.example" "${ENV_FILE}"
fi

# Per-VM SECRET_KEY: unique per VM, never the shared/auto default.
# (1.14.x auto-generates one into the storage volume if left blank, but we set
# it explicitly so it is captured in the build record and stays stable across
# volume resets.)
if [ -z "${SECRET_KEY:-}" ]; then
  SECRET_KEY="$(openssl rand -base64 42)"
  warn "SECRET_KEY not provided in overlay — generated a fresh one. Persist it: a new key cannot decrypt existing stored credentials."
fi

# set_env KEY VALUE — replace KEY=... in place, or append if absent.
set_env() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    # Use a non-/ delimiter; values contain slashes (URLs) and '+' (base64).
    python3 - "$ENV_FILE" "$key" "$val" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
out = []
for ln in lines:
    if ln.startswith(key + "="):
        out.append(f"{key}={val}")
    else:
        out.append(ln)
open(path, "w").write("\n".join(out) + "\n")
PY
  else
    printf '%s=%s\n' "${key}" "${val}" >> "${ENV_FILE}"
  fi
}

# Public base URL. Vanilla install serves plain HTTP on :80, so the overlay sets
# APP_BASE_URL=http://${DOMAIN}; fall back to https for a TLS-fronted deployment.
BASE="${APP_BASE_URL:-https://${DOMAIN}}"
log "Writing per-VM values into ${ENV_FILE} (base ${BASE})"
set_env SECRET_KEY                "${SECRET_KEY}"

# Public URLs — all behind Caddy's TLS on ${DOMAIN}.
set_env CONSOLE_API_URL           "${BASE}"
set_env CONSOLE_WEB_URL           "${BASE}"
set_env SERVICE_API_URL           "${BASE}"
set_env APP_API_URL               "${BASE}"
set_env APP_WEB_URL               "${BASE}"
set_env FILES_URL                 "${BASE}"

# nginx: plain HTTP on the standard host port (no external TLS terminator here).
set_env NGINX_HTTPS_ENABLED       "false"
set_env EXPOSE_NGINX_PORT         "${EXPOSE_NGINX_PORT}"
set_env EXPOSE_NGINX_SSL_PORT     "${EXPOSE_NGINX_SSL_PORT}"
set_env NGINX_CLIENT_MAX_BODY_SIZE "${NGINX_CLIENT_MAX_BODY_SIZE:-100M}"

# Offline plugin install: allow unsigned local package + larger uploads.
set_env FORCE_VERIFYING_SIGNATURE "false"
set_env PLUGIN_MAX_PACKAGE_SIZE   "${PLUGIN_MAX_PACKAGE_SIZE:-524288000}"

# Vector store stays at the default (weaviate). Leave VECTOR_STORE as upstream.

# ---- 3. Bring the stack up ---------------------------------------------------
log "Starting Dify stack (docker compose up -d) ..."
( cd "${DOCKER_DIR}" && docker compose up -d )

# Wait for the API/console to answer before any API wiring.
log "Waiting for Dify console to become ready on 127.0.0.1:${EXPOSE_NGINX_PORT} ..."
ready=""
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${EXPOSE_NGINX_PORT}/console/api/setup" 2>/dev/null; then
    ready=1; break
  fi
  sleep 5
done
[ -n "${ready}" ] || warn "Console did not answer in time; continuing (stack may still be initializing)."

# ---- 4. Install the OpenAI-API-compatible plugin from a local package ---------
# Offline path: bake a deps-bundled package built with dify-plugin-repackaging
# (./plugin_repackaging.sh market langgenius openai_api_compatible <ver>) into
# ${DIFY_DIR}/plugins/. With FORCE_VERIFYING_SIGNATURE=false it installs without
# marketplace access. If no package is present we fall through to the manual
# step (admin can install it from the Marketplace once they have console access).
PLUGIN_PKG="$(ls -1 ${PLUGIN_GLOB} 2>/dev/null | head -n1 || true)"
if [ -n "${PLUGIN_PKG}" ]; then
  log "Found offline plugin package: ${PLUGIN_PKG}"
  warn "Local-package plugin install is exposed through the AUTHENTICATED console UI/API."
  warn "It cannot run until the admin account exists (one-time /install). The reliable"
  warn "path is: finish admin setup, then upload this .difypkg via Plugins → Install"
  warn "from Local Package File. Package staged for that step."
else
  warn "No offline plugin package at ${PLUGIN_GLOB}. Install 'OpenAI-API-compatible'"
  warn "from the Marketplace (or upload a repackaged .difypkg) after admin setup."
fi

# ---- 5. BEST-EFFORT: register the avots provider via the console API ----------
# UNCERTAIN / BEST-EFFORT. There is NO clean env/file pre-seed for model
# credentials: Dify stores them ENCRYPTED in Postgres keyed by SECRET_KEY, only
# via the authenticated console. The endpoint below is internal/undocumented and
# requires (a) a created admin account and (b) a logged-in bearer token. We
# attempt it only if DIFY_ADMIN_EMAIL/DIFY_ADMIN_PASSWORD are provided; otherwise
# we print manual instructions.
api="http://127.0.0.1:${EXPOSE_NGINX_PORT}/console/api"
print_manual_wiring() {
  cat <<EOF

  ===================================================================
  MANUAL avots WIRING (do this once in the Dify console at ${BASE})
  ===================================================================
  1. Open ${BASE}/install and create the admin account (first run only).
  2. Plugins → Install plugin → "Install from Local Package File" and upload
     the OpenAI-API-compatible package (${PLUGIN_GLOB}), OR install
     "OpenAI-API-compatible" from the Marketplace if this VM has internet.
  3. Settings → Model Provider → OpenAI-API-Compatible → "Add Model":
        Model type ........... LLM
        Model Name ........... ${AVOTS_MODEL}
        API Key .............. ${AVOTS_API_KEY:-<this client's av_mcp_ key>}
        API endpoint URL ..... ${AVOTS_BASE_URL}
        Model context size ... ${AVOTS_MODEL_CONTEXT}
        Function calling ..... Tool Call        <-- REQUIRED, or agents/workflows
                                                     never send tools to avots
        Stream function call . Support
     Save. Dify validates the key against ${AVOTS_BASE_URL}/models on save.
  4. (RAG only) Add a SEPARATE embedding model. avots may not expose one;
     verify ${AVOTS_BASE_URL}/models for an embedding id. If none, point the
     Knowledge "embedding model" at another OpenAI-compatible embedding
     endpoint, or RAG indexing will fail.
  ===================================================================
EOF
}

if [ -n "${AVOTS_API_KEY}" ] && [ "${AVOTS_API_KEY}" != "av_mcp_REPLACE_ME" ] \
   && [ -n "${DIFY_ADMIN_EMAIL:-}" ] && [ -n "${DIFY_ADMIN_PASSWORD:-}" ]; then
  log "Attempting best-effort provider registration via console API (uncertain) ..."
  token="$(curl -fsS -X POST "${api}/login" \
      -H 'Content-Type: application/json' \
      -d "{\"email\":\"${DIFY_ADMIN_EMAIL}\",\"password\":\"${DIFY_ADMIN_PASSWORD}\"}" \
      2>/dev/null | python3 -c 'import sys,json;
try: print(json.load(sys.stdin).get("data",{}).get("access_token",""))
except Exception: print("")' 2>/dev/null || true)"

  if [ -z "${token}" ]; then
    warn "Could not obtain a console access token (no admin yet, or API shape changed)."
    print_manual_wiring
  else
    # NOTE: provider/model path + JSON body are version-specific and undocumented.
    # Pattern seen in the codebase:
    #   POST /console/api/workspaces/current/model-providers/\
    #        langgenius/openai_api_compatible/openai_api_compatible/models/credentials
    prov="langgenius/openai_api_compatible/openai_api_compatible"
    body="$(python3 - "$AVOTS_MODEL" "$AVOTS_API_KEY" "$AVOTS_BASE_URL" "$AVOTS_MODEL_CONTEXT" <<'PY'
import json,sys
name,key,url,ctx=sys.argv[1:5]
print(json.dumps({
  "model": name, "model_type": "llm",
  "credentials": {
    "api_key": key,
    "endpoint_url": url,
    "mode": "chat",
    "context_size": ctx,
    "function_calling_type": "tool_call",   # REQUIRED for agents/tools
    "stream_function_calling": "supported",
    "vision_support": "no_support",
  },
}))
PY
)"
    code="$(curl -s -o /tmp/dify_prov.json -w '%{http_code}' \
        -X POST "${api}/workspaces/current/model-providers/${prov}/models/credentials" \
        -H "Authorization: Bearer ${token}" \
        -H 'Content-Type: application/json' \
        -d "${body}" 2>/dev/null || echo 000)"
    if [ "${code}" = "200" ] || [ "${code}" = "201" ]; then
      log "avots provider registered via API (HTTP ${code}). Verify in the console."
    else
      warn "API provider registration returned HTTP ${code} (expected if the plugin"
      warn "isn't installed yet or the endpoint shape differs). Falling back to manual."
      [ -s /tmp/dify_prov.json ] && head -c 400 /tmp/dify_prov.json >&2 && echo >&2
      print_manual_wiring
    fi
  fi
else
  print_manual_wiring
fi

log "Done. Console: ${BASE}  (Caddy fronts Dify nginx on 127.0.0.1:${EXPOSE_NGINX_PORT})"
log "If first boot: visit ${BASE}/install to create the admin account."
