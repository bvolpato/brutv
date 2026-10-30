const fs = require('node:fs');
const path = require('node:path');

const projectRoot = path.resolve(__dirname, '..');
const lock = JSON.parse(fs.readFileSync(path.join(projectRoot, 'package-lock.json'), 'utf8'));
const oldImport = 'const getImageSize = require("image-size");';
const newImport = [
  'const { imageSize } = require("image-size");',
  'const getImageSize = input =>',
  '  imageSize(typeof input === "string" ? fs.readFileSync(input) : input);',
].join('\n');
const metros = Object.entries(lock.packages).filter(([location]) => location.endsWith('/metro'));

if (metros.length === 0) {
  throw new Error('No locked Metro installation found.');
}

let patched = 0;
for (const [location, metadata] of metros) {
  if (!['0.76.5', '0.76.9'].includes(metadata.version)) {
    throw new Error(`Review the image-size compatibility patch for Metro ${metadata.version}.`);
  }
  const assetsPath = path.join(projectRoot, location, 'src/Assets.js');
  // npm may hoist a duplicate package to a shared node_modules location. Lockfile
  // entries that are not materialized by the installed tree do not need patching.
  if (!fs.existsSync(assetsPath)) continue;
  const source = fs.readFileSync(assetsPath, 'utf8');
  if (source.includes(oldImport)) {
    fs.writeFileSync(assetsPath, source.replace(oldImport, newImport));
  } else if (!source.includes(newImport)) {
    throw new Error(`Unexpected image-size import in ${assetsPath}.`);
  }
  patched++;
}

if (patched === 0) throw new Error('No installed Metro Assets.js file was found.');
console.log('Metro 0.76 uses the patched image-size 2 API.');
