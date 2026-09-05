const { config } = require('./config');
const { createServer: createSmtpServer } = require('./smtp/server');
const { createApp } = require('./web/app');
const { enforceRetention } = require('./retention');

// Age-based pruning needs to run even when no new mail arrives to trigger it
// (enforcement also runs right after every capture — see smtp/server.js).
enforceRetention();
const retentionInterval = setInterval(enforceRetention, 60 * 60 * 1000);
retentionInterval.unref();

const smtpServer = createSmtpServer();
smtpServer.listen(config.smtp.port, config.smtp.host, () => {
  console.log(
    `SMTP daemon listening on ${config.smtp.host}:${config.smtp.port} ` +
      `(accepting mail for: ${config.smtp.allowedRecipients.join(', ') || '(none configured)'})`
  );
});

const app = createApp();
app.listen(config.web.port, config.web.host, () => {
  console.log(`Web UI listening on http://${config.web.host}:${config.web.port}`);
});

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

function shutdown() {
  console.log('Shutting down...');
  smtpServer.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}
