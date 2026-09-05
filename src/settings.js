const { db } = require('./db');
const { config } = require('./config');

const getStmt = db.prepare(`SELECT quota_bytes, retention_days FROM settings WHERE id = 1`);
const insertStmt = db.prepare(
  `INSERT OR IGNORE INTO settings (id, quota_bytes, retention_days) VALUES (1, ?, ?)`
);
const updateStmt = db.prepare(
  `UPDATE settings SET quota_bytes = ?, retention_days = ? WHERE id = 1`
);

// Seed from env on first run only (same pattern as ALLOWED_RECIPIENTS) — after
// that the row in the database is the source of truth and the web UI is how
// you change it.
insertStmt.run(config.storage.quotaBytes, config.storage.retentionDays);

function getSettings() {
  const row = getStmt.get();
  return { quotaBytes: row.quota_bytes, retentionDays: row.retention_days };
}

// quotaBytes: minimum 10 MB (a lower cap makes the app nearly unusable and
// is almost certainly a typo). retentionDays: 0 or more (0 means "prune
// everything not already deleted by the next sweep" — a deliberate choice
// we allow, not a default).
function updateSettings({ quotaBytes, retentionDays }) {
  const q = Number(quotaBytes);
  const r = Number(retentionDays);
  if (!Number.isFinite(q) || q < 10 * 1024 * 1024) {
    return { error: 'Storage quota must be at least 10 MB.' };
  }
  if (!Number.isInteger(r) || r < 0) {
    return { error: 'Retention days must be a whole number, 0 or greater.' };
  }
  updateStmt.run(q, r);
  return { error: null };
}

module.exports = { getSettings, updateSettings };
