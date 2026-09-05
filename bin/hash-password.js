#!/usr/bin/env node
const bcrypt = require('bcryptjs');

async function readStdin() {
  let data = '';
  for await (const chunk of process.stdin) data += chunk;
  return data.replace(/\r?\n$/, '');
}

async function main() {
  // Prefer stdin (e.g. `printf '%s' "$PASSWORD" | node bin/hash-password.js`)
  // so the password never appears in argv, which is visible to other
  // processes/users on the same machine via `ps`. The argv form is kept for
  // interactive command-line use.
  const password = process.argv[2] || (process.stdin.isTTY ? '' : await readStdin());
  if (!password) {
    console.error("Usage: npm run hash-password -- 'your-password-here'");
    console.error('   or: printf \'%s\' \'your-password-here\' | npm run hash-password');
    process.exit(1);
  }
  console.log(bcrypt.hashSync(password, 12));
}

main();
