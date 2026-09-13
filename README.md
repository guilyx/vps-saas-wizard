# vps-saas-wizard

A guided, good-looking terminal wizard that turns a **bare Debian/Ubuntu VPS
into a production host** and deploys your **Docker Compose SaaS** on it with
the boring best practices already done: non-root deploy user, key-only
hardened SSH, docker-aware firewall, kernel anti-DDoS tuning, fail2ban,
automatic TLS behind Caddy (or Traefik), optional Tailscale for admin access,
nightly backups. Zero dependencies (pure Bash), idempotent, and fully
scriptable so **AI agents can drive it** (skills included).

```
curl -fsSL https://raw.githubusercontent.com/guilyx/vps-saas-wizard/main/install.sh | sudo bash
sudo vps-wizard
```

```
   Step 4/12  Firewall  ufw default-deny · docker-aware · rate-limited SSH
──────────────────────────────────────────────────────────────────────────
  ? Configure the firewall (ufw)? [Y/n]:
  ? Rate-limit SSH connections (blocks brute force bursts)? [Y/n]:
  ? Extra public TCP ports (comma separated, usually none):
  ? Restrict HTTP/HTTPS to Cloudflare IP ranges only? [y/N]:
```

## What you get

| Step | What it does |
|------|--------------|
| **Preflight** | OS/arch/RAM/disk checks, connectivity, base packages. Nothing changed until you confirm the plan. |
| **System** | `apt full-upgrade`, hostname, timezone + NTP, swap file, **unattended security upgrades**, bounded journald. |
| **Deploy user & SSH** | Non-root sudo user with your keys, `sshd` drop-in: key-only, no root, modern ciphers, `AllowUsers`, custom port. **Lock-out safety net**: changes auto-revert after 15 min unless you run `vps-wizard confirm`. |
| **Firewall** | UFW default-deny, SSH rate-limited, 80/443 only (optionally **Cloudflare ranges only**, refreshed weekly). **Docker made to respect UFW** via the `DOCKER-USER` chain. |
| **Anti-DDoS & hardening** | sysctl: SYN cookies, rp_filter, no redirects/source routing, conntrack sizing, BBR, kernel restrictions. iptables **per-IP connection + new-connection rate limits** on 80/443, bogus-flag drops. |
| **fail2ban** | `sshd` (aggressive) + `recidive` with escalating bans; **HTTP flood jail** on the proxy's JSON access log; bans also cover Docker-published ports. |
| **Docker** | Docker CE + Compose plugin from Docker's repo, `daemon.json` with log rotation, live-restore, no userland proxy, `no-new-privileges`; shared `proxy` network. |
| **Tailscale** | Join your tailnet (auth key or login URL), Tailscale SSH, and optionally **close the public SSH port** (rollback armed, verified over the tailnet first). |
| **Reverse proxy & TLS** | **Caddy** (default) or **Traefik v3**: Let's Encrypt, HTTP/3, HSTS + security headers, compression, body limits, probe blocking, JSON access logs, Cloudflare real-IP. Unknown hosts get 404, not your first site. |
| **Application** | Clone from git (https or `git@` with a generated deploy key), build `.env` from `.env.example` with **auto-generated secrets**, compose overlay onto the `proxy` network, TLS site, build + up, wait for healthy, DNS + HTTPS verification. Ships a `deploy.sh` for zero-touch redeploys. |
| **Backups** | Nightly systemd timer: auto-detected Postgres/MySQL dumps, volume tarballs, env + compose, proxy certs; retention; optional **restic offsite** (S3/B2/SFTP). |
| **Ops tools** | Optional Dozzle (logs) + Uptime Kuma (monitoring) bound to your Tailscale IP / localhost only. |

At the end you get a summary box, a markdown report at
`/etc/vps-wizard/report.md`, and your answers saved to
`/etc/vps-wizard/wizard.conf` so the whole thing is reproducible.

## Usage

```bash
sudo vps-wizard                     # interactive wizard (asks everything, shows a plan, applies)
sudo vps-wizard init -o wizard.conf # answer questions, write a config, change nothing
sudo vps-wizard plan -c wizard.conf # dry run: prints every command and file it would write
sudo vps-wizard apply -c wizard.conf --yes      # non-interactive apply (CI / agents)
sudo vps-wizard step firewall       # (re)run a single step
sudo vps-wizard status              # what's configured
sudo vps-wizard doctor              # health checks: ufw, docker, ssh, tls, dns, disk, backups
sudo vps-wizard confirm             # "I can still log in" - cancel the SSH rollback timer

sudo vps-wizard app add --name shop --source git@github.com:org/shop.git --domain shop.example.com
sudo vps-wizard app deploy shop     # git pull + build + up + wait healthy  (call this from CI)
sudo vps-wizard app logs shop
sudo vps-wizard env shop set SMTP_HOST=smtp.example.com
```

Run `vps-wizard --help` for everything. All config keys with descriptions:
[`examples/wizard.conf.example`](examples/wizard.conf.example) or
`vps-wizard config`.

## Design principles

- **Never lock you out.** Password auth is only disabled when a key is
  verified; the SSH port is only closed when Tailscale is up; both arm a
  timer that reverts unless you confirm from a fresh session.
- **Only the proxy is public.** Apps live on an internal docker network; Docker
  cannot punch holes in the firewall behind your back.
- **Idempotent.** Re-run any step, any time. Files are written atomically with
  backups; blocks in shared files (`ufw` rules) are marked and replaced.
- **Plan before apply.** `plan` shows exactly what will happen, without root.
- **No magic.** Everything is plain files you can read: compose files,
  a `Caddyfile`, sysctl and ufw rules under `/opt/proxy`, `/opt/apps`, `/etc/*`.

## For AI agents

The repo ships Claude Code skills in [`.claude/skills/`](.claude/skills):

- `vps-saas-wizard` - provision + harden a host non-interactively (config, plan, apply, confirm, verify)
- `vps-deploy-app` - add / redeploy / debug apps and manage their `.env`
- `vps-doctor` - diagnose a broken host (TLS, 502, bans, lock-outs, disk)

Everything an agent needs is exposed as commands with stable exit codes and
plain-text output: `plan`, `apply --yes`, `doctor`, `status`, `config KEY`,
`app ...`, `env ...`. See also [`AGENTS.md`](AGENTS.md).

## Layout

```
bin/vps-wizard        CLI entrypoint (commands, plan/apply loop, app/env subcommands)
lib/                  core (run/dry-run/config/state), ui (TUI), validate, detect
steps/NN-name.sh      one file per step: config keys, prompts, plan, apply, status
templates/            sysctl, sshd, ufw blocks, fail2ban, daemon.json, Caddy/Traefik, backup, systemd units
examples/             annotated config, GitHub Actions deploy workflow
tests/                unit + dry-run tests (bash tests/run.sh), config renderers used by CI
.claude/skills/       agent skills
```

## Requirements

Debian 11/12/13 or Ubuntu 20.04–24.04+ (other systemd distros may work),
root, outbound HTTPS. Tested on x86_64 and aarch64 images.

## Development

```bash
bash tests/run.sh                          # ~100 assertions, no root/docker needed
shellcheck -x bin/vps-wizard lib/*.sh steps/*.sh
vps-wizard plan -c examples/wizard.conf.example   # full dry run
```

Adding a step: create `steps/NN-name.sh`, call `register_step name "Title" "subtitle"`
and define `step_name_config|prompt|enabled|plan|apply|status`. It is picked up
automatically in filename order.

## License

MIT
