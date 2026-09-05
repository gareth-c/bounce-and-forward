#!/usr/bin/env bash
# One-time provisioning script for a fresh Ubuntu EC2 instance.
# Run as: sudo REPO_URL=https://github.com/you/bounce-and-forward.git bash deploy/setup-ec2.sh
#
# What it does:
#   - installs Node.js 22.x (via NodeSource)
#   - creates a dedicated, non-root service user
#   - clones the repo to /opt/bounce-and-forward
#   - installs production dependencies
#   - installs the systemd unit (grants CAP_NET_BIND_SERVICE so the service
#     user can bind port 25 without running as root)
#   - if CADDY_DOMAIN is set: installs Caddy and configures it as a
#     TLS-terminating reverse proxy in front of the web UI, with automatic
#     Let's Encrypt issuance/renewal (see README's "TLS for the web UI"
#     section). Requires that domain's DNS to already point at this
#     instance's public IP before Caddy can obtain a certificate for it.
#     Omit CADDY_DOMAIN to skip this and leave the web UI on plain HTTP.
#
# It does NOT start the bounce-and-forward service — you still need to
# create and fill in .env (copy from .env.example, set ALLOWED_RECIPIENTS /
# WEB_USERNAME / WEB_PASSWORD_HASH / SESSION_SECRET) before running:
#   sudo systemctl enable --now bounce-and-forward

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo/root (it installs packages and a systemd unit)." >&2
  exit 1
fi

REPO_URL="${REPO_URL:-}"
if [ -z "$REPO_URL" ]; then
  echo "Set REPO_URL to your git repo, e.g.:" >&2
  echo "  sudo REPO_URL=https://github.com/you/bounce-and-forward.git bash deploy/setup-ec2.sh" >&2
  exit 1
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

CADDY_DOMAIN="${CADDY_DOMAIN:-}"
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
  2. Open ports 25, 80, and 443 in the EC2 security group (80+443 for
     Caddy/Let's Encrypt; 25 for inbound mail). WEB_PORT (8080) does not
     need to be open at all now — the app listens on 127.0.0.1 only and is
     reached solely through Caddy at https://$CADDY_DOMAIN.
EOF
else
  cat <<EOF
  2. Open port 25 (and your chosen WEB_PORT, restricted to your own IP) in
     the EC2 security group. No CADDY_DOMAIN was given, so the web UI is
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
