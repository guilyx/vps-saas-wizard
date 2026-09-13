---
name: vps-deploy-app
description: Deploy, redeploy, add or remove a Docker Compose application on a VPS already prepared by vps-wizard - clone from git, manage the app .env, attach it to the Caddy/Traefik proxy with TLS, roll a new version, tail logs, run one-off commands. Use when asked to ship an app to the server, redeploy after a push, add a second app/domain, change an environment variable, or debug a running app.
---

# Deploying apps with vps-wizard

Assumes the host was prepared with the `vps-saas-wizard` skill (Docker, proxy
and firewall are in place). All commands run on the host as root or the
deploy user with sudo.

## Add a new app (idempotent)

```bash
sudo vps-wizard app add --yes \
  --name shop \
  --source https://github.com/org/shop.git --branch main \
  --domain shop.example.com --www \
  --service web --port 3000 --health /healthz \
  --env "DATABASE_URL=postgres://shop:pw@db/shop,STRIPE_KEY=sk_live_x"
```

- `--source` accepts `https://`, `git@` (a per-app read-only deploy key is
  generated at `/opt/apps/<name>/deploy_key.pub` - add it to the repo), a
  local directory, or nothing (scaffolds a `whoami` demo to validate TLS).
- `--service`/`--port` are auto-detected from the compose file when omitted
  (`web`/`app`/`frontend`/`api`/... then `ports:`/`expose:`).
- The app's own compose file is never edited. A `compose.wizard.yml` overlay
  attaches the web service to the `proxy` network, sets `restart:
  unless-stopped`, log rotation and `no-new-privileges`.
- `.env` is built from the repo's `.env.example` (or `.env.sample`,
  `.env.template`): `--env` overrides win, empty secret-looking keys are
  generated, URL keys default to `https://<domain>`. Mode 600.
- The proxy site is written (`/opt/proxy/sites/<name>.caddy` or
  `/opt/proxy/dynamic/<name>.yml`), validated and hot-reloaded; TLS is issued
  on first request once DNS points at the host.

Requirements for the app repo: a compose file at the root (or
`--compose-file path`), the HTTP service must listen on `0.0.0.0:<port>`
inside the container and **must not publish ports** (`ports:` on
`0.0.0.0`); databases should also stay unpublished (they're reachable by
service name inside the compose network).

## Day-2 operations

```bash
sudo vps-wizard app list                          # name, url, service states
sudo vps-wizard app deploy shop                   # git pull + build --pull + up -d + wait healthy
sudo vps-wizard app deploy shop --no-pull         # redeploy current checkout (after env change)
sudo vps-wizard app logs shop [service]           # follow logs
sudo vps-wizard app ps shop
sudo vps-wizard app restart shop
sudo vps-wizard app exec shop web sh -c 'npm run migrate'
sudo vps-wizard app remove shop [--purge]         # --purge deletes files and volumes
```

`app deploy` is what CI should call over SSH (see `examples/github-deploy.yml`).
It exits non-zero and prints the last 50 log lines if the service dies.

## Environment variables

```bash
sudo vps-wizard env shop list                     # secrets masked
sudo vps-wizard env shop get SMTP_HOST
sudo vps-wizard env shop set SMTP_HOST=smtp.x.com SMTP_PORT=587
sudo vps-wizard env shop unset OLD_FLAG
sudo vps-wizard env shop path                     # /opt/apps/shop/.env
sudo vps-wizard app deploy shop --no-pull         # apply
```

Never `cat` the `.env` into a chat transcript; use `env <app> list`.

## Database and one-off tasks

Databases run as compose services in the app's stack. Reach them from the
app service (`db:5432`) or with `app exec`:

```bash
sudo vps-wizard app exec shop db psql -U shop -d shop -c '\dt'
sudo vps-backup --app shop                        # on-demand backup (pg_dumpall / mysqldump + volumes)
ls /var/backups/vps-wizard/
```

## Verifying a deploy

```bash
sudo vps-wizard doctor                            # DNS, TLS expiry, HTTP status, health, exposed ports
curl -sSI https://shop.example.com/healthz
sudo docker logs proxy-caddy --tail 50            # or proxy-traefik
```

Common causes of a failing site: DNS not pointing at the host (or Cloudflare
mode mismatch), the service listening on 127.0.0.1 inside the container,
wrong `--port`, or the health path returning non-2xx/3xx (Caddy marks the
upstream down).
