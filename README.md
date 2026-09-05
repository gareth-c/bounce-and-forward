# Bounce & Forward

An SMTP daemon that listens for mail on port 25 for a configured list of
users/domains, **captures the full message**, then rejects it with a
permanent SMTP error — so the sender's mail server generates a real bounce
back to them, while you keep a copy. Captured mail is browsable in a
password-protected web UI.

## How the bounce works

The daemon accepts `MAIL FROM` / `RCPT TO` for configured addresses, reads
the entire message during `DATA`, and only *then* responds to the final `.`
with a 5xx error instead of `250 OK`. Two things fall out of that:

- The sender's own MTA is the one that generates the bounce message to their
  user — this server never originates outbound mail. That means it works
  fine even on hosts (like AWS EC2) that block or throttle *outbound* port
  25, since no outbound SMTP connection is ever made.
- Rejecting inline (rather than accepting and bouncing asynchronously later)
  avoids "backscatter" — you never send a bounce to a third party whose
  address was forged as the sender.

Addresses/domains not in the accepted list are rejected immediately at
`RCPT TO` with a normal 550, before any message is captured — nothing is
stored for them.

## Managing accepted addresses/domains

The list of addresses/domains to capture mail for lives in the database, not
just `.env`, and is managed at **/recipients** in the web UI — add a full
address (`alice@example.com`) or a bare domain (`example.com`, meaning
"every address at this domain") and remove them, with no restart or
redeploy needed; changes apply to the very next SMTP connection.

`ALLOWED_RECIPIENTS` in `.env` is only used to seed that list the first time
the server ever starts (so existing single-`.env` deployments keep working
unchanged) — after that it's ignored, and the web UI is the source of
truth.

## Managing storage (quota & retention)

Captured mail is bounded by a storage quota (default 5 GB) and a retention
window (default 365 days), both editable live at **/settings** — same
seed-from-`.env`-once-then-database-is-source-of-truth pattern as
`ALLOWED_RECIPIENTS` above, via `STORAGE_QUOTA_GB` / `RETENTION_DAYS`.

Enforcement runs after every captured message, plus an hourly sweep so
retention still applies even with no new mail arriving: anything past the
retention window is deleted regardless of quota, and if still over quota,
the oldest remaining messages are deleted until back under it.

## Local development

```bash
npm install
cp .env.example .env
npm run hash-password -- 'your-password' # paste result into WEB_PASSWORD_HASH in .env
```

Edit `.env`: set `ALLOWED_RECIPIENTS`, `WEB_USERNAME`, `SESSION_SECRET`
(`openssl rand -hex 32`). Leave `SMTP_PORT=2525` locally — port 25 needs
root/elevated capabilities (see below).

```bash
npm start
```

Then send a test message, e.g.:

```bash
python3 -c "
import smtplib
smtplib.SMTP('127.0.0.1', 2525).sendmail(
    'sender@example.com', ['alice@example.com'], 'Subject: test\n\nhi'
)
"
```

It should fail with a `550` from Python (that's the bounce working), and the
message should appear in the web UI at http://127.0.0.1:8080.

## Deploying to AWS EC2

Port 25 needs a real host with an unrestricted public IP and listening
socket — this won't run on PaaS platforms like Railway/Render/Heroku, which
don't expose raw port 25 to the internet.

### One-time setup

1. Launch an Ubuntu EC2 instance with an Elastic IP. This workload is tiny
   (an idle Node process plus occasional mail parsing) — a Graviton instance
   like `t4g.micro` is the cheapest sensible choice and works with zero
   changes here: none of this project's dependencies need native compilation
   (no `better-sqlite3`, no native `bcrypt` — see `package.json`), so there's
   none of the "no prebuilt ARM binary" friction that trips up a lot of Node
   projects on arm64.
2. Security group: allow inbound TCP 25 from `0.0.0.0/0`; allow SSH (22)
   from your IP. For the web UI: if you're setting up TLS via Caddy (step 5
   below), open 80 and 443 instead — `WEB_PORT` itself never needs to be
   open to the world, since Caddy is what's actually internet-facing and it
   talks to the app over `127.0.0.1`. If skipping Caddy, open `WEB_PORT`
   only to your own IP/VPN instead (not the world) — the web UI has its own
   auth, but don't expose an unencrypted admin panel needlessly.
3. AWS blocks *outbound* port 25 by default on EC2 — irrelevant here since
   this daemon never sends outbound mail (see "How the bounce works" above),
   so you do **not** need to file the EC2 email-sending-limit removal
   request for this use case.
4. Optional but recommended: request a PTR (reverse DNS) record for your
   Elastic IP via an AWS Support case ("EC2 reverse DNS request"), and point
   an MX record for your domain(s) at the instance.
5. If you want TLS on the web UI (recommended — see "TLS for the web UI"
   below for how this works), point an A record for your chosen subdomain
   (e.g. `mail.yourdomain.com`) at the instance's Elastic IP now, so it's
   already resolving by the time Caddy tries to get a certificate for it.

6. SSH in and run `install.sh` as root. It's interactive — run it bare and
   it asks for anything it needs:

   ```bash
   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/you/bounce-and-forward/main/install.sh)"
   ```

   It'll prompt for your repo URL, then a domain for TLS via Caddy (leave
   blank to skip that — see "TLS for the web UI" below), show a summary, and
   wait for you to press Enter before touching the system. Prefer to review
   it first, or automate it (CI, no prompts)? Same script, no prompting when
   the values are already given as env vars:

   ```bash
   git clone https://github.com/you/bounce-and-forward.git /tmp/baf-setup
   less /tmp/baf-setup/install.sh
   sudo REPO_URL=https://github.com/you/bounce-and-forward.git \
     CADDY_DOMAIN=mail.yourdomain.com \
     bash /tmp/baf-setup/install.sh
   ```

   Either way it installs Node.js, creates a `bounceforward` service user,
   clones the repo to `/opt/bounce-and-forward`, installs dependencies, and
   installs the systemd unit — but does **not** start the service yet.
   (`install.sh` itself pipes NodeSource's official install script through
   `bash` to add the Node.js apt repository — the standard way to install
   it, but still worth knowing it's root-executing a remote script; review
   https://github.com/nodesource/distributions if you want to avoid that. It
   does the same thing for Caddy's official apt repository if you gave it a
   domain — review https://caddyserver.com/docs/install if you want to avoid
   that too.)

7. Fill in `/opt/bounce-and-forward/.env` (set `SMTP_PORT=25`,
   `ALLOWED_RECIPIENTS`, `WEB_USERNAME`, `SESSION_SECRET`, and
   `WEB_PASSWORD_HASH` — the setup script prints the exact command to
   generate the hash; if you set `CADDY_DOMAIN`, also set
   `WEB_SECURE_COOKIES=true` and `WEB_TRUST_PROXY=true` as the script's
   final output will remind you).
8. Start it:

   ```bash
   sudo systemctl enable --now bounce-and-forward
   sudo systemctl status bounce-and-forward
   sudo journalctl -u bounce-and-forward -f
   ```

The systemd unit runs the service as the unprivileged `bounceforward` user
and grants only `CAP_NET_BIND_SERVICE` (via `AmbientCapabilities`) so it can
bind port 25 without running as root.

### TLS for the web UI

By default the app serves the web UI as plain HTTP on `127.0.0.1:WEB_PORT` —
fine if you're only reaching it over SSH tunnel/VPN, not fine if you're
putting a login form on the open internet. `install.sh` can set up
[Caddy](https://caddyserver.com) as a reverse proxy in front of it, which
gets you automatic Let's Encrypt certificate issuance and renewal for free
(no `certbot`, no manual renewal cron, no code changes to the app).

How it fits together: Caddy binds the public IP on 80/443, terminates TLS,
and reverse-proxies plaintext to the app over `127.0.0.1:WEB_PORT`, which
never needs to be reachable from outside the box at all. Give `install.sh` a
domain (step 6 above, prompted or via `CADDY_DOMAIN=mail.yourdomain.com`)
and it installs Caddy from its official apt repo, writes
`/etc/caddy/Caddyfile` from [`deploy/Caddyfile`](deploy/Caddyfile) with your
domain substituted in, and starts it — the Caddyfile itself is just:

```
mail.yourdomain.com {
	reverse_proxy 127.0.0.1:8080
}
```

That domain's DNS must already point at the instance before Caddy starts
(step 5), since Let's Encrypt's HTTP-01 challenge validates ownership over
it. Once it's up, set `WEB_SECURE_COOKIES=true` and `WEB_TRUST_PROXY=true`
in `.env` — the app is now genuinely behind a real TLS-terminating proxy, so
both settings described in "Security notes" below should be on.

To add this to an instance that's already running without it: rerun
`install.sh` with a domain given (it's safe to rerun), or just do the same
install/Caddyfile/`WEB_*` steps by hand.

### Redeploying after code changes

```bash
ssh you@your-ec2-host 'sudo /opt/bounce-and-forward/deploy/deploy.sh main'
```

`deploy/deploy.sh` does a `git fetch` + hard reset to `origin/main`,
reinstalls production dependencies, and restarts the systemd service.
`.env` is untracked so it's left alone.

## Configuration reference

See [.env.example](.env.example) — every variable is documented inline.

## Security notes

- The web UI is single-user (one username/password from `.env`, bcrypt
  hashed). Put it behind a TLS-terminating reverse proxy (see "TLS for the
  web UI" above) if exposing it beyond a VPN, and set
  `WEB_SECURE_COOKIES=true` and `WEB_TRUST_PROXY=true` once it's actually
  behind that proxy — leave both false if Node is directly
  internet/VPN-facing, since trusting `X-Forwarded-*` headers with no real
  proxy in front lets a client spoof them.
- `/login` is rate-limited (10 attempts / 15 min per IP) to slow down
  password guessing; there's still no account lockout/alerting, so a weak
  password is still a weak password.
- State-changing admin actions (`/recipients`, `/settings`, `/logout`) are
  CSRF-protected with a per-session token minted at login and checked on
  every POST, independent of the cookie's `SameSite=Lax` attribute (which
  also helps, but isn't relied on as the only defense).
- A Content-Security-Policy is enabled (script-src limited to same-origin,
  no inline event handlers, no plugins/objects, no framing) as
  defense-in-depth against XSS, on top of EJS's default output-escaping.
- HTML email bodies are rendered in a sandboxed `<iframe>` (`sandbox=""`,
  scripts disabled) so a captured message can't execute JavaScript in the
  admin's browser.
- The SMTP side never performs `AUTH` and accepts any `MAIL FROM` — it's an
  inbound-only capture point, not a relay. It will not forward or relay mail
  anywhere. `MAIL FROM` is trivially spoofable by design in SMTP, so treat
  the "From"/envelope-sender shown in the UI as unverified.
- Captured storage is bounded by the quota/retention settings at
  **/settings** (see "Managing storage" above) — default 5 GB / 365 days,
  enforced automatically. There's no cap on message *rate*, though, so a
  fast enough flood could still fill disk faster than pruning keeps up if
  you set the quota too high for the instance's actual disk size.
- Sessions are stored in the same SQLite database as everything else (see
  `src/web/sqliteSessionStore.js`), not the `express-session` default
  in-memory store — a redeploy/restart doesn't force a re-login. This still
  assumes a single instance; it isn't a distributed session store.
