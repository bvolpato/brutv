const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const deepmerge = require('deepmerge');

const root = path.resolve(__dirname, '..');
const lock = require('../package-lock.json');
const iconPath = path.join(root, 'assets/image/BruTV.png');

const metros = Object.entries(lock.packages).filter(([location, metadata]) =>
  location.endsWith('/metro') && fs.existsSync(path.join(root, location, 'src/Assets.js')));
assert.ok(metros.length > 0, 'at least one locked Metro installation must be present');

for (const [location, metadata] of metros) {

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

test('patched deepmerge preserves __proto__ as data when merging into a null target', () => {
  const malicious = JSON.parse('{"session":{"__proto__":{"admin":true}}}');
  const merged = deepmerge({session: null}, malicious);
  assert.equal(Object.getPrototypeOf(merged.session), Object.prototype);
  assert.equal(Object.hasOwn(merged.session, '__proto__'), true);
  assert.deepEqual(merged.session.__proto__, {admin: true});
  assert.equal(merged.session.admin, undefined);
  assert.equal(({}).admin, undefined);
});

test('React Native CLI config merge still replaces arrays and merges nested settings', () => {
  const merge = require('@react-native-community/cli-config/build/merge').default;
  assert.deepEqual(merge({resolver: {assetExts: ['png'], unstable: true}}, {resolver: {assetExts: ['svg']}}), {
    resolver: {assetExts: ['svg'], unstable: true},
  });

  const malicious = JSON.parse('{"session":{"__proto__":{"admin":true}}}');
  const merged = merge({session: null}, malicious);
  assert.equal(Object.getPrototypeOf(merged.session), Object.prototype);
  assert.equal(Object.hasOwn(merged.session, '__proto__'), true);
  assert.deepEqual(merged.session.__proto__, {admin: true});
  assert.equal(merged.session.admin, undefined);
});
