# AGENTS.md

Guidance for AI agents working **on this repository** (contributing code).
For driving the tool against a real server, use the skills in
[`.claude/skills/`](.claude/skills) instead.

## What this repo is

A pure-Bash CLI (`bin/vps-wizard`) that provisions a Debian/Ubuntu VPS and
deploys Docker Compose apps behind a TLS proxy. No runtime dependencies
beyond bash 4+, coreutils and the packages it installs itself. It must keep
working on a freshly booted VPS with nothing installed.

## Ground rules

1. **Every mutation goes through `run`, `run_sh`, `write_file` or `run_try`**
   (`lib/core.sh`). They handle dry-run, logging, atomic writes and backups.
   Never call `apt-get`, `systemctl`, `ufw`, `docker`, `mv`, `rm` directly in
   a step - `vps-wizard plan` would then lie about what it does.
2. **Idempotence is a hard requirement.** Running any step twice must not
   change the result or fail. Use marked blocks in shared files (see
   `ufw_install_block`), `write_file` (skips unchanged content), and check
   before creating users, networks, keys.
3. **Never risk a lock-out.** Anything touching SSH or the firewall must
   either verify access first or arm the rollback (`safety_arm`). The
   validator in `lib/validate.sh` refuses configurations that would remove
   the last way in.
4. **Only the proxy publishes ports.** Do not add `ports:` bindings on
   `0.0.0.0` to any generated compose file except the proxy's 80/443.
5. **No secrets in output.** Redact auth keys in dry-run output (see the
   Tailscale step), keep `.env` at mode 600, mask secret-looking values in
   `vps-wizard env <app> list`.
6. `set -e` is deliberately **off** in `bin/vps-wizard`; `run` aborts on
   failure via `die`. Don't add `set -e` - it breaks interactive prompts and
   probing commands.

## Adding a step

Create `steps/NN-name.sh` (filename order = execution order) with:

```bash
register_step name "Title" "short subtitle"
step_name_config()  { defcfg KEY default "description shown in config dumps"; }
step_name_enabled() { cfg_bool KEY_ENABLE; }          # is this step active?
step_name_prompt()  { ask "Question" "$KEY"; KEY="$REPLY"; }
step_name_plan()    { ui_bullet "what apply would do"; return 0; }
step_name_apply()   { run something; step_mark_done name; }
step_name_status()  { ui_kv "Label" "current value"; return 0; }
```

All six functions must exist. `prompt` must work when `NONINTERACTIVE=true`
(the `ask*` helpers already fall back to defaults). `plan` and `status` must
never mutate anything and must return 0.

Add config keys to `examples/wizard.conf.example` and mention user-visible
behaviour in `README.md` and the relevant skill.

## Templates

`templates/*` are rendered by `render_template` with `{{VAR}}` substitution
from exported shell variables. Missing variables render empty - export
everything the template needs in the step before calling it. Keep templates
valid for their target parser (YAML, Caddyfile, sshd_config, iptables-restore).

## Testing

```bash
bash tests/run.sh                    # unit + CLI dry-run assertions, no root needed
shellcheck -x -S warning bin/vps-wizard install.sh lib/*.sh steps/*.sh templates/backup.sh templates/app-deploy.sh tests/run.sh
bash tests/render-proxy-configs.sh /tmp/out          # render caddy configs
PROXY_TYPE=traefik bash tests/render-proxy-configs.sh /tmp/out2
```

CI (`.github/workflows/ci.yml`) additionally validates the rendered
Caddyfile with the real `caddy` image, parses the Traefik YAML, and runs
`docker compose config` on generated compose files. Add assertions to
`tests/run.sh` for any new parsing, validation or rendering logic.

Sandbox everything with `WIZARD_ETC`, `WIZARD_APPS_DIR`, `WIZARD_PROXY_DIR`,
`WIZARD_LOG_DIR` and `WIZARD_PUBLIC_IP` - tests must never touch the real
system.

## Style

- 2-space indent, `local` for every function variable, lower_snake_case
  functions, UPPER_SNAKE_CASE config keys.
- User-facing output only through the `ui_*` helpers so `NO_COLOR`, non-TTY
  and `--ascii` keep working.
- Comment *why*, not *what*, and especially why a security default is what it
  is - the config file is documentation users read.
