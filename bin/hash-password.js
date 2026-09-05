#!/usr/bin/env node
const bcrypt = require('bcryptjs');

const password = process.argv[2];
if (!password) {
  console.error('Usage: npm run hash-password -- \'your-password-here\'');
  process.exit(1);
}

const hash = bcrypt.hashSync(password, 12);
console.log(hash);
