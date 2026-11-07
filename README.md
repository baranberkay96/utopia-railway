# Deploy and Host Utopia with Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/utopia-v01-rc9-enterprise-world-model?referralCode=20H68q)

Utopia is DeepLethe's open-source (Apache-2.0) "enterprise world model": it reads your documents into a bitemporal knowledge graph that records what was true when, and when the system learned it. This community template runs **v0.1.0-rc9, a release candidate**, with Postgres 18 + pgvector, a pre-created administrator account and sign-up closed.

## About Hosting Utopia

Utopia is one Rust binary and one Postgres: full-text search (Tantivy) is embedded, vectors live in pgvector and the job queue is a table. Hosting it well still takes care: a pgvector database, a volume for uploaded originals and the search index, a key that seals stored API keys, and a safe first start, because upstream makes the first account that registers the system administrator. This template creates that account from generated variables on a loopback-only first boot, before the public port opens, closes self-registration, runs the app as a least-privilege database role and stores your model key once, encrypted.

## Common Use Cases

- Contract chains: ask which payment terms applied on a given date, and see the amendment and sentence they came from
- Records that change (HR, finance, research): who held a role in a period, and what the base believed at the time, with corrections kept as history
- Give Claude Desktop, Cursor or your own agents typed, dated reads of a knowledge base over MCP with scoped personal tokens
- Search and chat across documents and a mounted database (Postgres, MySQL, ClickHouse, Trino, Databricks, Snowflake), with answers citing their passages
- An append-only decision ledger for audits: who confirmed, rejected, merged or reverted what, and when

## Dependencies for Utopia Hosting

- Utopia v0.1.0-rc9 (`ghcr.io/deeplethe/utopia`, pinned by digest), started by a small wrapper
- PostgreSQL 18 with pgvector 0.8 (Railway's Postgres image, tuned to the container)
- A Railway volume for originals and the full-text index
- An OpenAI-compatible model provider for chat and embeddings (OpenAI by default; DeepSeek, Qwen, Ollama, vLLM and others work). Optional at deploy time

### Deployment Dependencies

- Source and release notes: https://github.com/deeplethe/utopia/releases/tag/v0.1.0-rc9
- Project site and philosophy: https://utopia.bi
- Security notes from upstream: https://github.com/deeplethe/utopia/blob/v0.1.0-rc9/SECURITY.md
- MCP guide: https://github.com/deeplethe/utopia/blob/v0.1.0-rc9/web/src/docs/mcp.md
- Ingest interfaces (sources, push API): https://github.com/deeplethe/utopia/blob/v0.1.0-rc9/web/src/docs/ingest.md
- pgvector: https://github.com/pgvector/pgvector

### Implementation Details

| Service | Role | Public | Volume |
|---|---|---|---|
| Utopia | Web UI, API, MCP endpoints and the background job worker in one process; migrations run at startup | yes (port 1516) | `/app/data` |
| Postgres | PostgreSQL 18 + pgvector: graph, ontology, ledger, embeddings, job queue | no | `/var/lib/postgresql/data` |

**First login**

1. Optionally paste an OpenAI-compatible API key into `MODEL_API_KEY` when deploying, and change `ADMIN_EMAIL` to your address. Utopia boots without a key.
2. Wait until both services are healthy. The first boot applies about 100 migrations and creates the administrator before the public port opens.
3. Open the Utopia URL and sign in with `ADMIN_EMAIL` (default `admin@example.com`, typed exactly) and `ADMIN_PASSWORD` (generated; Utopia → Variables). Change the password in your account settings: the variable is used on the first boot only.
4. In Administration → Models, check or set the chat and embedding models and press Test. The deploy log also shows the result of that test when a key was given.

**First run**

1. Upload a few PDF, DOCX, XLSX, Markdown or HTML files to the General knowledge base, or create a new base and pick ontology packs (schema.org, W3C Org, PROV-O, FOAF, IOF Core).
2. A document becomes searchable once embedded; extraction then builds entities and dated facts in the background, one model call per chunk.
3. Ask in Chat, for example "Which payment terms applied on 15 March 2024?". Answers cite the passages they used.
4. Open Review for low-confidence extractions, suspected duplicates and conflicts, and the graph to see when each fact held.
5. For agents, create a token in Account → Agents & tokens and point an MCP client at `https://{your-domain}/api/v1/kbs/{kb-id}/mcp` with `Authorization: Bearer {token}`.

**Security defaults**

- Self-registration is closed (`OPEN_REGISTRATION=false`); add people in Administration → Users, or turn sign-up on in Administration → Deployment.
- The app connects as `utopia_app`, which can read and write business tables but only append to the audit ledger; migrations run as the Postgres owner. This is upstream's recommended hardening.
- Model keys, connection strings and source tokens are encrypted with `UTOPIA_SECRET_KEY` (generated). Keep that variable: without it the stored keys cannot be read.
- Postgres has no public endpoint. Session cookies are marked Secure.
- There is no login rate limiting upstream; keep the generated password or an equally strong one.

**Models**

The key, endpoint and model variables are applied once, on the first boot, to the default workspace; after that, manage models in Administration → Models. Defaults follow upstream's OpenAI preset: `gpt-4o-mini` for chat and `text-embedding-3-small` for embeddings. For DeepSeek, set `MODEL_BASE_URL=https://api.deepseek.com/v1` and `CHAT_MODEL=deepseek-chat`, plus `EMBEDDING_BASE_URL` and `EMBEDDING_API_KEY` for another provider, since DeepSeek has no embedding model. Keep the embedding model fixed once documents are in. Scans and images need a MinerU service or a Volcengine Ark vision model, and recordings a transcription model; both are configured in Administration → Models.

**Scaling**

Run one Utopia replica: the job worker lives in the app process and requeues unfinished jobs when it starts, and the volume belongs to one service. Scale vertically. Background workers and per-model concurrency are in Administration → Deployment: lower them on small plans or when your provider rate-limits, raise them for large imports.

**Versions and upgrades**

Utopia is at v0.1 and this is a release candidate: the schema changes between versions and migrations only roll forward. The image is pinned by tag and digest in `UTOPIA_IMAGE`. To upgrade, read the release notes, back up both volumes, then set the new tag and digest there and redeploy. A rollback needs the backup.

**Backups**

A complete backup is the Postgres volume plus the Utopia volume (originals and search index). Use Railway volume backups for both. If the index is lost, Utopia rebuilds it from the database at startup.

**Costs and plans**

Estimated at Railway usage prices: about $4/month idle and $15–20/month while importing and chatting with a small team. Trial can run it for evaluation; Hobby is recommended. Model calls are billed by your model provider, not by Railway.

### Why Deploy Utopia on Railway?

Railway runs Utopia and its pgvector database in one project on a private network, with HTTPS, volumes and logs handled for you, so you can go from deploy to a governed, time-aware knowledge base in minutes and connect your agents. This is a community template. It is not affiliated with or endorsed by DeepLethe; Utopia is DeepLethe's open-source project under the Apache-2.0 licence.
