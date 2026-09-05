const fs = require('node:fs');
const path = require('node:path');
const { config } = require('./config');
const { deleteMessage, listMessagesForPruning, totalMessageBytes } = require('./db');
const { getSettings } = require('./settings');

function removeMessage(row) {
  deleteMessage(row.id);
  try {
    fs.unlinkSync(path.join(config.messagesDir, row.raw_filename));
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }
}

// Deletes anything past the retention window, then — if still over the
// storage quota — deletes the oldest remaining messages until back under it.
// Age-based pruning runs first so quota pruning doesn't keep old junk around
// just because there happens to be room for it.
function enforceRetention() {
  const { quotaBytes, retentionDays } = getSettings();
  let removed = 0;

  if (retentionDays >= 0) {
    const cutoff = new Date(Date.now() - retentionDays * 24 * 60 * 60 * 1000).toISOString();
    for (const row of listMessagesForPruning()) {
      if (row.received_at < cutoff) {
        removeMessage(row);
        removed += 1;
      }
    }
  }

  let total = totalMessageBytes();
  if (total > quotaBytes) {
    for (const row of listMessagesForPruning()) {
      if (total <= quotaBytes) break;
      removeMessage(row);
      total -= row.size;
      removed += 1;
    }
  }

  return removed;
}

function getStorageStats() {
  const rows = listMessagesForPruning();
  return {
    messageCount: rows.length,
    totalBytes: rows.reduce((sum, r) => sum + r.size, 0),
  };
}

module.exports = { enforceRetention, getStorageStats };
