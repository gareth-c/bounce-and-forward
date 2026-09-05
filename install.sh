#!/usr/bin/env bash
# One-time provisioning script for a fresh Ubuntu server (EC2 or otherwise).
# Prompts interactively for anything not already given via env var — run it
# bare and it'll ask; pre-set the env vars (e.g. in CI) and it runs
# unattended with no prompts at all. Either way it needs root:
#
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/you/bounce-and-forward/main/install.sh)"
#
# (That "bash -c "$(curl ...)"" form — not "curl | bash" — matters: it's
# what lets the interactive prompts below actually reach your terminal
# instead of trying to read the piped script bytes as input.)
#
# What it does:
#   - installs Node.js 22.x (via NodeSource)
#   - creates a dedicated, non-root service user
#   - clones the repo to /opt/bounce-and-forward
#   - installs production dependencies
#   - installs the systemd unit (grants CAP_NET_BIND_SERVICE so the service
#     user can bind port 25 without running as root)
#   - if given a domain: installs Caddy and configures it as a
#     TLS-terminating reverse proxy in front of the web UI, with automatic
#     Let's Encrypt issuance/renewal (see README's "TLS for the web UI"
#     section). Requires that domain's DNS to already point at this
#     instance's public IP before Caddy can obtain a certificate for it.
#     Leave it blank to skip this and stay on plain HTTP.
#
# It does NOT start the bounce-and-forward service — you still need to
# fill in .env (SMTP_PORT, ALLOWED_RECIPIENTS, WEB_USERNAME,
# WEB_PASSWORD_HASH, SESSION_SECRET) before running:
#   sudo systemctl enable --now bounce-and-forward
#
# Env vars (all optional — you're prompted for anything left unset, when
# running interactively): REPO_URL, CADDY_DOMAIN, NONINTERACTIVE=1 to force
# non-interactive mode even on a real terminal (fails fast on missing
# required values instead of prompting).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo/root (it installs packages and a systemd unit)." >&2
  exit 1
fi

# Only prompt when there's an actual terminal to prompt on — never hang a
# CI run or a "curl | bash" (as opposed to "bash -c \"\$(curl ...)\"")
# invocation waiting on input that will never arrive. Reads come from
# /dev/tty rather than stdin so this also works even when stdin itself is
# occupied by a piped script.
INTERACTIVE=true
if [ -n "${NONINTERACTIVE:-}" ] || [ ! -e /dev/tty ] || ! { exec 3</dev/tty; } 2>/dev/null; then
  INTERACTIVE=false
fi

# ask PROMPT VARNAME — sets VARNAME from its existing env value if already
# set, otherwise prompts for it (when interactive), otherwise leaves it
# unset for the caller to handle.
ask() {
  local __prompt="$1" __var="$2" __reply
  if [ -n "${!__var:-}" ]; then
    return
  fi
  if [ "$INTERACTIVE" != true ]; then
    return
  fi
  read -r -p "$__prompt" __reply <&3
  printf -v "$__var" '%s' "$__reply"
}

echo "==> Bounce & Forward — installer"
echo

ask "Git repo URL to deploy (e.g. https://github.com/you/bounce-and-forward.git): " REPO_URL
REPO_URL="${REPO_URL:-}"
if [ -z "$REPO_URL" ]; then
  echo "REPO_URL is required. Either run this on a real terminal so it can ask, or set it:" >&2
  echo "  sudo REPO_URL=https://github.com/you/bounce-and-forward.git bash install.sh" >&2
  exit 1
fi

ask "Domain for TLS via Caddy, e.g. mail.yourdomain.com (leave blank to skip): " CADDY_DOMAIN
CADDY_DOMAIN="${CADDY_DOMAIN:-}"

if [ "$INTERACTIVE" = true ]; then
  echo
  echo "About to set up Bounce & Forward on this host:"
  echo "  Repo:   $REPO_URL"
  echo "  Domain: ${CADDY_DOMAIN:-(none — plain HTTP on WEB_PORT)}"
  echo "This installs Node.js${CADDY_DOMAIN:+, Caddy,} and a systemd service, as root."
  read -r -p "Press ENTER to continue, or Ctrl+C to abort... " _ <&3
  echo
fi

INSTALL_DIR="/opt/bounce-and-forward"
SERVICE_USER="bounceforward"

echo "==> Installing Node.js 22.x"
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
node --version

echo "==> Creating service user '$SERVICE_USER'"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

echo "==> Fetching repo into $INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

echo "==> Installing production dependencies"
sudo -u "$SERVICE_USER" bash -c "cd '$INSTALL_DIR' && npm ci --omit=dev"

if [ ! -f "$INSTALL_DIR/.env" ]; then
  cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
  chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
  echo "==> Created $INSTALL_DIR/.env from .env.example — edit it before starting the service."
fi

echo "==> Installing systemd unit"
cp "$INSTALL_DIR/deploy/bounce-and-forward.service" /etc/systemd/system/bounce-and-forward.service
systemctl daemon-reload

if [ -n "$CADDY_DOMAIN" ]; then
  echo "==> Installing Caddy (TLS reverse proxy for the web UI)"
  if ! command -v caddy >/dev/null 2>&1; then
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
  fi

  if [ ! -f /etc/caddy/Caddyfile ] || ! grep -q "$CADDY_DOMAIN" /etc/caddy/Caddyfile; then
    sed "s/mail.yourdomain.com/$CADDY_DOMAIN/" "$INSTALL_DIR/deploy/Caddyfile" > /etc/caddy/Caddyfile
    echo "==> Wrote /etc/caddy/Caddyfile for $CADDY_DOMAIN"
  fi
  systemctl enable caddy
  systemctl restart caddy
fi

cat <<EOF

Setup complete. Before starting the service:

  1. Edit $INSTALL_DIR/.env — set SMTP_PORT=25, ALLOWED_RECIPIENTS,
     WEB_USERNAME, SESSION_SECRET (openssl rand -hex 32), and
     WEB_PASSWORD_HASH (generate with:
       sudo -u $SERVICE_USER bash -c "cd $INSTALL_DIR && npm run hash-password -- 'your-password'"
     )
EOF

if [ -n "$CADDY_DOMAIN" ]; then
  cat <<EOF
     Since Caddy is fronting the web UI, also set:
       WEB_SECURE_COOKIES=true
       WEB_TRUST_PROXY=true
  2. Open ports 25, 80, and 443 in your firewall/security group (80+443 for
     Caddy/Let's Encrypt; 25 for inbound mail). WEB_PORT (8080) does not
     need to be open at all now — the app listens on 127.0.0.1 only and is
     reached solely through Caddy at https://$CADDY_DOMAIN.
EOF
else
  cat <<EOF
  2. Open port 25 (and your chosen WEB_PORT, restricted to your own IP) in
     your firewall/security group. No domain was given, so the web UI is
     plain HTTP — see the README's "TLS for the web UI" section if you want
     that added later.
EOF
fi

cat <<EOF
  3. Start it:
       systemctl enable --now bounce-and-forward
       systemctl status bounce-and-forward
       journalctl -u bounce-and-forward -f

To redeploy after pushing new commits, run deploy/deploy.sh (see README).
EOF
