const path = require('node:path');
require('dotenv').config();

function parseRecipients(raw) {
  return (raw || '')
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
}

const dataDir = path.resolve(process.cwd(), process.env.DATA_DIR || './data');

const config = {
  dataDir,
  messagesDir: path.join(dataDir, 'messages'),
  dbPath: path.join(dataDir, 'db.sqlite'),

  smtp: {
    port: Number(process.env.SMTP_PORT || 2525),
    host: process.env.SMTP_HOST || '0.0.0.0',
    banner: process.env.SMTP_BANNER || 'mail ESMTP',
    maxSize: Number(process.env.SMTP_MAX_SIZE || 25 * 1024 * 1024),
    allowedRecipients: parseRecipients(process.env.ALLOWED_RECIPIENTS),
    bounceCode: Number(process.env.BOUNCE_CODE || 550),
    bounceMessage: process.env.BOUNCE_MESSAGE || '5.7.1 Message not accepted for delivery',
  },

  web: {
    port: Number(process.env.WEB_PORT || 8080),
    host: process.env.WEB_HOST || '127.0.0.1',
    username: process.env.WEB_USERNAME || '',
    passwordHash: process.env.WEB_PASSWORD_HASH || '',
    sessionSecret: process.env.SESSION_SECRET || '',
    secureCookies: /^true$/i.test(process.env.WEB_SECURE_COOKIES || 'false'),
    trustProxy: /^true$/i.test(process.env.WEB_TRUST_PROXY || 'false'),
  },

  storage: {
    quotaBytes: Number(process.env.STORAGE_QUOTA_GB || 5) * 1024 * 1024 * 1024,
    retentionDays: Number(process.env.RETENTION_DAYS || 365),
  },
};

module.exports = { config };
