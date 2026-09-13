---
name: vps-saas-wizard
description: Provision and harden a bare Debian/Ubuntu VPS and deploy a Docker Compose SaaS on it with vps-wizard - non-root deploy user, hardened SSH, UFW (docker-aware), sysctl anti-DDoS, fail2ban, Docker, optional Tailscale, Caddy/Traefik with automatic TLS, app .env handling, backups. Use when asked to set up a server, deploy an app to a VPS, harden a VPS, configure firewall/fail2ban/Tailscale on a server, or run vps-wizard non-interactively.
---

# vps-saas-wizard (agent guide)

`vps-wizard` is a zero-dependency Bash CLI that turns a fresh VPS into a
production host and deploys a compose app behind a TLS proxy. It has an
interactive TUI for humans and a **config-file driven, non-interactive mode
for agents**. Everything is idempotent: re-running a step converges.

## Install on the target host (run as root over SSH)

```bash
curl -fsSL https://raw.githubusercontent.com/guilyx/vps-saas-wizard/main/install.sh | sudo bash
vps-wizard --version
```

## The non-interactive workflow (use this)

1. **Write a config file** (KEY=VALUE, see `examples/wizard.conf.example`).
   Minimum for a real deployment:

   ```bash
   cat > /root/wizard.conf <<'EOF'
   PROXY_EMAIL=ops@example.com          # Let's Encrypt contact (required)
   APP_NAME=myapp                       # slug
   APP_SOURCE=https://github.com/org/app.git
   APP_BRANCH=main
   APP_DOMAIN=app.example.com           # DNS A record must already point here
   APP_SERVICE=web                      # compose service that serves HTTP (auto-detected if empty)
   APP_PORT=3000                        # container port (auto-detected if empty)
   APP_ENV_VARS=DATABASE_URL=postgres://app:pw@db/app,SMTP_HOST=smtp.example.com
   DEPLOY_USER_SSH_KEY=root             # copy root's authorized_keys to the deploy user
   EOF
   ```

   Secrets that are empty in the app's `.env.example` and look like secrets
   (`*SECRET*`, `*PASSWORD*`, `*TOKEN*`, `*_KEY`) are generated automatically.
   URL-ish keys (`APP_URL`, `NEXTAUTH_URL`, ...) default to `https://$APP_DOMAIN`.

2. **Dry-run first** and read the output. It prints every command and every
   file that would be written, without root and without changing anything:

   ```bash
   vps-wizard plan -c /root/wizard.conf
   ```

3. **Apply**:

   ```bash
   sudo vps-wizard apply -c /root/wizard.conf --yes
   ```

   Exit code 0 means every enabled step converged. On failure the wizard
   stops at the failing command and prints the last log lines; the log path
   is `/var/log/vps-wizard/wizard-<timestamp>.log`.

4. **Confirm SSH access - mandatory.** The access step arms a safety net:
   if `vps-wizard confirm` is not run within `ACCESS_ROLLBACK_MINUTES`
   (default 15), the sshd drop-in is removed and the firewall re-opens the
   old port, so nobody gets locked out. As an agent, after `apply`:

   ```bash
   # from your side, in a NEW connection (not the one you applied from):
   ssh -p <SSH_PORT> <DEPLOY_USER>@<host> 'sudo vps-wizard confirm'
   ```

   If the new login fails, do nothing: the rollback restores the previous
   SSH config automatically. Investigate with the old connection.

5. **Verify**:

   ```bash
   sudo vps-wizard doctor     # exit 0 = healthy; prints each check
   sudo vps-wizard status     # what is installed / configured
   sudo vps-wizard report     # markdown report with URLs, ports, next steps
   ```

## Steps (execution order) and how to run one

```
preflight system access firewall hardening fail2ban docker tailscale proxy app backups ops
```

```bash
sudo vps-wizard step firewall --yes           # one step, non-interactive
sudo vps-wizard apply --only proxy,app --yes  # subset
sudo vps-wizard apply --skip tailscale --yes  # everything but
```

Steps are gated by config: `FIREWALL_ENABLE`, `FAIL2BAN_ENABLE`,
`DOCKER_INSTALL`, `TAILSCALE_ENABLE`, `PROXY_TYPE=none`, `APP_ENABLE`,
`BACKUP_ENABLE`, `OPS_ENABLE`.

## Key config decisions (defaults are best practice)

| Goal | Keys |
|------|------|
| Change SSH port | `SSH_PORT=2222` (firewall + fail2ban follow automatically) |
| Keep root login / passwords (not recommended) | `SSH_DISABLE_ROOT_LOGIN=false`, `SSH_DISABLE_PASSWORD_AUTH=false` |
| Behind Cloudflare (orange cloud) | `FIREWALL_CLOUDFLARE_ONLY=true` (80/443 only from CF ranges, real client IP restored, connection limits raised) |
| Tailscale for admin access | `TAILSCALE_ENABLE=true`, `TAILSCALE_AUTH_KEY=tskey-auth-...`, `TAILSCALE_SSH=true` |
| Hide SSH from the internet | additionally `TAILSCALE_RESTRICT_SSH=true` (rollback armed; confirm over Tailscale) |
| Traefik instead of Caddy | `PROXY_TYPE=traefik` (adds per-IP rateLimit/inFlightReq middlewares) |
| Extra public ports (rare) | `FIREWALL_EXTRA_TCP_PORTS=8443,9000` |
| Offsite backups | `BACKUP_RESTIC_REPOSITORY=s3:s3.amazonaws.com/bucket/vps`, `BACKUP_RESTIC_ENV=AWS_ACCESS_KEY_ID=..,AWS_SECRET_ACCESS_KEY=..` |
| Private dashboards | `OPS_ENABLE=true` (Dozzle + Uptime Kuma bound to the Tailscale IP or 127.0.0.1) |
| Disable the lock-out safety net (CI with known-good key) | `ACCESS_ROLLBACK_MINUTES=0` |

Environment variables override config keys: `PROXY_TYPE=traefik vps-wizard plan -c f`.
Print the effective value of any key with `vps-wizard config KEY`.

## Where things live on the host

| Path | Purpose |
|------|---------|
| `/etc/vps-wizard/wizard.conf` | saved answers (mode 600) - re-apply with `vps-wizard apply --yes` |
| `/etc/vps-wizard/report.md` | last deployment report |
| `/etc/vps-wizard/state/` | step completion markers and facts (`tailscale.ip`, `ssh.previous_port`) |
| `/var/log/vps-wizard/` | full command logs |
| `/opt/proxy/` | proxy compose + `Caddyfile` + `sites/*.caddy` (or `traefik.yml` + `dynamic/*.yml`) + `logs/access.log` |
| `/opt/apps/<name>/src` | app checkout |
| `/opt/apps/<name>/.env` | app environment (mode 600) |
| `/opt/apps/<name>/compose.wizard.yml` | overlay joining the `proxy` network |
| `/opt/apps/<name>/app.conf`, `deploy.sh` | app metadata and redeploy script |
| `/usr/local/bin/vps-backup` | backup script (`systemctl list-timers vps-backup.timer`) |

## Safety rules the wizard enforces (do not work around them)

- It refuses to disable password auth or root login without a usable public key
  for the deploy user (`DEPLOY_USER_SSH_KEY`).
- It never closes the public SSH port unless Tailscale reports `Running`, and
  always arms the rollback timer when it does.
- Only the proxy publishes ports. App services must **not** use `ports:` on
  `0.0.0.0`; they are reached through the `proxy` docker network. Docker
  published ports are filtered by ufw via the `DOCKER-USER` chain.
- `.env` files are 600 and never printed by `vps-wizard env <app> list`
  (secret-looking values are masked).

## Troubleshooting quick map

| Symptom | Check |
|---------|-------|
| `apply` failed | tail the log printed in the error; fix; re-run the same `apply` or `step` (idempotent) |
| No TLS / 502 | `vps-wizard doctor`; DNS must resolve to the host public IP; `docker logs proxy-caddy --tail 100` |
| App unhealthy | `vps-wizard app logs <name>`; `vps-wizard app ps <name>` |
| Locked out | wait for the rollback timer (`ACCESS_ROLLBACK_MINUTES`) then reconnect on the old port |
| Banned yourself | from console/Tailscale: `fail2ban-client unban <ip>`; add your IP to `FAIL2BAN_IGNOREIP` |

Related skills: `vps-deploy-app` (add/update apps on an already prepared
host), `vps-doctor` (diagnose a host).
