const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const projectRoot = path.resolve(__dirname, '..');
const vendorRoot = path.join(projectRoot, 'vendor/deepmerge');
const installedPackagePath = require.resolve('deepmerge/package.json');
const installedPackage = JSON.parse(fs.readFileSync(installedPackagePath, 'utf8'));
const vendorPackage = JSON.parse(fs.readFileSync(path.join(vendorRoot, 'package.json'), 'utf8'));

if (installedPackage.name !== 'deepmerge' || installedPackage.version !== '4.3.1') {
  throw new Error(`Expected registry deepmerge@4.3.1, found ${installedPackage.name}@${installedPackage.version}.`);
}
if (vendorPackage.name !== installedPackage.name || vendorPackage.version !== installedPackage.version) {
  throw new Error('The vendored deepmerge identity must match the installed package.');
}

const installedRoot = path.dirname(installedPackagePath);
const files = [
  {
    name: 'index.js',
    upstreamHash: '12440c84957c1990ea2d5e33dc0091722dc1dc1585c6d20e0c780e568ffa9d30',
    patchedHash: '470089074806a96b43803d179f94727193c8596d58fb61dc349a89f744d6d6cf',
  },
  {
    name: 'dist/cjs.js',
    upstreamHash: '2e5160f84a1141bd927264afe4d15766f1e6cf07daef182b37ff53fea121de7d',
    patchedHash: 'b6fe28281118473872eed26cf22596faed457a4be818691ac9ab3ec2edfe0d86',
  },
  {
    name: 'dist/umd.js',
    upstreamHash: 'f33e6596482d1fb5c7c427f8ef92f2aa849eea9223acd974176b2fb27ddbf73a',
    patchedHash: '4d2e9274a42453e93c2c19d26d93dc41f81eef121ae1e852706435afa33d23c8',
  },
];

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

let changed = 0;
for (const {name, upstreamHash, patchedHash} of files) {
  const installedPath = path.join(installedRoot, name);
  const vendorPath = path.join(vendorRoot, name);
  const installedSource = fs.readFileSync(installedPath);
  const vendorSource = fs.readFileSync(vendorPath);
  const installedHash = sha256(installedSource);
  const vendorHash = sha256(vendorSource);

  if (vendorHash !== patchedHash) throw new Error(`Unexpected vendored deepmerge source at ${vendorPath}; refusing to patch.`);
  if (installedHash === patchedHash) continue;
  if (installedHash !== upstreamHash) {
    throw new Error(`Unexpected deepmerge@4.3.1 source at ${installedPath}; refusing to patch.`);
  }

  fs.writeFileSync(installedPath, vendorSource);
  changed++;
}

console.log(changed ? 'Applied the local deepmerge@4.3.1 prototype-safe write patch.' : 'deepmerge@4.3.1 prototype-safe write patch is already applied.');
