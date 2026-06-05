# dify/ — single-tenant Dify VM, backed by avots.ai

The client gets a turnkey **Dify** install: a self-hosted LLM app platform for
building chatbots, RAG ("Knowledge") apps, and agent/workflow automations,
behind their own domain with TLS. The LLM backend is **avots.ai** (OpenAI-API
compatible), and the client uses **their own avots key**. One VM = one client.

This directory is a **provisioning script + overlay**, not a vendored compose.
Dify's supported deployment is its own `docker/docker-compose.yaml`; we clone it
at a pinned tag and layer per-VM values on top. We deliberately do NOT hand-copy
Dify's ~11-container compose.

## What ships here

| File | Purpose |
|---|---|
| `provision.sh` | First-boot, idempotent: clone Dify at the pinned tag, build `docker/.env` from upstream `.env.example` + our overlay, `docker compose up -d`, stage the offline plugin, best-effort register the avots provider (or print manual steps). |
| `Caddyfile` | TLS front for `{domain}` → `reverse_proxy` to Dify's internal nginx on `127.0.0.1:8080`. Automatic Let's Encrypt. |
| `.env.overlay.example` | Committed template of the per-VM values we set on top of Dify's `.env`. Real `.env.overlay` is gitignored + injected per client. |
| `autoinstall-snippet.yaml` | cloud-init `write_files` (overlay + Caddy unit) + `runcmd` (run `provision.sh`, start Caddy). `{placeholder}` tokens substituted per client. |

`dify-upstream/` (the cloned Dify repo) and any `.env.overlay` are gitignored.

## The stack (Dify's official compose)

~11 containers from `docker/docker-compose.yaml`:

- **app:** `api`, `worker`, `worker_beat`, `web`, `plugin_daemon`
- **infra:** `db` (PostgreSQL), `redis`, `weaviate` (default vector DB),
  `sandbox` (isolated code execution), `ssrf_proxy`, `nginx`

**Footprint:** Dify's documented minimum is **2 CPU cores / 4 GiB RAM**; 8 GB is
comfortable once you add datasets/plugins. Disk grows with Postgres + Weaviate +
uploaded files; start at 40+ GB.

## Version pin

Pinned to **Dify 1.14.2** (latest 1.14.x as of 2026-06-05, released 2026-05-19).

- Do **NOT** use **2.0.0** for a baked image yet — unproven for this flow.
- 1.14.x is also a hard floor for a security reason: versions **before 1.11.0**
  leaked configured **model-provider API keys in plaintext to the frontend**
  (CVE-2025-67732 / advisory GHSA-phpv-94hg-fv9g). That is exactly the avots key
  we store, so an old build would expose it. Re-verify the latest 1.14.x and its
  advisories before each re-bake; `DIFY_TAG` in `provision.sh` is the single
  knob.

## avots wiring (exact)

Dify has **no clean env/file pre-seed** for model credentials. It stores them
**encrypted in Postgres, keyed by `SECRET_KEY`**, and only through the
authenticated console. So wiring avots is a two-part job:

### 1. Install the "OpenAI-API-compatible" model-provider plugin

avots is reached through Dify's **OpenAI-API-compatible** provider plugin
(`langgenius/openai_api_compatible`), not a built-in provider.

For a baked / offline image, bundle the plugin as a local `.difypkg` and install
it from a local file rather than the Marketplace:

1. On an online machine, repackage the plugin with deps bundled using
   `dify-plugin-repackaging`:
   `./plugin_repackaging.sh market langgenius openai_api_compatible <version>`
   → produces an `*-offline.difypkg`.
2. Bake it into the image at `dify/plugins/openai_api_compatible-*.difypkg`.
3. Set **`FORCE_VERIFYING_SIGNATURE=false`** (unsigned local install) and raise
   `PLUGIN_MAX_PACKAGE_SIZE` + `NGINX_CLIENT_MAX_BODY_SIZE` (the overlay does
   this). Then in the console: **Plugins → Install from Local Package File**.

If the VM has internet, installing "OpenAI-API-compatible" from the Marketplace
is simpler — the offline package just removes that dependency.

### 2. Add the avots model (console step)

**Settings → Model Provider → OpenAI-API-Compatible → Add Model:**

| Field | Value |
|---|---|
| Model type | `LLM` |
| Model Name | `anthropic/claude-opus-4.8` (any avots `/v1/models` id) |
| API Key | this client's `av_mcp_...` key |
| API endpoint URL | `https://api.avots.ai/openai/v1` |
| Model context size | `200000` (Claude Opus) |
| **Function calling** | **`Tool Call`** |
| Stream function calling | `Support` |

**The `Tool Call` flag is load-bearing.** If it is left at "Not Support", Dify
never sends `tools` to avots and **agents/workflows silently can't call tools** —
even though avots tool-calling works (validated stream + non-stream). The
underlying provider variable is `function_calling_type=tool_call`.

Dify validates the key against `…/v1/models` when you save, so a bad key fails
fast.

### Best-effort automation

`provision.sh` will *attempt* step 2 via the internal console API
(`POST /console/api/workspaces/current/model-providers/.../models/credentials`)
**only if** `DIFY_ADMIN_EMAIL` + `DIFY_ADMIN_PASSWORD` are in the overlay and an
admin account exists. This endpoint is **undocumented and version-specific** — 
treat it as best-effort. On any failure it prints the exact manual steps above.
**Verify the result in the console** even when it reports success.

## RAG needs a SEPARATE embedding model (gotcha)

Dify's Knowledge/RAG indexing requires an **embedding** model, which is a
*different* model from the chat LLM. You must add a second model under the
provider with **Model type = Text Embedding**.

**Uncertain:** whether avots exposes an embedding model. Check
`https://api.avots.ai/openai/v1/models` for an embedding id. If none exists,
either point Dify's embedding model at another OpenAI-compatible embedding
endpoint, or **RAG/dataset indexing will fail** while plain chat/agents still
work. Verify before promising RAG to a client.

## Per-VM `SECRET_KEY`

Generate a **unique** key per VM: `openssl rand -base64 42`.

- All stored credentials (incl. the avots key) are encrypted under this key.
- 1.14.x auto-generates a key into the storage volume if left blank, but we set
  it explicitly so it is captured in the build record and survives a volume
  reset. **Reusing one key across VMs, or rotating it after first boot, breaks
  decryption of every stored credential.**

## Ports / TLS

- **Public:** only **80/443**, owned by **Caddy** (TLS for `{domain}`).
- **Dify's own nginx:** plain HTTP, published on **`127.0.0.1:8080`**
  (`NGINX_HTTPS_ENABLED=false`, `EXPOSE_NGINX_PORT=8080`); 443 is **not**
  published (`EXPOSE_NGINX_SSL_PORT=8443` is parked, unused).
- Caddy `reverse_proxy 127.0.0.1:8080` handles TLS + websockets (Dify's console
  uses Socket.IO).
- Alternative (not chosen here): Dify's built-in nginx TLS via
  `NGINX_HTTPS_ENABLED=true` + mounted certs. We use Caddy for consistency with
  the other avots-vm builds.

## Security checklist

- [ ] **Never publish** Postgres / Redis / Weaviate / sandbox / ssrf_proxy
      ports. Dify's compose keeps them internal-only by default — keep it that
      way (don't add `ports:` to those services).
- [ ] Keep **`sandbox`** and **`ssrf_proxy`** enabled (code-exec isolation +
      egress filtering for model/tool requests).
- [ ] **Unique `SECRET_KEY`** per VM; never the shared default.
- [ ] Pin a recent **1.14.x** (>= 1.11.0); never an image baked before the
      plaintext-key fix; never `:latest`; not 2.0.0 yet.
- [ ] `FORCE_VERIFYING_SIGNATURE=false` is for the **one-time offline plugin
      install** only; it does not weaken runtime auth, but keep the plugin set
      minimal.
- [ ] Set a strong console admin password at first `/install`; the admin account
      is the only thing standing in front of the stored avots key.
- [ ] Treat the VM as fully compromisable by whatever the client builds (Dify
      runs user code in the sandbox) — the **VM is the isolation boundary**.
- [ ] Keep a re-bake pipeline: Dify ships CVEs/releases frequently.

## License — read before shipping

Dify is under the **"Dify Open Source License"** = Apache-2.0 **plus two extra
conditions**:

1. **No multi-tenant SaaS without authorization.** You may not run Dify as a
   multi-tenant managed service. **Our model is fine:** one single-tenant Dify
   per client VM, the client operates their own instance.
2. **You may NOT remove or modify the Dify LOGO / copyright** in the console UI.
   So the console **cannot be white-labeled** — the client sees Dify branding.
   State this to the client up front; it is a hard constraint of the license,
   not a config option.

## First-boot summary

1. cloud-init writes `.env.overlay` (with `{secret_key}`, `{domain}`,
   `{avots_key}`) + the Caddy unit.
2. `provision.sh`: clone/reuse Dify 1.14.2 → build `docker/.env` → `compose up`
   → stage offline plugin → best-effort avots provider (or manual instructions).
3. Caddy starts, gets a cert for `{domain}`.
4. Operator opens `https://{domain}/install`, creates the admin account,
   confirms the avots provider + **Tool Call**, and (if needed) adds an
   embedding model for RAG.

## Uncertainties to verify before baking

- **avots embedding model** — does `…/v1/models` list one? Decides whether RAG
  works out of the box.
- **Console provider API** path/body for 1.14.2 — undocumented; the scripted
  registration is best-effort. Confirm the manual console flow regardless.
- **Exact offline `.difypkg` filename/version** for the OpenAI-API-compatible
  plugin to bake into `plugins/`.
- Re-confirm the **latest 1.14.x** tag and any newer advisory at bake time.
