const session = require('express-session');
const { db } = require('../db');

const DEFAULT_MAX_AGE_MS = 12 * 60 * 60 * 1000;

// Sessions in the default express-session MemoryStore don't survive a
// restart and can't be shared across instances. This app only ever runs as
// a single instance, but it's redeployed often (see deploy/deploy.sh, which
// restarts the systemd service on every push) — persisting sessions in the
// same SQLite file we already use means an admin redeploy doesn't force a
// re-login.
class SqliteSessionStore extends session.Store {
  constructor() {
    super();
    this.getStmt = db.prepare(`SELECT data, expires_at FROM sessions WHERE sid = ?`);
    this.upsertStmt = db.prepare(
      `INSERT INTO sessions (sid, data, expires_at) VALUES (?, ?, ?)
       ON CONFLICT(sid) DO UPDATE SET data = excluded.data, expires_at = excluded.expires_at`
    );
    this.destroyStmt = db.prepare(`DELETE FROM sessions WHERE sid = ?`);
    this.pruneStmt = db.prepare(`DELETE FROM sessions WHERE expires_at < ?`);

    this.pruneStmt.run(Date.now());
    const interval = setInterval(() => this.pruneStmt.run(Date.now()), 60 * 60 * 1000);
    interval.unref();
  }

  get(sid, cb) {
    try {
      const row = this.getStmt.get(sid);
      if (!row) return cb(null, null);
      if (row.expires_at < Date.now()) {
        this.destroyStmt.run(sid);
        return cb(null, null);
      }
      cb(null, JSON.parse(row.data));
    } catch (err) {
      cb(err);
    }
  }

  set(sid, sessionData, cb) {
    try {
      const maxAge =
        sessionData.cookie && Number.isFinite(sessionData.cookie.maxAge)
          ? sessionData.cookie.maxAge
          : DEFAULT_MAX_AGE_MS;
      this.upsertStmt.run(sid, JSON.stringify(sessionData), Date.now() + maxAge);
      cb && cb(null);
    } catch (err) {
      cb && cb(err);
    }
  }

  destroy(sid, cb) {
    try {
      this.destroyStmt.run(sid);
      cb && cb(null);
    } catch (err) {
      cb && cb(err);
    }
  }

  touch(sid, sessionData, cb) {
    this.set(sid, sessionData, cb);
  }
}

module.exports = { SqliteSessionStore };
