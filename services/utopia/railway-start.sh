#!/bin/bash
# railway-start: start wrapper for Utopia on Railway (community template, not affiliated
# with DeepLethe). DeepLethe's utopia-server runs unmodified; this script prepares its
# environment and, on a fresh database, claims the instance for the administrator before
# the public port opens.
#
#   1. Listen on [::]:$PORT (dual stack), size the async runtime from the CPU quota,
#      check UTOPIA_SECRET_KEY and the data volume.
#   2. Wait for Postgres on the owner connection (UTOPIA_MIGRATION_URL).
#   3. DB_LEAST_PRIVILEGE=true: create or update the login role utopia_app from
#      UTOPIA_APP_DB_PASSWORD and run the app as that role, upstream's optional hardening
#      (business tables read/write, the audit ledger append-only). Migrations and vector
#      index builds keep using the owner connection.
#   4. Fresh database (no organization yet): start utopia-server on loopback only (it runs
#      the migrations), set self-registration from OPEN_REGISTRATION, register ADMIN_EMAIL /
#      ADMIN_PASSWORD (upstream makes the first account the system administrator), store
#      MODEL_* as the default workspace's model settings, then stop it. The sign-up form is
#      never reachable from outside before the administrator exists.
#   5. exec utopia-server on the public port.
#
# Values typed into the deploy form never fail the deploy unless the result would be unsafe
# (an administrator password under 8 characters): other bad values fall back to defaults
# with a warning in the log.

set -u -o pipefail

readonly DEFAULT_PORT=1516
readonly DEFAULT_DATA_DIR=/app/data
readonly DEFAULT_ADMIN_EMAIL=admin@example.com
readonly DEFAULT_ADMIN_NAME=Administrator
readonly DEFAULT_MODEL_BASE_URL=https://api.openai.com/v1
readonly DEFAULT_CHAT_MODEL=gpt-4o-mini
readonly APP_ROLE=utopia_app

# Secrets from the deploy form are copied into these unexported variables and removed from
# the environment, so neither utopia-server process inherits them.
ADMIN_PASSWORD_VALUE=""
MODEL_API_KEY_VALUE=""
EMBEDDING_API_KEY_VALUE=""
BOOT_PID=""
BOOT_URL=""
WORK=""
OWNER_URL=""
APP_URL=""
PUBLIC_PORT=""

log() { printf '[railway-start] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# flag NAME DEFAULT: prints true or false.
flag() {
  local name="$1" def="$2" raw
  raw="$(trim "${!name:-}")"
  case "$(lower "$raw")" in
    "") printf '%s' "$def" ;;
    true | 1 | yes | on) printf 'true' ;;
    false | 0 | no | off) printf 'false' ;;
    *)
      log "WARN: $name=\"$raw\" is not true or false; using $def"
      printf '%s' "$def"
      ;;
  esac
}

# uint NAME DEFAULT MIN MAX: prints a whole number in [MIN, MAX].
uint() {
  local name="$1" def="$2" min="$3" max="$4" raw
  raw="$(trim "${!name:-}")"
  if [ -z "$raw" ]; then
    printf '%s' "$def"
  elif [[ "$raw" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$raw))" -ge "$min" ] && [ "$((10#$raw))" -le "$max" ]; then
    printf '%s' "$((10#$raw))"
  else
    log "WARN: $name=\"$raw\" is not a number from $min to $max; using $def"
    printf '%s' "$def"
  fi
}

valid_http_url() {
  [[ "$1" =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]]
}

url_host() {
  local h="${1#*://}"
  printf '%s' "${h%%/*}"
}

# psql on the owner connection: no psqlrc, stop on the first error, unaligned quiet output.
pg() {
  PGCONNECT_TIMEOUT=10 psql "$OWNER_URL" -X -v ON_ERROR_STOP=1 -A -t -q "$@"
}

# ---------------------------------------------------------------- 1. runtime environment

cpu_quota() {
  local n q p c
  n="$(nproc 2>/dev/null || printf 2)"
  if read -r q p 2>/dev/null </sys/fs/cgroup/cpu.max && [[ "$q" =~ ^[0-9]+$ ]] && [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 0 ]; then
    c=$(((q + p - 1) / p))
    if [ "$c" -lt "$n" ]; then n="$c"; fi
  fi
  printf '%s' "$n"
}

setup_runtime() {
  PUBLIC_PORT="$(uint PORT "$DEFAULT_PORT" 1 65535)"
  export PORT="$PUBLIC_PORT"
  export UTOPIA_BIND_ADDR="[::]:$PUBLIC_PORT"

  # tokio sizes its worker pool from the host's cores, not the service's CPU share.
  local raw threads=""
  raw="$(trim "${RUNTIME_THREADS:-}")"
  if [ -n "$raw" ] && [ "$(lower "$raw")" != auto ]; then
    if [[ "$raw" =~ ^[0-9]{1,2}$ ]] && [ "$((10#$raw))" -ge 1 ] && [ "$((10#$raw))" -le 64 ]; then
      threads="$((10#$raw))"
    else
      log "WARN: RUNTIME_THREADS=\"$raw\" is not auto or a number from 1 to 64; using auto"
    fi
  fi
  if [ -z "$threads" ]; then
    threads="$(cpu_quota)"
    if [ "$threads" -lt 2 ]; then threads=2; fi
    if [ "$threads" -gt 8 ]; then threads=8; fi
  fi
  export TOKIO_WORKER_THREADS="$threads"

  local mem
  mem="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"
  if [[ "$mem" =~ ^[0-9]+$ ]]; then
    mem=$((mem / 1048576))
    log "container limits: ${mem} MiB memory, runtime threads $threads"
    if [ "$mem" -lt 1000 ]; then
      log "WARN: under 1 GB of memory: fine for evaluation; for large uploads lower Background workers in Administration -> Deployment, or use a plan with more memory"
    fi
  else
    log "runtime threads $threads"
  fi

  # Sealing key for stored model keys, connection strings and source tokens.
  local key
  key="$(trim "${UTOPIA_SECRET_KEY:-}")"
  if [ -n "$key" ]; then
    if [[ "$key" =~ ^[0-9A-Fa-f]{64}$ ]] || [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
      export UTOPIA_SECRET_KEY="$key"
    else
      log "WARN: UTOPIA_SECRET_KEY is not 64 hex characters (or base64 of 32 bytes); ignoring it, so the key file secret.key in the data directory is used. Values sealed with another key cannot be read."
      unset UTOPIA_SECRET_KEY
    fi
  fi

  local dir mnt
  dir="$(trim "${UTOPIA_DATA_DIR:-}")"
  if [ -z "$dir" ]; then dir="$DEFAULT_DATA_DIR"; fi
  export UTOPIA_DATA_DIR="$dir"
  mkdir -p "$dir" || die "cannot create the data directory $dir"
  mnt="$(df -P "$dir" 2>/dev/null | awk 'NR == 2 { print $6 }')"
  if [ "$mnt" = / ]; then
    log "WARN: no volume is mounted at $dir: uploaded files and the search index are lost on every redeploy. Attach a volume at $dir."
  fi
}

# ---------------------------------------------------------------- 2. Postgres

setup_urls() {
  OWNER_URL="$(trim "${UTOPIA_MIGRATION_URL:-}")"
  APP_URL="$(trim "${UTOPIA_DATABASE_URL:-}")"
  if [ -z "$OWNER_URL" ]; then OWNER_URL="$APP_URL"; fi
  case "$OWNER_URL" in
    postgres://* | postgresql://*) ;;
    "") die 'UTOPIA_MIGRATION_URL is empty: set it to ${{Postgres.DATABASE_URL}} (the Postgres service must be named Postgres)' ;;
    *) die "UTOPIA_MIGRATION_URL does not start with postgresql://" ;;
  esac
}

wait_for_db() {
  local limit deadline next err
  limit="$(uint DB_WAIT_SECONDS 600 30 3600)"
  deadline=$((SECONDS + limit))
  next=0
  while :; do
    if err="$(pg -c 'SELECT 1' 2>&1 >/dev/null)"; then
      log "Postgres is ready"
      return 0
    fi
    err="${err//$'\n'/ }"
    if [ "$SECONDS" -ge "$deadline" ]; then
      die "Postgres did not answer within ${limit}s (last error: ${err:0:300})"
    fi
    if [ "$SECONDS" -ge "$next" ]; then
      log "waiting for Postgres: ${err:0:200}"
      next=$((SECONDS + 30))
    fi
    sleep 3
  done
}

# ---------------------------------------------------------------- 3. least-privilege role

ensure_app_role() {
  local out
  if out="$(pg -v app_pw="$1" 2>&1 <<'SQL'
SELECT format('CREATE ROLE utopia_app LOGIN PASSWORD %L', :'app_pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'utopia_app')
\gexec
SELECT format('ALTER ROLE utopia_app WITH LOGIN PASSWORD %L', :'app_pw')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO utopia_app', current_database())
\gexec
SQL
  )"; then
    return 0
  fi
  log "WARN: could not create or update the role $APP_ROLE (${out//$'\n'/ }); running as the owner"
  return 1
}

# Migration 0010 grants utopia_app its rights when it runs, and only if the role exists by
# then. A schema created before the role existed has no grants: run as the owner instead.
app_role_has_grants() {
  local exists granted
  exists="$(pg -c "SELECT to_regclass('public.organizations') IS NOT NULL")" || return 1
  if [ "$exists" != t ]; then return 0; fi
  granted="$(pg -c "SELECT has_table_privilege('$APP_ROLE', 'public.organizations', 'SELECT')")" || return 1
  if [ "$granted" = t ]; then return 0; fi
  log "WARN: this database was set up before the role $APP_ROLE existed, so the role holds no grants; running as the owner"
  return 1
}

setup_db_identity() {
  local wanted pw use_app=false
  wanted="$(flag DB_LEAST_PRIVILEGE true)"
  pw="${UTOPIA_APP_DB_PASSWORD:-}"
  if [ "$wanted" = true ]; then
    if [ -z "$APP_URL" ] || [ "$APP_URL" = "$OWNER_URL" ]; then
      log "WARN: DB_LEAST_PRIVILEGE=true but UTOPIA_DATABASE_URL is empty or the owner connection; running as the owner"
    elif ! [[ "$pw" =~ ^[A-Za-z0-9]{16,128}$ ]]; then
      log "WARN: UTOPIA_APP_DB_PASSWORD must be 16 to 128 letters or digits (it is part of a URL); running as the owner"
    elif ensure_app_role "$pw" && app_role_has_grants; then
      use_app=true
    fi
  fi
  if [ "$use_app" = true ]; then
    export UTOPIA_DATABASE_URL="$APP_URL"
    export UTOPIA_MIGRATION_URL="$OWNER_URL"
    log "database: migrations as the owner, the app as $APP_ROLE (audit ledger append-only)"
  else
    export UTOPIA_DATABASE_URL="$OWNER_URL"
    unset UTOPIA_MIGRATION_URL
    log "database: the app runs as the owner"
  fi
  unset UTOPIA_APP_DB_PASSWORD
}

# ---------------------------------------------------------------- 4. first boot

count_organizations() {
  local exists
  exists="$(pg -c "SELECT to_regclass('public.organizations') IS NOT NULL")" || return 1
  if [ "$exists" != t ]; then
    printf '0'
    return 0
  fi
  pg -c 'SELECT count(*) FROM organizations'
}

start_private_server() {
  local port=15161 limit deadline rc
  if [ "$port" = "$PUBLIC_PORT" ]; then port=15162; fi
  BOOT_URL="http://127.0.0.1:$port"
  log "first boot: starting utopia-server on 127.0.0.1:$port only; it applies the database migrations now"
  UTOPIA_BIND_ADDR="127.0.0.1:$port" utopia-server &
  BOOT_PID=$!
  limit="$(uint BOOT_WAIT_SECONDS 600 60 3600)"
  deadline=$((SECONDS + limit))
  until curl -fs -o /dev/null --max-time 5 "$BOOT_URL/api/v1/health"; do
    if ! kill -0 "$BOOT_PID" 2>/dev/null; then
      wait "$BOOT_PID"
      rc=$?
      BOOT_PID=""
      die "utopia-server exited with status $rc during the first boot (see its log above)"
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      die "utopia-server did not answer on loopback within ${limit}s"
    fi
    sleep 2
  done
}

stop_private_server() {
  local i=0
  if [ -z "$BOOT_PID" ]; then return 0; fi
  kill -TERM "$BOOT_PID" 2>/dev/null
  while kill -0 "$BOOT_PID" 2>/dev/null && [ "$i" -lt 30 ]; do
    sleep 1
    i=$((i + 1))
  done
  kill -KILL "$BOOT_PID" 2>/dev/null
  wait "$BOOT_PID" 2>/dev/null
  BOOT_PID=""
}

admin_email() {
  local v
  v="$(trim "${ADMIN_EMAIL:-}")"
  if [ -z "$v" ] || [ "${#v}" -gt 254 ] || ! [[ "$v" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
    log "WARN: ADMIN_EMAIL=\"$v\" is not an email address; using $DEFAULT_ADMIN_EMAIL"
    v="$DEFAULT_ADMIN_EMAIL"
  fi
  printf '%s' "$v"
}

admin_name() {
  local v
  v="$(trim "${ADMIN_NAME:-}")"
  if [ -z "$v" ] || [ "${#v}" -gt 64 ]; then
    if [ -n "$v" ]; then log "WARN: ADMIN_NAME is longer than 64 characters; using $DEFAULT_ADMIN_NAME"; fi
    v="$DEFAULT_ADMIN_NAME"
  fi
  printf '%s' "$v"
}

# register_admin EMAIL NAME PASSWORD: prints the workspace id and leaves the session token
# in $WORK/auth as a header line. Values reach jq through its environment, not its argv.
register_admin() {
  local email="$1" name="$2" password="$3" code token workspace
  code="$(BOOT_EMAIL="$email" BOOT_PASSWORD="$password" BOOT_NAME="$name" \
    jq -n '{email: env.BOOT_EMAIL, password: env.BOOT_PASSWORD, display_name: env.BOOT_NAME}' |
    curl -s -o "$WORK/register.json" -w '%{http_code}' --max-time 60 -X POST \
      -H 'Content-Type: application/json' --data-binary @- "$BOOT_URL/api/v1/auth/register")"
  if [ "$code" != 200 ]; then
    log "registration answered HTTP $code: $(head -c 300 "$WORK/register.json" 2>/dev/null)"
    return 1
  fi
  if [ "$(jq -r '.user.is_admin' "$WORK/register.json")" != true ]; then
    log "the registered account is not the system administrator"
    return 1
  fi
  token="$(jq -r '.token // empty' "$WORK/register.json")"
  workspace="$(jq -r '.workspace.id // empty' "$WORK/register.json")"
  rm -f "$WORK/register.json"
  if [ -n "$token" ]; then printf 'Authorization: Bearer %s\n' "$token" >"$WORK/auth"; fi
  printf '%s' "$workspace"
}

seed_models() {
  local workspace="$1" key base chat emb ebase ekey code
  key="$(trim "$MODEL_API_KEY_VALUE")"
  base="$(trim "${MODEL_BASE_URL:-}")"
  base="${base%/}"
  if [ -z "$base" ]; then base="$DEFAULT_MODEL_BASE_URL"; fi
  ekey="$(trim "$EMBEDDING_API_KEY_VALUE")"
  if [ -z "$key" ] && [ -z "$ekey" ] && [ "$base" = "$DEFAULT_MODEL_BASE_URL" ]; then
    log "models: MODEL_API_KEY is empty; set the chat and embedding models in Administration -> Models"
    return 0
  fi
  if [ -z "$workspace" ] || [ ! -s "$WORK/auth" ]; then
    log "WARN: models: no session from the registration; set the models in Administration -> Models"
    return 0
  fi
  if ! valid_http_url "$base"; then
    log "WARN: models: MODEL_BASE_URL=\"$base\" is not an http(s) URL; nothing stored, set the models in Administration -> Models"
    return 0
  fi
  chat="$(trim "${CHAT_MODEL:-}")"
  if [ -z "$chat" ]; then chat="$DEFAULT_CHAT_MODEL"; fi
  emb="$(trim "${EMBEDDING_MODEL:-}")"
  ebase="$(trim "${EMBEDDING_BASE_URL:-}")"
  ebase="${ebase%/}"
  if [ -z "$ebase" ]; then ebase="$base"; fi
  if [ -z "$ekey" ]; then ekey="$key"; fi
  if [ -n "$emb" ] && ! valid_http_url "$ebase"; then
    log "WARN: models: EMBEDDING_BASE_URL=\"$ebase\" is not an http(s) URL; embeddings left unset"
    emb=""
  fi

  code="$(S_CB="$base" S_CK="$key" S_CM="$chat" S_EB="$ebase" S_EK="$ekey" S_EM="$emb" jq -n '
      def opt: if . == "" then null else . end;
      {chat_base_url: env.S_CB, chat_api_key: (env.S_CK | opt), chat_model: env.S_CM}
      + (if env.S_EM == "" then {}
         else {embed_base_url: env.S_EB, embed_api_key: (env.S_EK | opt), embed_model: env.S_EM} end)' |
    curl -s -o "$WORK/settings.json" -w '%{http_code}' --max-time 60 -X PUT \
      -H @"$WORK/auth" -H 'Content-Type: application/json' --data-binary @- \
      "$BOOT_URL/api/v1/workspaces/$workspace/settings")"
  if [ "$code" != 200 ]; then
    log "WARN: models: storing the settings answered HTTP $code: $(head -c 300 "$WORK/settings.json" 2>/dev/null); set them in Administration -> Models"
    return 0
  fi
  if [ -n "$emb" ]; then
    log "models: default workspace uses $chat at $(url_host "$base") for chat and $emb at $(url_host "$ebase") for embeddings"
  else
    log "WARN: models: chat $chat at $(url_host "$base") stored, EMBEDDING_MODEL is empty: documents cannot be embedded until an embedding model is set in Administration -> Models"
  fi

  # Same check as the Test button in Administration -> Models; the outcome is only logged.
  local summary
  code="$(curl -s -o "$WORK/test.json" -w '%{http_code}' --max-time 120 -X POST -H @"$WORK/auth" \
    "$BOOT_URL/api/v1/workspaces/$workspace/settings/test")"
  if [ "$code" = 200 ] && summary="$(jq -r '
      def outcome: if .ok == true then "ok" + (if .dim then " (dimension " + (.dim | tostring) + ")" else "" end)
                   else "failed: " + ((.error // "unknown") | tostring | .[0:200]) end;
      "chat " + (.chat | outcome) + "; embeddings " + (.embed | outcome)' "$WORK/test.json")"; then
    log "models: connectivity test: $summary"
  else
    log "WARN: models: connectivity test answered HTTP $code"
  fi
}

first_boot() {
  local email name open workspace password="$ADMIN_PASSWORD_VALUE"
  if [ "${#password}" -lt 8 ]; then
    die "ADMIN_PASSWORD must be at least 8 characters. The instance stays closed until it is set: an unclaimed Utopia makes whoever signs up first its administrator."
  fi
  email="$(admin_email)"
  name="$(admin_name)"
  open="$(flag OPEN_REGISTRATION false)"

  start_private_server
  if ! pg -c "UPDATE deployment_settings SET open_registration = $open" >/dev/null; then
    if [ "$open" = false ]; then
      die "could not close self-registration (deployment_settings); refusing to open the public port"
    fi
    log "WARN: could not write the self-registration setting"
  fi
  if ! workspace="$(register_admin "$email" "$name" "$password")"; then
    die "could not register the administrator account"
  fi
  log "administrator account created: $email (password: the ADMIN_PASSWORD variable)"
  if [ "$open" = true ]; then
    log "self-registration: open (anyone who can reach this URL may sign up as a viewer)"
  else
    log "self-registration: closed (add people in Administration -> Users)"
  fi
  seed_models "$workspace"
  stop_private_server
}

cleanup() {
  stop_private_server
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}

main() {
  trap cleanup EXIT
  trap 'log "stopping on signal"; exit 143' TERM INT
  ADMIN_PASSWORD_VALUE="${ADMIN_PASSWORD:-}"
  MODEL_API_KEY_VALUE="${MODEL_API_KEY:-}"
  EMBEDDING_API_KEY_VALUE="${EMBEDDING_API_KEY:-}"
  unset ADMIN_PASSWORD MODEL_API_KEY EMBEDDING_API_KEY
  WORK="$(mktemp -d)" || die "mktemp failed"

  setup_runtime
  setup_urls
  wait_for_db
  setup_db_identity

  local orgs
  orgs="$(count_organizations)" || die "could not read the organizations table"
  if [ "$orgs" = 0 ]; then
    first_boot
  else
    log "existing deployment: ADMIN_*, OPEN_REGISTRATION and the model variables are first-boot settings and were not re-applied"
  fi

  cleanup
  trap - EXIT
  log "starting utopia-server on [::]:$PUBLIC_PORT"
  exec utopia-server
}

main "$@"
