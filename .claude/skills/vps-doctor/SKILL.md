---
name: vps-doctor
description: Diagnose and fix a VPS managed by vps-wizard - failing TLS, 502s, unhealthy or restart-looping containers, firewall/ufw and docker port exposure, fail2ban bans, SSH lock-out and the rollback safety net, disk pressure, backup timer. Use when a deployed site is down, a server "stopped working", someone is locked out or banned, or when asked to audit/harden an existing host.
---

# Diagnosing a vps-wizard host

Start with the built-in checks; they encode the expected end state.

```bash
sudo vps-wizard doctor          # ✔/▲/✖ per check, exit 0 = healthy
sudo vps-wizard status          # per-step summary incl. ufw rules, jails, containers
sudo vps-wizard report          # what was deployed, URLs, ports
ls -t /var/log/vps-wizard/ | head -1   # latest run log
```

Then go by symptom.

## Site down / no TLS / 502

1. `vps-wizard doctor` - look at the DNS line for the app and the proxy line.
2. DNS must resolve to the host's public IP (or to Cloudflare when
   `FIREWALL_CLOUDFLARE_ONLY=true`). Fix DNS first; Let's Encrypt cannot issue
   otherwise and Caddy will keep retrying with back-off.
3. Proxy logs: `docker logs proxy-caddy --tail 100` (or `proxy-traefik`).
   `no such host`/`connection refused` to `web:3000` means the app service is
   down, on the wrong port, or listening on 127.0.0.1 inside the container.
4. App: `vps-wizard app ps <name>` and `vps-wizard app logs <name>`.
   Restart loop → usually a missing env var: `vps-wizard env <name> list`.
5. Upstream health: Caddy marks an upstream unhealthy when
   `HEALTHCHECK_PATH` (in `/opt/apps/<name>/app.conf`) is not 2xx/3xx.
   Change it with `app add` again (idempotent) or edit the site file and
   `docker exec proxy-caddy caddy reload --config /etc/caddy/Caddyfile`.
6. Ports 80/443 must be listened on by the proxy only: `ss -ltnp | grep -E ':80|:443'`.

## Container publishing ports it shouldn't

`doctor` warns "containers publishing ports on all interfaces". Docker
published ports are filtered by ufw through the `DOCKER-USER` chain
(`grep VPS-WIZARD /etc/ufw/after.rules`), so they are not reachable from the
internet unless `ufw route allow ... port N` exists - but the fix is to
remove the `ports:` mapping from the app compose file and rely on the
`proxy` network. Re-run `vps-wizard step firewall --yes` if the hook is
missing (e.g. after a manual ufw reset).

## Locked out of SSH

- Within `ACCESS_ROLLBACK_MINUTES` of a run: wait. The safety timer
  (`systemctl list-timers vpsw-rollback-ssh.timer`) removes
  `/etc/ssh/sshd_config.d/00-vps-wizard.conf` and re-allows the old port.
  `/etc/vps-wizard/state/ssh.rolled_back` records that it fired.
- After confirmation: use the provider's console or Tailscale SSH
  (`tailscale ssh deploy@host`). Check `sshd -T | grep -E 'port|allowusers|passwordauth'`
  and `ufw status numbered`. Keys live in `/home/<deploy>/.ssh/authorized_keys`.
- Public SSH closed on purpose (`TAILSCALE_RESTRICT_SSH=true`): the state file
  `/etc/vps-wizard/state/ssh.restricted_to_tailscale` exists. Re-open with
  `ufw limit <port>/tcp` from a console if Tailscale is broken.

## Banned by fail2ban

```bash
sudo fail2ban-client status                  # jails
sudo fail2ban-client status sshd             # banned IPs
sudo fail2ban-client unban <ip>
sudo fail2ban-client set vps-http-flood addignoreip <ip>
```

Persist exemptions in `FAIL2BAN_IGNOREIP` and re-run `vps-wizard step fail2ban --yes`.
The HTTP jail (`vps-http-flood`) bans after `FAIL2BAN_HTTP_MAXRETRY` 4xx in
`FAIL2BAN_FINDTIME` from `/opt/proxy/logs/access.log`; a real user hitting a
404-heavy SPA route can trip it - raise the threshold or ignore their IP.

## Under attack / high load

- `ufw status verbose`, `dmesg | grep -i 'UFW'`, `ss -s`, `conntrack -S` if installed.
- Per-IP limits live in `/etc/ufw/before.rules` between the `VPS-WIZARD
  RATELIMIT` markers; tune `HARDEN_HTTP_*` and re-run `step hardening`.
- Volumetric attacks need Cloudflare: enable the proxy in DNS, then set
  `FIREWALL_CLOUDFLARE_ONLY=true` and re-run `step firewall` + `step proxy`
  so only Cloudflare can reach the origin and real client IPs are restored.

## Disk / logs / backups

- `docker system df`, `docker system prune -f` (images only; volumes kept).
- Container logs are capped by `daemon.json` (10m × 3) and journald to 500M.
- Backups: `systemctl list-timers vps-backup.timer`, `journalctl -u vps-backup`,
  run now with `vps-backup`. Local copies in `/var/backups/vps-wizard/<stamp>/`
  (db dumps, volume tarballs, env, compose). Offsite via restic when
  `RESTIC_REPOSITORY` is set in `/etc/vps-wizard/backup.env`.

## Re-converging

Every step is idempotent. After manual changes, `vps-wizard apply --yes`
(uses `/etc/vps-wizard/wizard.conf`) restores the intended state; or
target one area with `vps-wizard step <name> --yes`.
