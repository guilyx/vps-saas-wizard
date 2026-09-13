#!/usr/bin/env bash
# Step: docker - Docker Engine + Compose plugin from Docker's repo, sane daemon.json.
register_step docker "Docker" "engine + compose plugin · log rotation · live-restore"

step_docker_config() {
  defcfg DOCKER_INSTALL true "Install Docker Engine and the Compose plugin"
  defcfg DOCKER_LOG_MAX_SIZE "10m" "Default json-file log size per container file"
  defcfg DOCKER_LOG_MAX_FILE "3" "Default number of rotated log files per container"
}

step_docker_enabled() { cfg_bool DOCKER_INSTALL; }

step_docker_prompt() {
  if have docker; then
    ui_info "Docker $(docker --version 2>/dev/null | sed -E 's/.*version ([0-9.]+).*/\1/') is already installed; the wizard will only tune daemon.json."
  fi
  ask_yn "Install/configure Docker?" "$DOCKER_INSTALL" && DOCKER_INSTALL=true || DOCKER_INSTALL=false
}

step_docker_plan() {
  have docker || ui_bullet "Install docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin from download.docker.com"
  ui_bullet "daemon.json: log rotation ${DOCKER_LOG_MAX_SIZE}x${DOCKER_LOG_MAX_FILE}, live-restore, no userland-proxy, no-new-privileges"
  ui_bullet "Create shared 'proxy' docker network; add $DEPLOY_USER to docker group"
  return 0
}

step_docker_apply() {
  if ! have docker; then
    apt_update_once
    apt_install ca-certificates curl gnupg
    run install -m 0755 -d /etc/apt/keyrings
    run_sh "curl -fsSL https://download.docker.com/linux/$OS_ID/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg"
    run chmod a+r /etc/apt/keyrings/docker.gpg
    local deb_arch; deb_arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    write_file /etc/apt/sources.list.d/docker.list 0644 <<<"deb [arch=$deb_arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -q
    ui_spin "Installing Docker Engine" env DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    ui_ok "Docker already installed"
    if ! docker compose version >/dev/null 2>&1; then
      apt_update_once
      run_try env DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-compose-plugin \
        || ui_warn "Could not install docker-compose-plugin from apt; install the compose plugin manually."
    fi
  fi
  export DOCKER_LOG_MAX_SIZE DOCKER_LOG_MAX_FILE
  local changed=false
  if ! [[ -f /etc/docker/daemon.json ]] || ! diff -q <(render_template docker-daemon.json) /etc/docker/daemon.json >/dev/null 2>&1; then changed=true; fi
  render_template docker-daemon.json | write_file /etc/docker/daemon.json 0644
  run systemctl enable docker
  if [[ "$changed" == true ]]; then run systemctl restart docker; else run systemctl start docker; fi
  getent group docker >/dev/null 2>&1 && id "$DEPLOY_USER" >/dev/null 2>&1 && run usermod -aG docker "$DEPLOY_USER"
  if [[ "$DRY_RUN" == true ]] || ! docker network inspect proxy >/dev/null 2>&1; then
    run docker network create --driver bridge --opt com.docker.network.bridge.name=br-proxy proxy
  fi
  # Docker (re)installs its iptables chains: make sure ufw's DOCKER-USER hook is live.
  if have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then run ufw reload; fi
  ui_ok "Docker ready ($(docker --version 2>/dev/null | sed -E 's/.*version ([0-9.]+).*/\1/' || echo 'dry-run'))"
  step_mark_done docker
}

step_docker_status() {
  if have docker; then
    ui_kv "Docker" "$(docker --version 2>/dev/null | sed -E 's/Docker version //') / $(service_active docker && echo active || echo inactive)"
    ui_kv "Compose" "$(docker compose version --short 2>/dev/null || echo missing)"
    ui_kv "Containers" "$(docker ps --format '{{.Names}} ({{.Status}})' 2>/dev/null | tr '\n' ';' | sed 's/;$//;s/;/, /g')"
    ui_kv "proxy network" "$(docker network inspect proxy >/dev/null 2>&1 && echo present || echo missing)"
  else
    ui_kv "Docker" "not installed"
  fi
}
