const crypto = require('node:crypto');
const { db } = require('./db');
const { config } = require('./config');

const insertStmt = db.prepare(
  `INSERT OR IGNORE INTO allowed_recipients (id, pattern, created_at) VALUES (?, ?, ?)`
);
const deleteStmt = db.prepare(`DELETE FROM allowed_recipients WHERE id = ?`);
const listStmt = db.prepare(`SELECT * FROM allowed_recipients ORDER BY pattern ASC`);
const matchStmt = db.prepare(
  `SELECT 1 FROM allowed_recipients WHERE pattern = ? OR pattern = ? LIMIT 1`
);
const countStmt = db.prepare(`SELECT COUNT(*) as c FROM allowed_recipients`);

// Seed from the ALLOWED_RECIPIENTS env var on first run only, so existing
// deployments keep working without edits. After that, the web UI (backed by
// this table) is the source of truth and the env var is ignored.
if (countStmt.get().c === 0) {
  for (const pattern of config.smtp.allowedRecipients) {
    insertStmt.run(crypto.randomUUID(), pattern, new Date().toISOString());
  }
}

// Accepts "alice@example.com", "example.com", or "@example.com". Bare
// domains are normalized to the "@example.com" form used for matching.
function normalizePattern(input) {
  const trimmed = (input || '').trim().toLowerCase();
  if (!trimmed) return null;
  if (trimmed.includes('@')) return trimmed;
  return `@${trimmed}`;
}

function listAllowedRecipients() {
  return listStmt.all();
}

function addAllowedRecipient(rawInput) {
  const pattern = normalizePattern(rawInput);
  if (!pattern) return null;
  insertStmt.run(crypto.randomUUID(), pattern, new Date().toISOString());
  return pattern;
}

function removeAllowedRecipient(id) {
  deleteStmt.run(id);
}

function isRecipientAllowed(address) {
  const normalized = (address || '').trim().toLowerCase();
  const atIndex = normalized.lastIndexOf('@');
  if (atIndex === -1) return false;
  const domainPattern = `@${normalized.slice(atIndex + 1)}`;
  return Boolean(matchStmt.get(normalized, domainPattern));
}

module.exports = {
  listAllowedRecipients,
  addAllowedRecipient,
  removeAllowedRecipient,
  isRecipientAllowed,
};
