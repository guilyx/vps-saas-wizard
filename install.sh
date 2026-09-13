#!/usr/bin/env bash
# vps-saas-wizard installer
#   curl -fsSL https://raw.githubusercontent.com/guilyx/vps-saas-wizard/main/install.sh | sudo bash
#   curl -fsSL .../install.sh | sudo bash -s -- --run      # install then start the wizard
# Installs to /opt/vps-wizard and symlinks /usr/local/bin/vps-wizard.
set -euo pipefail

REPO="${VPS_WIZARD_REPO:-https://github.com/guilyx/vps-saas-wizard.git}"
REF="${VPS_WIZARD_REF:-main}"
DEST="${VPS_WIZARD_HOME:-/opt/vps-wizard}"
RUN=false
for a in "$@"; do case "$a" in --run) RUN=true ;; esac; done

if [[ "$(id -u)" != 0 ]]; then
  echo "Please run as root: curl -fsSL ... | sudo bash" >&2; exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q git ca-certificates curl >/dev/null
  else
    echo "git is required" >&2; exit 1
  fi
fi

if [[ -d "$DEST/.git" ]]; then
  echo "» updating $DEST"
  git -C "$DEST" fetch -q origin "$REF"
  git -C "$DEST" checkout -q -B "$REF" "origin/$REF"
else
  echo "» cloning $REPO ($REF) to $DEST"
  rm -rf "$DEST"
  git clone -q --depth 1 --branch "$REF" "$REPO" "$DEST"
fi
chmod +x "$DEST/bin/vps-wizard"
ln -sfn "$DEST/bin/vps-wizard" /usr/local/bin/vps-wizard
echo "» installed: $(vps-wizard --version) -> /usr/local/bin/vps-wizard"
echo
echo "  Start the guided setup:   sudo vps-wizard"
echo "  Non-interactive:          sudo vps-wizard init && sudo vps-wizard apply --yes"
echo "  Agent skills:             $DEST/.claude/skills/"
echo
if [[ "$RUN" == true ]]; then
  exec vps-wizard </dev/tty
fi
