# Notice

## Upstream software

This repository contains Railway configuration and a small start wrapper only. Utopia is **DeepLethe's open-source project**; its software is pulled from DeepLethe's published container image and is not stored or modified here. This is a community template, not affiliated with or endorsed by DeepLethe.

| Software | License | Used as |
|---|---|---|
| Utopia v0.1.0-rc9 (`utopia-server`, web UI) | Apache License 2.0 — Copyright 2026 DeepLethe Contributors | Image `ghcr.io/deeplethe/utopia:0.1.0-rc9`, pinned by its index digest `sha256:9bba072b…b95755`. The `services/utopia` build adds Debian's `curl`, `jq` and `postgresql-client` and one script on top; no upstream file is changed. License text: https://github.com/deeplethe/utopia/blob/v0.1.0-rc9/LICENSE |
| Third-party components inside that image (Rust crates such as tokio, axum, sqlx, Tantivy, tantivy-jieba; the web front end's npm packages; Debian bookworm with poppler-utils) | Their own licenses | Shipped by DeepLethe in the image; listed in upstream's `Cargo.lock` and `web/pnpm-lock.yaml` |
| curl, jq, postgresql-client 15 (Debian bookworm packages) | curl license (MIT-style), MIT, PostgreSQL License | Installed from Debian's repository at build time |
| PostgreSQL 18, pgvector 0.8 | PostgreSQL License | `ghcr.io/railwayapp-templates/postgres-ssl:18` (Railway; MIT-licensed image repository) |
| Lucide icon `orbit` | ISC | Referenced by URL from `cdn.jsdelivr.net/npm/lucide-static@1.59.0`; not copied |

Apache-2.0 section 4 is met by linking the license above and stating that nothing of Utopia is modified or redistributed from this repository; the image itself is DeepLethe's distribution.

## Model providers (not legal advice)

The template stores, on request, an API key for an OpenAI-compatible provider (OpenAI by default). Documents you upload are sent to that provider for embedding and extraction, under the provider's own terms and data-processing conditions. Choose a provider, region and agreement that fit the data you put into Utopia, or point the model settings at a self-hosted endpoint (Ollama, vLLM) to keep documents on infrastructure you control. Ask your legal or compliance team before loading personal or regulated data.

## Verified against

| What | Upstream file | Ref | Checked |
|---|---|---|---|
| Release, pre-release flag, date, migrations added, upgrade notes | GitHub release `v0.1.0-rc9` | tag commit `888761cae3d7c9432b75164ccd715731ccf2999d` | 2026-11-07 |
| Image digest, platforms, config (CMD, user, env, revision label) | GHCR registry API: index `ghcr.io/deeplethe/utopia:0.1.0-rc9`, amd64 manifest and config | 0.1.0-rc9 | 2026-11-07 |
| Services, Postgres requirement ("any PG16+ image with pgvector"), volumes, variables, restricted role | `docker-compose.yml`, `.env.example`, `docker/Dockerfile`, `docker/init-app-role.sh`, `.github/workflows/release.yml` | `888761c` (local copy: compose, Dockerfile, .env.example, config.rs, main.rs hash-checked against the tag; migration list identical) | 2026-11-07 |
| Configuration keys and blank handling, bind address, migrations at startup, secret key, JWT secret, IPv6 loopback listener | `crates/utopia-core/src/config.rs`, `crates/utopia-core/src/secrets.rs`, `crates/utopia-server/src/main.rs` | `888761c` | 2026-11-07 |
| First user becomes administrator, registration switch (database value wins over the environment), admin user creation | `crates/utopia-server/src/api/auth_routes.rs`, `admin_routes.rs`, `crates/utopia-store/src/accounts.rs`, `access.rs`, `migrations/0001_core.sql` | `888761c` | 2026-11-07 |
| Health route, routes, upload limit, Bearer auth | `crates/utopia-server/src/api/mod.rs`, `crates/utopia-server/src/auth.rs` | `888761c` | 2026-11-07 |
| Model settings per workspace, sealing, connectivity test, presets | `crates/utopia-server/src/api/settings_routes.rs`, `crates/utopia-store/src/settings.rs`, `web/src/pages/Settings.tsx` | `888761c` | 2026-11-07 |
| Least-privilege grants, vector indexes built as owner, runtime DDL | `migrations/0010_least_privilege_role.sql`, `crates/utopia-store/src/vector_index.rs` | `888761c` | 2026-11-07 |
| Postgres features used (NULLS NOT DISTINCT, halfvec, HNSW, gen_random_uuid) | `migrations/*.sql` | `888761c` | 2026-11-07 |
| Job queue orphan requeue (single process), Tantivy writer heap | `crates/utopia-store/src/jobs.rs`, `crates/utopia-search/src/lib.rs` | `888761c` | 2026-11-07 |
| OIDC configuration (read per request) | `crates/utopia-server/src/api/oidc_routes.rs` | `888761c` | 2026-11-07 |
| UI labels quoted in the README | `web/src/i18n/en.ts`, `web/src/docs/mcp.md` | `888761c` | 2026-11-07 |
| Postgres base and init hooks | `ghcr.io/railwayapp-templates/postgres-ssl:18` config (PostgreSQL 18.6, pgvector 0.8.*), our `56-pgvector` template | index `sha256:4fc833b4…7c863` | 2026-11-07 |

## Our files

| File | Origin |
|---|---|
| `services/postgres/pgvector-tune.sh`, `services/postgres/to-start-command.py` | Our own `56-pgvector` template (baranberkay96/pgvector-railway), unchanged apart from a header comment |
| `services/utopia/Dockerfile`, `services/utopia/railway-start.sh`, `template.json`, `TEMPLATE.md`, `README.md` | Written for this template. The wrapper calls Utopia's public HTTP API (register, workspace settings, settings test) and reads two of its tables; it contains no upstream code. |

## Reference only (not copied)

- Two small Railway templates named "Utopia" exist (0 projects each, per the task brief); their configuration was not available here and nothing was taken from them.
- Upstream's README, SECURITY.md and docs were read for behaviour; no prose was copied.

## Trademarks

"Utopia" and "DeepLethe" are used only to say what this template deploys. The template uses a neutral icon, not DeepLethe's logo or banner. "Railway", "PostgreSQL", "OpenAI", "DeepSeek", "Claude" and "Cursor" belong to their respective owners. This is a community template and is not affiliated with or endorsed by DeepLethe or Railway.
