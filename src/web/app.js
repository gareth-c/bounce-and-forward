const path = require('node:path');
const fs = require('node:fs');
const crypto = require('node:crypto');
const express = require('express');
const session = require('express-session');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const bcrypt = require('bcryptjs');
const { simpleParser } = require('mailparser');
const { config } = require('../config');
const { listMessages, countMessages, getMessage } = require('../db');
const { listAllowedRecipients, addAllowedRecipient, removeAllowedRecipient } = require('../recipients');
const { getSettings, updateSettings } = require('../settings');
const { getStorageStats } = require('../retention');
const { SqliteSessionStore } = require('./sqliteSessionStore');

const PAGE_SIZE = 25;

function createApp() {
  if (!config.web.username || !config.web.passwordHash) {
    throw new Error(
      'WEB_USERNAME and WEB_PASSWORD_HASH must be set (see .env.example / npm run hash-password).'
    );
  }
  if (!config.web.sessionSecret || config.web.sessionSecret === 'change-me-to-a-random-value') {
    throw new Error('SESSION_SECRET must be set to a random value (e.g. `openssl rand -hex 32`).');
  }

  const app = express();
  app.set('view engine', 'ejs');
  app.set('views', path.join(__dirname, 'views'));
  // Only trust X-Forwarded-* headers when actually deployed behind a reverse
  // proxy — otherwise a client could spoof them directly (e.g. claim
  // X-Forwarded-Proto: https to fool secure-cookie logic over plain HTTP).
  if (config.web.trustProxy) {
    app.set('trust proxy', 1);
  }

  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          scriptSrc: ["'self'"],
          styleSrc: ["'self'", "'unsafe-inline'"],
          imgSrc: ["'self'", 'data:'],
          objectSrc: ["'none'"],
          baseUri: ["'none'"],
          frameAncestors: ["'none'"],
        },
      },
    })
  );
  app.use(express.urlencoded({ extended: false }));
  app.use(express.static(path.join(__dirname, 'public')));

  const loginLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: 10,
    standardHeaders: true,
    legacyHeaders: false,
    skipSuccessfulRequests: true,
  });
  app.use(
    session({
      name: 'baf.sid',
      store: new SqliteSessionStore(),
      secret: config.web.sessionSecret,
      resave: false,
      saveUninitialized: false,
      cookie: {
        httpOnly: true,
        sameSite: 'lax',
        secure: config.web.secureCookies,
        maxAge: 12 * 60 * 60 * 1000,
      },
    })
  );

  function requireAuth(req, res, next) {
    if (req.session.authenticated) return next();
    return res.redirect('/login');
  }

  // Synchronizer-token CSRF check for state-changing admin actions. The
  // token is minted once at login (below) and stored server-side in the
  // session; SameSite=Lax on the cookie already blocks the cookie itself
  // from riding along on a cross-site POST in modern browsers, but this is
  // a second, independent layer that doesn't depend on that browser
  // behavior. Login itself is exempt: there's only one fixed admin account,
  // so forcing a login has no attacker-useful effect the way it would on a
  // multi-account site.
  function requireCsrf(req, res, next) {
    const provided = Buffer.from(String(req.body._csrf || ''));
    const expected = Buffer.from(String(req.session.csrfToken || ''));
    if (provided.length !== expected.length || !crypto.timingSafeEqual(provided, expected)) {
      res.status(403).send('Invalid or missing CSRF token. Go back and try again.');
      return;
    }
    next();
  }

  app.use((req, res, next) => {
    res.locals.csrfToken = req.session.csrfToken;
    next();
  });

  app.get('/login', (req, res) => {
    res.render('login', { error: null });
  });

  app.post('/login', loginLimiter, (req, res) => {
    const { username, password } = req.body;
    const validUsername = typeof username === 'string' && username === config.web.username;
    const validPassword =
      typeof password === 'string' && bcrypt.compareSync(password, config.web.passwordHash);

    if (!validUsername || !validPassword) {
      res.status(401).render('login', { error: 'Invalid username or password.' });
      return;
    }

    req.session.regenerate((err) => {
      if (err) {
        res.status(500).render('login', { error: 'Login failed, please try again.' });
        return;
      }
      req.session.authenticated = true;
      req.session.csrfToken = crypto.randomBytes(32).toString('hex');
      res.redirect('/');
    });
  });

  app.post('/logout', requireAuth, requireCsrf, (req, res) => {
    req.session.destroy(() => {
      res.redirect('/login');
    });
  });

  app.get('/', requireAuth, (req, res) => {
    const page = Math.max(1, Number.parseInt(req.query.page, 10) || 1);
    const search = (req.query.q || '').toString();
    const total = countMessages({ search });
    const messages = listMessages({ limit: PAGE_SIZE, offset: (page - 1) * PAGE_SIZE, search });
    res.render('index', {
      messages,
      page,
      totalPages: Math.max(1, Math.ceil(total / PAGE_SIZE)),
      search,
    });
  });

  app.get('/recipients', requireAuth, (req, res) => {
    res.render('recipients', { recipients: listAllowedRecipients(), error: null });
  });

  app.post('/recipients', requireAuth, requireCsrf, (req, res) => {
    const pattern = addAllowedRecipient(req.body.pattern);
    if (!pattern) {
      res.status(400).render('recipients', {
        recipients: listAllowedRecipients(),
        error: 'Enter an address (alice@example.com) or domain (example.com).',
      });
      return;
    }
    res.redirect('/recipients');
  });

  app.post('/recipients/:id/delete', requireAuth, requireCsrf, (req, res) => {
    removeAllowedRecipient(req.params.id);
    res.redirect('/recipients');
  });

  app.get('/settings', requireAuth, (req, res) => {
    res.render('settings', { settings: getSettings(), stats: getStorageStats(), error: null });
  });

  app.post('/settings', requireAuth, requireCsrf, (req, res) => {
    const quotaBytes = Number(req.body.quotaGb) * 1024 * 1024 * 1024;
    const retentionDays = Number(req.body.retentionDays);
    const { error } = updateSettings({ quotaBytes, retentionDays });
    if (error) {
      res.status(400).render('settings', { settings: getSettings(), stats: getStorageStats(), error });
      return;
    }
    res.redirect('/settings');
  });

  app.get('/messages/:id', requireAuth, async (req, res) => {
    const message = getMessage(req.params.id);
    if (!message) {
      res.status(404).render('not-found');
      return;
    }
    const rawPath = path.join(config.messagesDir, message.raw_filename);
    let parsed;
    try {
      parsed = await simpleParser(fs.createReadStream(rawPath), { skipHtmlToText: true });
    } catch (err) {
      res.status(500).send('Failed to read stored message.');
      return;
    }
    res.render('message', { message, parsed });
  });

  app.get('/messages/:id/raw', requireAuth, (req, res) => {
    const message = getMessage(req.params.id);
    if (!message) {
      res.status(404).render('not-found');
      return;
    }
    const rawPath = path.join(config.messagesDir, message.raw_filename);
    res.setHeader('Content-Type', 'message/rfc822');
    res.setHeader('Content-Disposition', `attachment; filename="${message.id}.eml"`);
    fs.createReadStream(rawPath).pipe(res);
  });

  app.get('/messages/:id/attachments/:index', requireAuth, async (req, res) => {
    const message = getMessage(req.params.id);
    if (!message) {
      res.status(404).render('not-found');
      return;
    }
    const rawPath = path.join(config.messagesDir, message.raw_filename);
    const parsed = await simpleParser(fs.createReadStream(rawPath));
    const attachment = parsed.attachments[Number.parseInt(req.params.index, 10)];
    if (!attachment) {
      res.status(404).send('Attachment not found.');
      return;
    }
    // contentType comes from the captured email's own MIME headers, i.e. is
    // attacker-controlled; only trust it if it actually looks like a MIME
    // type, so a malformed value can't reach res.setHeader (which throws on
    // invalid header characters, e.g. embedded CRLF).
    const contentType = /^[\w.+-]+\/[\w.+-]+$/.test(attachment.contentType || '')
      ? attachment.contentType
      : 'application/octet-stream';
    res.setHeader('Content-Type', contentType);
    const filename = (attachment.filename || 'attachment').replace(/[\r\n"]/g, '_');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.send(attachment.content);
  });

  return app;
}

module.exports = { createApp };
