const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { SMTPServer } = require('smtp-server');
const { simpleParser } = require('mailparser');
const { config } = require('../config');
const { insertMessage } = require('../db');
const { isRecipientAllowed } = require('../recipients');

function makeSmtpError(code, message) {
  const err = new Error(message);
  err.responseCode = code;
  return err;
}

function onMailFrom(address, session, callback) {
  // Accept any sender; the point of this server is to capture inbound mail
  // for the configured recipients, not to authenticate senders.
  callback();
}

function onRcptTo(address, session, callback) {
  if (!isRecipientAllowed(address.address)) {
    callback(makeSmtpError(550, '5.1.1 No such user here'));
    return;
  }
  callback();
}

async function onData(stream, session, callback) {
  const id = crypto.randomUUID();
  const rawFilename = `${id}.eml`;
  const rawPath = path.join(config.messagesDir, rawFilename);
  const receivedAt = new Date().toISOString();

  const fileStream = fs.createWriteStream(rawPath);

  try {
    const [parsed] = await Promise.all([
      simpleParser(stream, { skipHtmlToText: true }),
      pipeToFile(stream, fileStream),
    ]);

    const size = fs.statSync(rawPath).size;

    insertMessage({
      id,
      receivedAt,
      mailFrom: session.envelope.mailFrom ? session.envelope.mailFrom.address : null,
      rcptTo: session.envelope.rcptTo.map((r) => r.address),
      subject: parsed.subject || null,
      size,
      remoteAddress: session.remoteAddress,
      rawFilename,
      bounceCode: config.smtp.bounceCode,
      bounceMessage: config.smtp.bounceMessage,
    });
  } catch (err) {
    // Even if parsing/storage fails, still bounce below rather than silently
    // accepting mail we failed to capture.
    // eslint-disable-next-line no-console
    console.error('Failed to store message', err);
  }

  callback(makeSmtpError(config.smtp.bounceCode, config.smtp.bounceMessage));
}

function pipeToFile(stream, fileStream) {
  // A Node Readable can feed multiple consumers at once (both simpleParser
  // and this file write below receive every chunk), so this tees the raw
  // message to disk in parallel with parsing it.
  return new Promise((resolve, reject) => {
    stream.pipe(fileStream);
    fileStream.on('finish', resolve);
    fileStream.on('error', reject);
  });
}

function createServer() {
  const server = new SMTPServer({
    banner: config.smtp.banner,
    size: config.smtp.maxSize,
    authOptional: true,
    disabledCommands: ['AUTH'],
    onMailFrom,
    onRcptTo,
    onData,
    logger: false,
  });

  server.on('error', (err) => {
    // eslint-disable-next-line no-console
    console.error('SMTP server error:', err);
  });

  return server;
}

module.exports = { createServer };
