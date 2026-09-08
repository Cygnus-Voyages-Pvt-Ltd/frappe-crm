# Self-hosting Frappe CRM on Railway

Railway gives each service **one** volume, and a volume **cannot be shared between
services**. Frappe's standard `frappe_docker` compose stack breaks that rule: `backend`,
`websocket`, the workers, `scheduler` and `frontend` all mount the same `sites` volume
(site config, uploaded files, assets). So the compose file cannot be imported into
Railway as-is.

The layout here instead is:

| Railway service | What it is | Storage |
| --- | --- | --- |
| `crm` | this repo, built by `docker/railway/Dockerfile` — nginx + gunicorn + socket.io + 2 RQ workers + scheduler, under supervisord | volume at `/home/frappe/frappe-bench/sites` |
| `mariadb` | `mariadb:11.8` image service | volume at `/var/lib/mysql` |
| `redis` | Railway Redis template (cache **and** queue) | none needed |

Trade-off: the bench cannot scale horizontally — one replica only. Frappe's `sites`
directory is shared mutable state, so a second replica would fight over it. Vertical
scaling (more RAM/CPU, more gunicorn workers) is the way up.

---

## 1. Create the project and the database

1. New project on Railway → **Empty project**.
2. **+ New → Database → Add MariaDB** (or **Docker Image** → `mariadb:11.8`). Name it `mariadb`.
3. On the `mariadb` service:
   - **Settings → Deploy → Custom Start Command**:
     ```
     --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --skip-character-set-client-handshake --bind-address=*
     ```
     Frappe requires the utf8mb4 server defaults; `--bind-address=*` makes MariaDB listen on
     IPv6 as well, which Railway's private network needs in environments created before
     2025-10-16.
   - **Variables**: `MARIADB_ROOT_PASSWORD` = a long random string (the image creates
     `root@'%'` by default, which is what `bench new-site` needs in order to create the
     site database).
   - **Settings → Volume**: mount at `/var/lib/mysql`.

## 2. Add Redis

**+ New → Database → Add Redis**. One instance backs both `redis_cache` and `redis_queue`
— Frappe namespaces its cache keys and RQ prefixes its own with `rq:`, and Frappe never
issues a `FLUSHALL`. Split them later if queue throughput warrants it.

## 3. Add the CRM service

**+ New → GitHub Repo → `Cygnus-Voyages-Pvt-Ltd/frappe-crm`**, branch `develop`.

`railway.json` at the repo root already selects the Dockerfile builder and
`docker/railway/Dockerfile`, so no build settings need touching.

### Variables

```
DB_HOST=${{mariadb.RAILWAY_PRIVATE_DOMAIN}}
DB_PORT=3306
DB_ROOT_USER=root
DB_ROOT_PASSWORD=${{mariadb.MARIADB_ROOT_PASSWORD}}
REDIS_CACHE_URL=${{Redis.REDIS_URL}}
REDIS_QUEUE_URL=${{Redis.REDIS_URL}}
SITE_NAME=crm.local
ADMIN_PASSWORD=<pick a strong one>
PORT=8080
RAILWAY_RUN_UID=0
GUNICORN_WORKERS=2
GUNICORN_THREADS=4
AUTO_MIGRATE=1
```

`SITE_NAME` must not equal an installed app name -- `bench new-site crm` is rejected because
the bench already has an app called `crm`. The name is internal (nginx pins
`FRAPPE_SITE_NAME_HEADER` to it), so it never has to match your domain.

`${{service.VAR}}` is Railway's reference syntax — match the service names you actually
used. `RAILWAY_RUN_UID=0` is what lets the entrypoint chown the volume (Railway mounts it
root-owned, every bench process runs as `frappe`).

### Volume

**Settings → Volume → Mount path**: `/home/frappe/frappe-bench/sites`.
This holds `common_site_config.json`, the site directory, and all uploaded files. Back it
up (Railway volume backups, and/or `bench backup` on a schedule).

### Networking

**Settings → Networking → Generate Domain**, target port **8080**.

Deploy. The first build takes 10–20 minutes (it clones Frappe, installs both Python and
Node dependency trees, and compiles the desk bundles plus the Vue SPA). First boot then
runs `bench new-site crm.local --install-app crm`, which is why `healthcheckTimeout` is 600s.

Open `https://<your-domain>/crm` and log in as `Administrator` with `ADMIN_PASSWORD`.
`/app` is the Frappe desk, if you need it.

## 4. Custom domain

Add it under **Settings → Networking → Custom Domain** and point the CNAME as instructed.
Nothing else changes: nginx is configured with `FRAPPE_SITE_NAME_HEADER=crm.local`, a fixed
site name, so every `Host` header resolves to the same site. Set `PUBLIC_URL=https://crm.example.com`
so links in outgoing email use the real domain.

---

## Operating it

- **Every deploy is downtime.** Railway will not run two deployments mounted to the same
  volume, so the old container stops before the new one starts, and the new one runs
  `bench migrate` before nginx accepts traffic. Budget a minute or two per deploy.

- **Migrations** run automatically on every boot (`AUTO_MIGRATE=1`). Set it to `0` and run
  `bench --site crm.local migrate` by hand (`railway ssh`) if you would rather control the timing.
- **A shell**: `railway ssh` → `cd /home/frappe/frappe-bench` → `runuser -u frappe -- bench --site crm.local console`.
- **Process control**: `supervisorctl -c /etc/supervisor/frappe.conf status`.
- **Backups**: `runuser -u frappe -- bench --site crm.local backup --with-files`, written to
  `sites/crm.local/private/backups` on the volume. Frappe's scheduler also takes daily backups
  once configured in System Settings.
- **Email**: configure an outgoing Email Account in the desk; nothing is set up by default.

## Choosing the Frappe branch

`FRAPPE_BRANCH` defaults to `version-16` (build arg in the Dockerfile), which satisfies
this app's declared range (`frappe = ">=16.0.0-dev,<=17.0.0-dev"` in `pyproject.toml`).
CI for this branch only tests against Frappe **`develop`**, so if the image build or
`bench migrate` fails on an API that has not been backported, set the build arg
`FRAPPE_BRANCH=develop` (Railway: **Settings → Build → Build Args**, or edit the default in
`docker/railway/Dockerfile`). Frappe `develop` is a moving target — pin it only if you must.

## Cost / sizing

Roughly 1.5–2 GB RAM for the CRM service (2 gunicorn workers + node + 2 RQ workers +
scheduler + nginx) and ~0.5 GB for MariaDB. Lower `GUNICORN_WORKERS` to 1 on a small plan.
