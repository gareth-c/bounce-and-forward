const fs = require('node:fs');
const { config } = require('./config');

let DatabaseSync;
try {
  ({ DatabaseSync } = require('node:sqlite'));
} catch (err) {
  throw new Error(
    'node:sqlite is unavailable. This requires Node.js >= 22.13.0 (or >= 23.4.0). ' +
      `Current version: ${process.version}. Original error: ${err.message}`
  );
}

fs.mkdirSync(config.messagesDir, { recursive: true });

const db = new DatabaseSync(config.dbPath);

const ddlStatements = [
  `CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    received_at TEXT NOT NULL,
    mail_from TEXT,
    rcpt_to TEXT NOT NULL,
    subject TEXT,
    size INTEGER NOT NULL,
    remote_address TEXT,
    raw_filename TEXT NOT NULL,
    bounce_code INTEGER NOT NULL,
    bounce_message TEXT NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS idx_messages_received_at ON messages(received_at)`,
  `CREATE TABLE IF NOT EXISTS allowed_recipients (
    id TEXT PRIMARY KEY,
    pattern TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL
  )`,
];

for (const statement of ddlStatements) {
  db.prepare(statement).run();
}

const insertStmt = db.prepare(`
  INSERT INTO messages (id, received_at, mail_from, rcpt_to, subject, size, remote_address, raw_filename, bounce_code, bounce_message)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
`);

function insertMessage(msg) {
  insertStmt.run(
    msg.id,
    msg.receivedAt,
    msg.mailFrom,
    JSON.stringify(msg.rcptTo),
    msg.subject,
    msg.size,
    msg.remoteAddress,
    msg.rawFilename,
    msg.bounceCode,
    msg.bounceMessage
  );
}

function listMessages({ limit = 50, offset = 0, search = '' } = {}) {
  let rows;
  if (search) {
    const like = `%${search}%`;
    rows = db
      .prepare(
        `SELECT * FROM messages
         WHERE mail_from LIKE ? OR rcpt_to LIKE ? OR subject LIKE ?
         ORDER BY received_at DESC LIMIT ? OFFSET ?`
      )
      .all(like, like, like, limit, offset);
  } else {
    rows = db
      .prepare(`SELECT * FROM messages ORDER BY received_at DESC LIMIT ? OFFSET ?`)
      .all(limit, offset);
  }
  return rows.map(deserializeRow);
}

function countMessages({ search = '' } = {}) {
  let row;
  if (search) {
    const like = `%${search}%`;
    row = db
      .prepare(
        `SELECT COUNT(*) as c FROM messages WHERE mail_from LIKE ? OR rcpt_to LIKE ? OR subject LIKE ?`
      )
      .get(like, like, like);
  } else {
    row = db.prepare(`SELECT COUNT(*) as c FROM messages`).get();
  }
  return row.c;
}

function getMessage(id) {
  const row = db.prepare(`SELECT * FROM messages WHERE id = ?`).get(id);
  return row ? deserializeRow(row) : null;
}

function deserializeRow(row) {
  return { ...row, rcptTo: JSON.parse(row.rcpt_to) };
}

module.exports = { db, insertMessage, listMessages, countMessages, getMessage };
