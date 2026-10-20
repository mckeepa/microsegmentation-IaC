import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

const directory = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(directory, '../..');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const passwordPath = path.join(root, config.adminPasswordFile);
const keyPath = path.join(root, config.sshPrivateKey + '.pub');
const output = path.join(root, 'work/windows-unattended');
fs.mkdirSync(output, {recursive: true, mode: 0o700});
if (fs.lstatSync(output).isSymbolicLink()) throw new Error('Refusing symlinked answer-file directory.');
for (const filename of [passwordPath, keyPath]) {
  if (fs.existsSync(filename) && fs.lstatSync(filename).isSymbolicLink()) throw new Error('Refusing symlinked credential files.');
}
if (!fs.existsSync(passwordPath)) {
  fs.writeFileSync(passwordPath, 'Aa1!' + crypto.randomBytes(24).toString('base64url') + '\n', {mode: 0o600, flag: 'wx'});
}
fs.chmodSync(passwordPath, 0o600);
const password = fs.readFileSync(passwordPath, 'utf8').trim();
if (password.length < 20 || /[\r\n]/.test(password)) throw new Error('Existing administrator password file is invalid. Restore it; do not regenerate installed credentials.');
const bootstrap = "$ErrorActionPreference='Stop'; $seed=Get-PSDrive -PSProvider FileSystem | Where-Object {Test-Path (Join-Path $_.Root 'configure-windows.ps1')} | Select-Object -First 1 -ExpandProperty Root; if(-not $seed){throw 'Windows seed media missing'}; $destination='C:\\ProgramData\\microsegmentation-iac'; New-Item -ItemType Directory -Path $destination -Force | Out-Null; Copy-Item (Join-Path $seed 'configure-windows.ps1') (Join-Path $destination 'configure-windows.ps1') -Force; & (Join-Path $destination 'configure-windows.ps1')";
const encoded = Buffer.from(bootstrap, 'utf16le').toString('base64');
const escapeXml = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
let answer = fs.readFileSync(path.join(directory, 'windows-unattend.xml'), 'utf8');
for (const [name, value] of Object.entries({ACCEPT_EULA: config.acceptEvaluationTerms, IMAGE_INDEX: config.imageIndex, HOSTNAME: config.hostname, ADMIN_PASSWORD: password, BOOTSTRAP_COMMAND: encoded})) {
  answer = answer.replaceAll('__' + name + '__', escapeXml(value));
}
if (/__[A-Z_]+__/.test(answer)) throw new Error('Unresolved answer-file placeholder.');
const secret = {
  apiVersion: 'v1', kind: 'Secret',
  metadata: {name: 'windows-unattended-seed', namespace: config.namespace, labels: {'microsegmentation-lab/managed-by': 'microsegmentation-iac'}},
  type: 'Opaque',
  stringData: {
    'autounattend.xml': answer,
    'configure-windows.ps1': fs.readFileSync(path.join(directory, 'configure-windows.ps1'), 'utf8'),
    'administrator.pub': fs.readFileSync(keyPath, 'utf8').trim() + '\n'
  }
};
for (const [filename, contents] of [['autounattend.xml', answer], ['secret.json', JSON.stringify(secret)]]) {
  const destination = path.join(output, filename);
  if (fs.existsSync(destination) && fs.lstatSync(destination).isSymbolicLink()) throw new Error('Refusing symlinked generated media.');
  fs.writeFileSync(destination, contents, {mode: 0o600});
  fs.chmodSync(destination, 0o600);
}
console.log('Windows answer media prepared privately. Username: ' + config.adminUser + '. Password file: ' + config.adminPasswordFile + ' (0600).');