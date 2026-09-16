#!/usr/bin/env node
// npx 用のシム。同じリポジトリの install.sh に引数をそのまま渡す。
//   npx github:<owner>/brain-kit --partner <name> --dev <name>
// install.sh は自分の場所（dirname）からテンプレートを読むので、npx の一時ディレクトリでも動く。
'use strict';
const path = require('path');
const { spawnSync } = require('child_process');

if (process.platform === 'win32') {
  console.error('brain-kit: Windows はそのままでは対象外。WSL（Ubuntu）の中で実行する。');
  process.exit(1);
}

const installer = path.join(__dirname, '..', 'install.sh');
const result = spawnSync('bash', [installer, ...process.argv.slice(2)], { stdio: 'inherit' });
if (result.error) {
  console.error('brain-kit: bash を起動できない: ' + result.error.message);
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);
