# Utopia v0.1 RC9 Enterprise World Model — Railway template spec

## Listing

| Field | Value |
|---|---|
| Name | **Utopia v0.1 RC9 Enterprise World Model** (38 chars; `v0.1 RC9` = the pinned pre-release `v0.1.0-rc9`; "enterprise world model" is upstream's own description) |
| Description | Bitemporal knowledge graph from your documents: search, chat, review, MCP (73 chars) |
| Category | AI/ML |
| Tags | utopia, knowledge-graph, bitemporal, ontology, rag, mcp, pgvector, rust |
| Icon | `https://cdn.jsdelivr.net/npm/lucide-static@1.59.0/icons/orbit.svg` (neutral Lucide icon, ISC; nods to upstream's Copernicus framing; no DeepLethe logo) |
| Repo | `baranberkay96/utopia-railway`, services in `/services/<svc>` |
| User input at deploy | **None required.** Recommended: `ADMIN_EMAIL` (default `admin@example.com`) and `MODEL_API_KEY` (optional; Utopia boots without it). |

Wording: README and listing describe Utopia in its own terms (bitemporal knowledge graph, ontology, governance). Upstream asks not to be framed as an open-source take on Palantir; the package never makes that comparison. README says in its first paragraph that rc9 is a release candidate.

## Base market templates

No `_market/*.json` files were supplied for this app. Per the task brief, two small Railway templates named "Utopia" exist with 0 projects; their configuration was not available and nothing was taken from them. The package is built from upstream's `docker-compose.yml`, `.env.example`, `docker/`, the rc9 release notes, the rc9 source and the published image.

## Pinned versions

| Service | Source | Version | Built / released | Checked |
|---|---|---|---|---|
| Utopia | repo `/services/utopia`: `FROM ghcr.io/deeplethe/utopia:0.1.0-rc9@sha256:9bba072bf510519425c141e71642cdfaf085c2b8dfde2b9c35bb8c6a31b95755` (index; amd64 `sha256:857f82b5…0c6f34`, arm64 `sha256:a975c5a9…6c8d`) + Debian `curl` 7.88.1, `jq` 1.6, `postgresql-client` 15 | v0.1.0-rc9 (pre-release) | release 2026-10-11, image created 2026-10-11 03:26 UTC | 2026-11-07 |
| Postgres | `ghcr.io/railwayapp-templates/postgres-ssl:18` (Railway base; index `sha256:4fc833b4…7c863`) + 56-pgvector tuning start command | PostgreSQL 18.6, pgvector 0.8.* | image 2026-10-23 | 2026-11-07 |

- The image's amd64 config carries `org.opencontainers.image.revision=888761cae3d7c9432b75164ccd715731ccf2999d` = the `v0.1.0-rc9` tag commit and `version=v0.1.0-rc9`. It is upstream's `docker/Dockerfile` output: Debian bookworm-slim, `poppler-utils`, `utopia-server` in `/usr/local/bin`, web build in `/app/web-dist`, `CMD ["utopia-server"]`, no ENTRYPOINT, runs as root. Pulls anonymously from GHCR.
- Upstream compose still defaults to `0.1.0-rc8`; rc9 is the newest release (rc9 adds migrations 0109/0110 and fixes vector indexes under the restricted role, #1124). `main` moves daily; this template follows the release, not `main`.
- **Postgres image pinned by tag, not digest**, like every other package (Railway base standard): the tag fixes the major version the data directory depends on, and Railway ships security rebuilds under it. The digest checked is recorded above. The Utopia image, the part that changes behaviour, is pinned by tag + digest.

## Architecture

```
Internet ─HTTPS─▶ Utopia (utopia-server: web UI, /api/v1, per-base MCP, job worker)   public :1516, [::]
                    ├─ runtime pool as utopia_app ─┐
                    ├─ migrations / vector index builds as owner ─┤─▶ Postgres 18 + pgvector (private)
                    │                                              ┘
                    ├─ /app/data (volume): files/ originals, index/ Tantivy full-text index
                    └─ HTTPS ─▶ OpenAI-compatible model endpoint(s) (chat, embeddings; optional OCR/transcription)
```

## Design decisions (verified in the v0.1.0-rc9 sources and image)

### One prebuilt image, a thin build for the wrapper

- `services/utopia/Dockerfile`: `ARG UTOPIA_IMAGE=<tag@digest>` + `FROM`, installs `curl`, `jq`, `postgresql-client` from Debian (no vendor repo, no pins that could disappear, Rule 8.27; apt retries), copies `railway-start.sh`, asserts the tools, `utopia-server` and `/app/web-dist/index.html` at build time. `UTOPIA_IMAGE` is a service variable, so an upgrade is one variable change.
- Utopia is "one Rust binary and one Postgres" upstream (full-text search embedded, job queue in a table): two services is the full upstream stack, nothing stripped.

### Postgres: PG16 is a minimum, not a pin

- Compose comment: "any PG16+ image with pgvector". The migrations use `NULLS NOT DISTINCT` (PG15+), `halfvec` (pgvector 0.7+), HNSW and `gen_random_uuid`; nothing PG16-only or removed in 18. So Railway's PG 18.6 + pgvector 0.8 image is used with the deploy-tested 56-pgvector container-aware tuning and 1 GiB `/dev/shm` (HNSW builds). `CREATE EXTENSION vector` happens at initdb (tuning hook) and again in migration 0001 as the owner.
- No TCP proxy, no PgBouncer (pool of 32 is small; vector index builds use `CREATE INDEX CONCURRENTLY` on a direct owner connection).

### Migrations at startup, not pre-deploy

- `utopia-server` has no migrate-only mode: `main.rs` runs `sqlx` migrations on its own owner pool at every start (forward-only, idempotent when current). A pre-deploy command would have to start the whole server, job worker included, in a throwaway container without the volume. Instead the wrapper waits for Postgres (`SELECT 1`, up to `DB_WAIT_SECONDS`=600) before the server starts (Rule 8.5/8.6 intent), restart policy `ALWAYS`, healthcheck window 1200 s.

### First boot: the administrator exists before the port opens

- Upstream: the first account registered becomes system administrator and owner of the Default Workspace (`accounts.rs`); later sign-ups join as viewers while `deployment_settings.open_registration` is true (default true). `UTOPIA_OPEN_REGISTRATION` is effectively ignored: the database value wins and only falls back to the env on a read error (`auth_routes.rs`).
- The wrapper counts `organizations` (owner connection; table missing = fresh). If zero: starts `utopia-server` on `127.0.0.1:15161` (15162 if PORT collides; its extra IPv6 listener is `[::1]` only), waits for `/api/v1/health` (migrations done), writes `open_registration` from `OPEN_REGISTRATION` (default **false**) via SQL **before** registering, `POST /api/v1/auth/register` with `ADMIN_EMAIL`/`ADMIN_PASSWORD`/`ADMIN_NAME`, checks `user.is_admin`, stores models, then stops that process. Only then is `[::]:$PORT` opened. Closing registration first means a crash between steps never leaves sign-up open; a failed close with `OPEN_REGISTRATION=false` refuses to start (fail closed).
- `ADMIN_PASSWORD` = `secret(24)`, unambiguous alphabet. Under 8 characters (upstream minimum) → exit 1: an unclaimed instance would make the first visitor admin (Rule 8.29 allows failing closed there). Invalid email / name → defaults with a warning. These variables, `OPEN_REGISTRATION` and the model variables apply **on the first boot only**; afterwards the app is the source of truth (password change in the account page, users and sign-up in Administration). The log says so on every later boot.
- Secrets reach jq through its environment and curl through stdin and a header file in a 0700 temp dir; `ADMIN_PASSWORD`, `MODEL_API_KEY`, `EMBEDDING_API_KEY`, `UTOPIA_APP_DB_PASSWORD` are removed from the environment before either server process starts.

### Least-privilege runtime role (upstream's recommended hardening)

- Upstream: with `UTOPIA_APP_DB_PASSWORD` + `UTOPIA_MIGRATION_URL`, the app connects as `utopia_app` (business tables read/write, `audit_events` without UPDATE/DELETE/TRUNCATE) and migrations run as the owner; migration 0010 grants the role its rights only if it exists when 0010 runs. rc9 fixed vector index builds in this mode (they use the owner URL at runtime).
- The wrapper creates the role if missing and re-applies its password every start (`format(... %L)` + `\gexec`, so the variable can be rotated), grants CONNECT, then exports `UTOPIA_DATABASE_URL` (utopia_app) and `UTOPIA_MIGRATION_URL` (owner). If the schema exists but the role has no SELECT on `organizations` (database first started as owner), if role creation fails, or if the password is not 16–128 alphanumerics, it falls back to owner mode with a warning instead of failing. `DB_LEAST_PRIVILEGE=false` = upstream's default owner mode.

### Keys and secrets

- `UTOPIA_SECRET_KEY` = `secret(64, hex)`: the AES-256-GCM key that seals model keys, connection strings and source tokens. Kept in Railway variables instead of `secret.key` on the volume, so it survives a volume loss and is identical for every process. Invalid values are dropped with a warning (upstream would exit), falling back to the key file.
- JWT signing key: left to upstream (generated on first start, stored in `deployment_settings`).
- `UTOPIA_COOKIE_SECURE=true` (Railway serves HTTPS; upstream would otherwise infer it from `X-Forwarded-Proto`).

### Models

- Upstream configures models per workspace in the UI only (`llm_settings`, sealed). The wrapper's first boot calls `PUT /api/v1/workspaces/{id}/settings` with the session token from registration when `MODEL_API_KEY` (or `EMBEDDING_API_KEY`) is set or `MODEL_BASE_URL` is not the OpenAI default (keyless endpoints such as Ollama on the private network), then `POST .../settings/test` and logs "chat ok; embeddings ok (dimension 1536)" or the provider's error. Never fatal.
- Defaults = upstream's OpenAI preset in `Settings.tsx`: `https://api.openai.com/v1`, `gpt-4o-mini`, `text-embedding-3-small` (both listed as current, non-deprecated, on models.dev on 2026-11-07). `EMBEDDING_BASE_URL`/`EMBEDDING_API_KEY` cover chat providers without embeddings (DeepSeek). `embed_dim` is informational upstream (vectors are dimension-agnostic; HNSW indexes are built per dimension) and left unset.

### Listening, threads, health

- `UTOPIA_BIND_ADDR=[::]:$PORT` (tokio on `::` is dual stack, Rule 8.2/8.14); `PORT=1516` = `targetPort`; healthcheck `/api/v1/health` (static JSON, answers once migrations and startup are done).
- `TOKIO_WORKER_THREADS` from the cgroup CPU quota, 2–8 (`RUNTIME_THREADS=auto` or a number; tokio 1.53 reads it), Rule 8.15. Tantivy's writer heap is 64 MB, which caps its threads at 4.
- The start log prints the container memory limit and a hint under 1 GB.

### Things deliberately left out

- **MinerU OCR / transcription services:** optional upstream, heavy (model downloads, GPU-oriented); configurable in Administration → Models against any endpoint.
- **Backup cron:** a full backup needs the app volume (originals) and the database; a separate service cannot read the app volume, and upstream's `utopia backup` CLI is not in the image. README points to Railway volume backups for both.
- **Sample data:** upstream has no sample loader, and the README's `docs/walkthrough.md` link does not exist at rc9 or on `main`. README carries a first-run walkthrough instead; auto-loading demo documents into an enterprise knowledge base would also cost model calls the user did not ask for.
- **OIDC SSO:** variables provided (empty, redirect URI prefilled); read per request upstream, so wrong values never stop the server.

## Services

### Utopia

- **Source:** repo `baranberkay96/utopia-railway`, root `/services/utopia` (Dockerfile above)
- **Start command:** image CMD `/usr/local/bin/railway-start` → `exec utopia-server`
- **Healthcheck:** `/api/v1/health` (timeout 1200 s) · **Public domain:** yes, target port `1516` · **Restart:** ALWAYS · **Replicas:** 1 (the job worker requeues every `running` job at start, so two processes would fight; the volume is single-service) · **Volume:** `/app/data`

| Variable | Value | Description |
|---|---|---|
| `ADMIN_EMAIL` | `admin@example.com` | Administrator login created on the first boot; sign in with exactly this value. |
| `ADMIN_PASSWORD` | `${{secret(24, "<unambiguous alphanumerics>")}}` | Generated; first boot only; min. 8 characters. |
| `MODEL_API_KEY` | *(empty)* | Optional OpenAI-compatible key, stored encrypted as the default workspace's chat + embedding key on the first boot. |
| `MODEL_BASE_URL` | `https://api.openai.com/v1` | Chat (and embedding) endpoint. First boot only. |
| `CHAT_MODEL` | `gpt-4o-mini` | Chat model (upstream OpenAI preset). |
| `EMBEDDING_MODEL` | `text-embedding-3-small` | Embedding model (upstream OpenAI preset); empty = none. |
| `EMBEDDING_BASE_URL` | *(empty)* | Separate embedding endpoint, if any. |
| `EMBEDDING_API_KEY` | *(empty)* | Key for it; empty = `MODEL_API_KEY`. |
| `ADMIN_NAME` | `Administrator` | Display name (1–64 chars). |
| `OPEN_REGISTRATION` | `false` | First boot: closed sign-up (admins add users) or open (viewers). |
| `PORT` | `1516` | Listen port, public target, healthcheck. |
| `UTOPIA_IMAGE` | `ghcr.io/deeplethe/utopia:0.1.0-rc9@sha256:9bba072b…b95755` | Build argument: upstream image. |
| `UTOPIA_MIGRATION_URL` | `${{Postgres.DATABASE_URL}}` | Owner connection: migrations, vector index builds, role management. |
| `UTOPIA_APP_DB_PASSWORD` | `${{secret(32, alphanumerics)}}` | Password of `utopia_app`, re-applied each start. |
| `UTOPIA_DATABASE_URL` | `postgresql://utopia_app:${{UTOPIA_APP_DB_PASSWORD}}@${{Postgres.PGHOST}}:${{Postgres.PGPORT}}/${{Postgres.PGDATABASE}}` | Runtime connection as `utopia_app`. |
| `DB_LEAST_PRIVILEGE` | `true` | Restricted role on/off. |
| `UTOPIA_SECRET_KEY` | `${{secret(64, "0123456789abcdef")}}` | Sealing key for stored credentials. |
| `UTOPIA_DATA_DIR` | `/app/data` | Originals and full-text index (volume). |
| `UTOPIA_DB_MAX_CONNECTIONS` | `32` | Pool size (upstream default). |
| `UTOPIA_COOKIE_SECURE` | `true` | Secure session cookies. |
| `RUNTIME_THREADS` | `auto` | tokio worker threads (2–8 from the CPU quota) or a number. |
| `RUST_LOG` | `info` | Log filter. |
| `UTOPIA_OIDC_ISSUER`, `UTOPIA_OIDC_CLIENT_ID`, `UTOPIA_OIDC_CLIENT_SECRET` | *(empty)* | Optional SSO. |
| `UTOPIA_OIDC_REDIRECT_URI` | `https://${{RAILWAY_PUBLIC_DOMAIN}}/api/v1/auth/oidc/callback` | SSO callback to register at the IdP. |

Not in the form but honoured by the wrapper: `DB_WAIT_SECONDS` (600, 30–3600), `BOOT_WAIT_SECONDS` (600, 60–3600).

### Postgres

- **Source:** `ghcr.io/railwayapp-templates/postgres-ssl:18` · **Start command:** the 56-pgvector tuning command (2,604 chars; source `services/postgres/pgvector-tune.sh`, `python3 services/postgres/to-start-command.py --check` → OK; byte-identical to 56-pgvector's)
- **Volume:** `/var/lib/postgresql/data` · **Healthcheck:** none · **Public domain / TCP proxy:** none · **Restart:** ON_FAILURE (10)
- Variables: the Railway base set (`PGDATA`, `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `POSTGRES_USER=postgres`, `POSTGRES_PASSWORD=secret(32, letters)`, `POSTGRES_DB=railway`, `DATABASE_URL`, `SSL_CERT_DAYS`, `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=60`) plus `RAILWAY_SHM_SIZE_BYTES=1073741824`, `PGVECTOR_TUNING=auto`, `PG_MEMORY_LIMIT_MB=auto`, `PG_CPU_LIMIT=auto` (see template.json for descriptions).

## Improvements over market templates and plain upstream compose

No market template to start from. Compared with upstream's compose run as-is:

- No race for the administrator: the account exists before the public port opens; self-registration closed by default (upstream: open, first visitor becomes admin).
- Least-privilege runtime role on by default (upstream: optional, off), with automatic fallback instead of a broken boot.
- No default database password (compose defaults to `utopia`/`utopia`); Postgres private only.
- Sealing key in Railway variables instead of only on the volume.
- Model key entered once at deploy, stored encrypted, connectivity tested and logged.
- Image pinned by digest at the newest release (compose's default still points at rc8).
- pgvector Postgres 18 with container-aware tuning instead of a bare `pgvector/pgvector:pg16`; dual-stack bind; thread pool sized to the CPU quota.

## Scaling

- **Utopia:** 1 replica, scale vertically. Background workers (default 64, 1–256) and per-model concurrency (default 10) are in Administration → Deployment; lower them on Trial/Free or on provider 429s.
- **Postgres:** vertical; tuning follows the container limit (`PG_MEMORY_LIMIT_MB`/`PG_CPU_LIMIT` to override).

## Resource estimate

Prices: RAM $10/GB-month, vCPU $20/vCPU-month, volume $0.15/GB-month. **Not measured** (no container run this round); derived from the processes involved (one Rust process with the jieba tokenizer dictionary, an in-memory docs index and a 64 MB Tantivy writer; poppler subprocesses for PDFs).

| Service | Idle RAM / vCPU | Typical RAM / vCPU | Notes |
|---|---|---|---|
| Utopia | 0.20 GB / 0.01 | 0.60 GB / 0.20 (bursts with many large parallel parses) | volume ~0.1 GB + originals + index |
| Postgres | 0.15 GB / 0.01 | 0.50 GB / 0.10 | volume ~0.3 GB idle; 1536-dim float vectors ≈ 6 KB per chunk + HNSW |

- **Idle ≈ $4/month** (0.35 GB × $10 + 0.02 vCPU × $20 + 0.5 GB × $0.15).
- **Typical ≈ $15–20/month** (1.1 GB × $10 + 0.3 vCPU × $20 + ~5 GB × $0.15) while importing and chatting with a small team.
- Model calls are billed by the provider: extraction is one call per ~1,200-character chunk plus batched adjudication; rough order with `gpt-4o-mini`: a few dollars per thousand pages (estimate, depends on ontology size in the prompt).
- **Minimum plan:** Trial for evaluation (both services are expected to stay under 1 GB at light load; unmeasured, Rule 8.31); **Hobby recommended**. Free (0.5 GB) is untested; the start log warns below 1 GB.

## Verification checklist

1. **Build** (Utopia): `psql (PostgreSQL) 15.x`, `curl 7.88.1`, `jq-1.6`, `/usr/local/bin/utopia-server`, `bash -n` of the wrapper all pass.
2. **First boot log:** `Postgres is ready` → `database: migrations as the owner, the app as utopia_app` → `first boot: starting utopia-server on 127.0.0.1:15161` → upstream's migration line `数据库迁移完成（迁移身份与运行身份分离）` → `administrator account created: admin@example.com` → `self-registration: closed` → `models: …` (with a key: `connectivity test: chat ok; embeddings ok (dimension 1536)`) → `starting utopia-server on [::]:1516` → `Utopia 服务启动于 http://[::]:1516`.
3. **Health:** `https://{domain}/api/v1/health` → `{"status":"ok","name":"utopia","version":"0.1.0"}` (crate version; rc suffix not shown).
4. **Login** with `ADMIN_EMAIL`/`ADMIN_PASSWORD`; Administration visible; Models show the seeded endpoint (key "configured").
5. **Sign-up closed:** `curl -s -X POST https://{domain}/api/v1/auth/register -H 'content-type: application/json' -d '{"email":"x@example.com","password":"Passw0rd!x","display_name":"x"}'` → 400 `registration_closed`.
6. **Role:** in the Postgres Data panel, `SELECT rolname FROM pg_roles WHERE rolname='utopia_app'` → 1 row; `SELECT has_table_privilege('utopia_app','audit_events','UPDATE')` → `f`.
7. **Ingest:** upload a PDF and a DOCX to General → document `ready`, extraction jobs finish, graph shows entities with validity; chat answer with citations.
8. **Vector index:** after embeddings exist, an HNSW index on the embedding expression appears (`\di` in the Data panel), proving the owner-URL path.
9. **MCP:** create a token (Account → Agents & tokens), `POST https://{domain}/api/v1/kbs/{kb}/mcp` `tools/list` with Bearer → tool list.
10. **Redeploy:** log `existing deployment: … not re-applied`; login, documents, search hits (index on the volume) persist; changing `UTOPIA_APP_DB_PASSWORD` + redeploy still connects.
11. **Without a key:** a deploy with `MODEL_API_KEY` empty is healthy and logs `models: MODEL_API_KEY is empty`.
12. **Trial-sized boot:** 1 GB limit (cgroup shows ~953 MiB) and 0.5 GB → healthy, start log shows the under-1-GB hint; record actual RSS of both services.

## Open questions

- **Not deployed; no Docker build or container run** (instruction). Verified: registry index/manifest/config of both images, rc9 sources and release notes via `gh api` and the hash-checked local copy, Debian package versions, `bash -n`, jq programs (local jq 1.7.1; syntax kept 1.6-compatible), template.json checks + `to_serialized.py`, and a stub run of our own wrapper (fake `psql`/`curl`/`utopia-server`; 19 scenarios incl. fresh boot, existing deployment, no-grant fallback, owner mode, short password, bad inputs, registration close failure open/closed, role creation failure, register 400, server crash, keyless/split/invalid model endpoints, DB timeout, SIGTERM during bootstrap, port collision; no secrets in either server environment).
- **Release candidate:** schema changes between rcs, forward-only. Upgrades need a backup of both volumes; re-check the restricted-role path and the register/settings API on each bump.
- **Memory** of Utopia during large parallel ingests (default 64 workers) is unmeasured; Trial/Free fit is an estimate.
- **Login rate limiting** is absent upstream (argon2 hashing slows but does not stop guessing); mitigated by the 24-char generated password.
- **Model defaults:** `gpt-4o-mini` / `text-embedding-3-small` are upstream's preset and current on 2026-11-07; OpenAI could retire them. Extraction quality with other models is upstream's concern.
- **Postgres 18 vs upstream's pg16 default:** compatible by feature analysis; not exercised end to end (watch migration 0001–0110 on the first deploy).
- **Password recovery:** upstream has no reset flow; another administrator can help, but if the only administrator loses the password, recovery means manual database work. README says `ADMIN_PASSWORD` is first-boot only.
