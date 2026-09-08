# syntax=docker/dockerfile:1
#
# All-in-one Frappe CRM image for Railway.
#
# Railway attaches at most one volume per service and a volume cannot be shared
# between services, so the whole bench (nginx + gunicorn + socket.io + workers +
# scheduler) runs in ONE container against ONE `sites` volume. MariaDB and Redis
# are separate Railway services.
#
# Mirrors frappe_docker's layered/production Containerfile, plus supervisord.

ARG FRAPPE_BRANCH=version-16

FROM frappe/build:${FRAPPE_BRANCH} AS builder

ARG FRAPPE_BRANCH=version-16
ARG FRAPPE_PATH=https://github.com/frappe/frappe

USER frappe

# Bench + frappe only. Assets are built once, after the CRM app is in place.
RUN bench init \
      --frappe-branch=${FRAPPE_BRANCH} \
      --frappe-path=${FRAPPE_PATH} \
      --no-procfile \
      --no-backups \
      --skip-redis-config-generation \
      --skip-assets \
      --verbose \
      /home/frappe/frappe-bench

# The app is this repo, so it is copied instead of `bench get-app`-ed: no deploy
# key or PAT is needed for the private fork, and the image matches the commit
# Railway is building.
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/crm

WORKDIR /home/frappe/frappe-bench

# The manual equivalent of `bench get-app`: pip install -e, register in apps.txt,
# build assets. `bench build` runs `yarn install && yarn build` for every app
# whose package.json has a build script -- that is what compiles the Vue SPA to
# crm/public/frontend and crm/www/crm.html.
RUN echo "{}" > sites/common_site_config.json \
    && ./env/bin/pip install --no-cache-dir --upgrade -e apps/crm \
    && ls -1 apps > sites/apps.txt \
    && bench build --production --verbose \
    && rm -rf apps/crm/node_modules apps/crm/frontend/node_modules \
    && find apps -mindepth 1 -path "*/.git" | xargs rm -fr


FROM frappe/base:${FRAPPE_BRANCH} AS crm

USER root

RUN apt-get update \
    && apt-get install --no-install-recommends -y supervisor \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

# Assets live in an image layer; the entrypoint symlinks them back into the
# mounted (initially empty) sites volume on every boot.
RUN cp -r /home/frappe/frappe-bench/sites/assets /home/frappe/frappe-bench/assets \
    && rm -rf /home/frappe/frappe-bench/sites/assets

COPY docker/railway/supervisord.conf /etc/supervisor/frappe.conf
COPY docker/railway/entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod 755 /usr/local/bin/railway-entrypoint.sh

ENV PORT=8080 \
    SOCKETIO_PORT=9000 \
    SITE_NAME=crm.local \
    GUNICORN_WORKERS=2 \
    GUNICORN_THREADS=4 \
    GUNICORN_TIMEOUT=120 \
    AUTO_MIGRATE=1

EXPOSE 8080

# Starts as root so the Railway volume can be chowned, then supervisord drops
# every process to the `frappe` user.
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
