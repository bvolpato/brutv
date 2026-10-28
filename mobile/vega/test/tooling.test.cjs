const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const lock = require('../package-lock.json');
const iconPath = path.join(root, 'assets/image/BruTV.png');

for (const [location, metadata] of Object.entries(lock.packages)) {
  if (!location.endsWith('/metro')) continue;

  test(`Metro ${metadata.version} reads bundled image dimensions`, async () => {
    const {getAssetSize, getAssetData} = require(path.join(root, location, 'src/Assets.js'));
    assert.deepEqual(getAssetSize('png', fs.readFileSync(iconPath), iconPath), {
      width: 2048,
      height: 2048,
    });
    const asset = await getAssetData(iconPath, 'assets/image/BruTV.png', [], 'kepler', '/assets');
    assert.equal(asset.width, 2048);
    assert.equal(asset.height, 2048);
  });
}
