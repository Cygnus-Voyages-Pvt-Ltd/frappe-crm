#!/bin/bash
# Boot sequence for the all-in-one Railway service.
#
#   1. make the (empty) Railway volume usable by the `frappe` user
#   2. relink image-baked assets into sites/
#   3. wait for MariaDB + Redis (Railway's private network needs a moment)
#   4. write sites/common_site_config.json from env vars
#   5. create the site on first boot, migrate on every later boot
#   6. hand over to supervisord
set -euo pipefail

BENCH=/home/frappe/frappe-bench
SITE=${SITE_NAME:-crm.local}
DB_PORT=${DB_PORT:-3306}
PORT=${PORT:-8080}

cd "$BENCH"

if [ "$(id -u)" = "0" ]; then
	as_frappe() { runuser -u frappe -- "$@"; }
else
	as_frappe() { "$@"; }
fi

log() { echo "[railway-entrypoint] $*"; }

require() {
	if [ -z "${!1:-}" ]; then
		log "FATAL: required environment variable $1 is not set"
		exit 1
	fi
}

require DB_HOST
require DB_ROOT_PASSWORD
require REDIS_CACHE_URL
require REDIS_QUEUE_URL
require ADMIN_PASSWORD

# --- 1. volume ownership -----------------------------------------------------
# Railway mounts volumes owned by root; every bench process runs as `frappe`.
mkdir -p "$BENCH/sites" "$BENCH/logs"
if [ "$(id -u)" = "0" ]; then
	chown frappe:frappe "$BENCH/sites" "$BENCH/logs"
	# A recursive chown is only needed when the tree is actually wrong -- doing it
	# on every boot would crawl a large files/ directory for nothing.
	if [ ! -d "$BENCH/sites/$SITE" ] || [ "$(stat -c '%U' "$BENCH/sites/$SITE")" != "frappe" ]; then
		log "fixing ownership of sites/"
		chown -R frappe:frappe "$BENCH/sites"
	fi
fi

# --- 2. assets ---------------------------------------------------------------
rm -rf "$BENCH/sites/assets"
ln -s "$BENCH/assets" "$BENCH/sites/assets"

# apps.txt lives on the volume, which starts empty -- regenerate it every boot.
as_frappe bash -c "ls -1 $BENCH/apps > $BENCH/sites/apps.txt"
[ -f "$BENCH/sites/common_site_config.json" ] || as_frappe bash -c "echo '{}' > $BENCH/sites/common_site_config.json"

# --- 3. dependencies ---------------------------------------------------------
log "waiting for MariaDB at $DB_HOST:$DB_PORT"
wait-for-it -t 180 "$DB_HOST:$DB_PORT"

wait_for_redis() {
	local url=$1 name=$2 i
	for i in $(seq 1 60); do
		if "$BENCH/env/bin/python" -c "
import sys, redis
try:
    redis.from_url('$url', socket_connect_timeout=3).ping()
except Exception:
    sys.exit(1)
" >/dev/null 2>&1; then
			log "$name is up"
			return 0
		fi
		sleep 2
	done
	log "FATAL: $name did not become reachable"
	exit 1
}
wait_for_redis "$REDIS_CACHE_URL" "redis cache"
wait_for_redis "$REDIS_QUEUE_URL" "redis queue"

# --- 4. common_site_config.json ---------------------------------------------
log "writing common_site_config.json"
as_frappe bench set-config -g db_host "$DB_HOST"
as_frappe bench set-config -gp db_port "$DB_PORT"
as_frappe bench set-config -g redis_cache "$REDIS_CACHE_URL"
as_frappe bench set-config -g redis_queue "$REDIS_QUEUE_URL"
as_frappe bench set-config -g redis_socketio "$REDIS_QUEUE_URL"
as_frappe bench set-config -gp socketio_port "${SOCKETIO_PORT:-9000}"
as_frappe bench set-config -g chromium_path /usr/bin/chromium-headless-shell
as_frappe bench set-config -gp developer_mode 0
as_frappe bench set-config -gp maintenance_mode 0

# --- 5. site -----------------------------------------------------------------
if [ ! -d "$BENCH/sites/$SITE" ]; then
	log "creating site $SITE (first boot)"
	as_frappe bench new-site "$SITE" \
		--db-root-username "${DB_ROOT_USER:-root}" \
		--db-root-password "$DB_ROOT_PASSWORD" \
		--admin-password "$ADMIN_PASSWORD" \
		--mariadb-user-host-login-scope='%' \
		--install-app crm \
		--set-default
elif [ "${AUTO_MIGRATE:-1}" = "1" ]; then
	log "running bench migrate on $SITE"
	as_frappe bench --site "$SITE" migrate
fi

as_frappe bench use "$SITE"

# Used for links in outgoing email and OAuth redirects.
PUBLIC_URL=${PUBLIC_URL:-${RAILWAY_PUBLIC_DOMAIN:+https://$RAILWAY_PUBLIC_DOMAIN}}
if [ -n "${PUBLIC_URL:-}" ]; then
	as_frappe bench --site "$SITE" set-config host_name "$PUBLIC_URL"
fi

# --- 6. processes ------------------------------------------------------------
# nginx-entrypoint.sh renders the template shipped in frappe/base; that template
# hardcodes `listen 8080`, so retarget it at whatever port Railway routes to.
sed -i "s/listen 8080;/listen ${PORT};/" /templates/nginx/frappe.conf.template

# The nginx master runs as whoever supervisord runs as (root here, so it can
# open the container's root-owned log pipes); pin the worker processes to frappe
# so request handling stays unprivileged.
if [ "$(id -u)" = "0" ]; then
	grep -q '^user ' /etc/nginx/nginx.conf || sed -i '1i user frappe;' /etc/nginx/nginx.conf
fi

export BACKEND=${BACKEND:-127.0.0.1:8000}
export SOCKETIO=${SOCKETIO:-127.0.0.1:${SOCKETIO_PORT:-9000}}
# Fixed site name: any Host header (railway.app subdomain, custom domain,
# healthcheck probe) resolves to the same site.
export FRAPPE_SITE_NAME_HEADER=${FRAPPE_SITE_NAME_HEADER:-$SITE}
export UPSTREAM_REAL_IP_ADDRESS=${UPSTREAM_REAL_IP_ADDRESS:-0.0.0.0/0}
export UPSTREAM_REAL_IP_HEADER=${UPSTREAM_REAL_IP_HEADER:-X-Forwarded-For}
export UPSTREAM_REAL_IP_RECURSIVE=${UPSTREAM_REAL_IP_RECURSIVE:-off}
export PROXY_READ_TIMEOUT=${PROXY_READ_TIMEOUT:-120}
export CLIENT_MAX_BODY_SIZE=${CLIENT_MAX_BODY_SIZE:-50m}

log "starting supervisord"
exec supervisord -c /etc/supervisor/frappe.conf -n
