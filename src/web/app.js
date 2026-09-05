const path = require('node:path');
const fs = require('node:fs');
const express = require('express');
const session = require('express-session');
const helmet = require('helmet');
const bcrypt = require('bcryptjs');
const { simpleParser } = require('mailparser');
const { config } = require('../config');
const { listMessages, countMessages, getMessage } = require('../db');
const { listAllowedRecipients, addAllowedRecipient, removeAllowedRecipient } = require('../recipients');

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
  app.set('trust proxy', 1);

  app.use(helmet({ contentSecurityPolicy: false }));
  app.use(express.urlencoded({ extended: false }));
  app.use(
    session({
      name: 'baf.sid',
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

  app.get('/login', (req, res) => {
    res.render('login', { error: null });
  });

  app.post('/login', (req, res) => {
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
      res.redirect('/');
    });
  });

  app.post('/logout', requireAuth, (req, res) => {
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

  app.post('/recipients', requireAuth, (req, res) => {
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

  app.post('/recipients/:id/delete', requireAuth, (req, res) => {
    removeAllowedRecipient(req.params.id);
    res.redirect('/recipients');
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
    res.setHeader('Content-Type', attachment.contentType || 'application/octet-stream');
    const filename = (attachment.filename || 'attachment').replace(/[\r\n"]/g, '_');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.send(attachment.content);
  });

  return app;
}

module.exports = { createApp };
