import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { planChangedPaths } from './ci-plan.mjs';

const flags = (plan) => Object.fromEntries(
  ['core', 'apple', 'android', 'vega', 'ps5', 'web', 'release_tools'].map((key) => [key, plan[key]]),
);
const none = { core: false, apple: false, android: false, vega: false, ps5: false, web: false, release_tools: false };
const all = Object.fromEntries(Object.keys(none).map((key) => [key, true]));

test('empty and documentation or repository metadata changes skip app jobs', () => {
  assert.deepEqual(flags(planChangedPaths([])), none);
  assert.deepEqual(flags(planChangedPaths([
    'README.md', 'README.txt', 'PRIVACY.md', 'docs/guide.txt', '.gitignore', '.gitattributes',
    'LICENSE', 'LICENSE-MIT', 'NOTICE.md', '.github/dependabot.yml',
  ])), none);
});

test('the public site change set routes only to web checks', () => {
  const plan = planChangedPaths([
    'README.md', 'PRIVACY.md', '.gitignore', 'docs/index.html', 'docs/styles.css',
    'mobile/ios/STORE_LISTING.md', 'tools/join-page.test.mjs', '.github/dependabot.yml',
  ]);
  assert.deepEqual(flags(plan), { ...none, web: true });
  assert.deepEqual(plan.apple_matrix.include, []);
});

test('platform source paths route only to their platform', () => {
  for (const [file, key] of [
    ['mobile/android/app/src/main/MainActivity.kt', 'android'],
    ['mobile/vega/src/player.ts', 'vega'],
    ['mobile/ps5/src/player.cpp', 'ps5'],
    ['mobile/ps5/CMakeLists.txt', 'ps5'],
  ]) assert.deepEqual(flags(planChangedPaths([file])), { ...none, [key]: true });
});

test('iOS source and deletions route to core and the four-job routine matrix', () => {
  const plan = planChangedPaths(['mobile/ios/BruTV/BruTV/AppRootView.swift']);
  assert.deepEqual(flags(plan), { ...none, core: true, apple: true });
  assert.deepEqual(plan.apple_matrix.include.map(({ target }) => target), ['ios-unit', 'iphone-smoke', 'tvos', 'catalyst']);
  assert.equal(plan.apple_matrix.include[0].tests, 'BruTVTests');
  assert.equal(plan.apple_matrix.include[1].tests, 'BruTVUITests/BruTVUITests/testAppLaunchAndLoginScreen BruTVUITests/BruTVUITests/testDemoLoginButton BruTVUITests/BruTVUITests/testSectionNavigation');
  assert.deepEqual(flags(planChangedPaths(['mobile/android/app/src/main/Deleted.kt'])), { ...none, android: true });
});

test('iOS support scripts, tests, and Linux tools route only to release tooling', () => {
  for (const file of [
    'mobile/ios/scripts/package.sh', 'mobile/ios/scripts/release.py',
    'mobile/ios/BruTV/tests/fixture.json', 'mobile/ios/BruTV/linux-tools/check.sh',
  ]) assert.deepEqual(flags(planChangedPaths([file])), { ...none, release_tools: true }, file);
});

test('root release helpers and Swift generators have narrow routes', () => {
  for (const file of ['build.sh', 'release.sh', 'capture-screenshots.sh', 'tools/brutv-login-qr.py', 'uv.toml']) {
    assert.deepEqual(flags(planChangedPaths([file])), { ...none, release_tools: true }, file);
  }
  assert.deepEqual(flags(planChangedPaths(['test.sh'])), { ...none, core: true, release_tools: true });
  assert.deepEqual(flags(planChangedPaths(['tools/make-preview.swift'])), { ...none, apple: true });
});

test('CI planner changes trigger all routine checks; unknown source is conservative', () => {
  for (const file of ['.github/workflows/ci.yml', 'tools/ci-plan.mjs', 'tools/ci-plan.test.mjs', 'new-source.js', 'requirements.txt', '.gitmodules']) {
    const plan = planChangedPaths([file]);
    assert.deepEqual(flags(plan), all, file);
    assert.equal(plan.apple_matrix.include.length, 4, file);
  }
});

test('manual scopes select their named platform and full selects all six Apple rows', () => {
  for (const scope of ['android', 'vega', 'ps5', 'web']) {
    assert.deepEqual(flags(planChangedPaths(['ignored.swift'], { scope })), { ...none, [scope]: true });
  }
  assert.deepEqual(flags(planChangedPaths([], { scope: 'apple' })), { ...none, core: true, apple: true });
  const full = planChangedPaths([], { scope: 'full' });
  assert.deepEqual(flags(full), all);
  assert.deepEqual(full.apple_matrix.include.map(({ target }) => target), ['ios-unit', 'iphone-ui', 'ipad-ui', 'duo-ui', 'tvos', 'catalyst']);
  assert.equal(full.apple_matrix.include[1].simulator, 'iPhone 18 Pro');
  assert.equal(full.apple_matrix.include[2].simulator, 'iPad Pro 13-inch (M5)');
  assert.equal(full.apple_matrix.include[3].simulator, 'iPhone Duo');
  assert.equal(full.apple_matrix.include[3].runtime, 'com.apple.CoreSimulator.SimRuntime.iOS-27-1');
  assert.equal(full.apple_matrix.include[1].tests, 'BruTVUITests');
  assert.throws(() => planChangedPaths([], { scope: 'invalid' }), /Unknown CI scope/);
});

test('the CLI routes a multi-commit push with a deleted source file and a version tag', (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'brutv-ci-plan-'));
  t.after(() => rmSync(directory, { recursive: true }));
  const git = (...args) => execFileSync('git', [
    '-c', 'user.name=CI fixture', '-c', 'user.email=ci@example.invalid',
    '-c', 'commit.gpgsign=false', ...args,
  ], { cwd: directory, encoding: 'utf8' }).trim();
  git('init', '-q');
  mkdirSync(join(directory, 'mobile/android'), { recursive: true });
  writeFileSync(join(directory, 'mobile/android/player.kt'), 'fun play() {}\n');
  git('add', '.');
  git('commit', '-qm', 'Initial fixture');
  const before = git('rev-parse', 'HEAD');
  unlinkSync(join(directory, 'mobile/android/player.kt'));
  git('add', '-u');
  git('commit', '-qm', 'Remove the player fixture');
  writeFileSync(join(directory, 'README.md'), 'Documentation only\n');
  git('add', '.');
  git('commit', '-qm', 'Update documentation');
  const after = git('rev-parse', 'HEAD');
  const event = join(directory, 'event.json');
  const output = join(directory, 'output');
  writeFileSync(event, JSON.stringify({ before, after }));
  const run = (ref) => {
    writeFileSync(output, '');
    execFileSync(process.execPath, [fileURLToPath(new URL('./ci-plan.mjs', import.meta.url))], {
      cwd: directory,
      env: { ...process.env, GITHUB_EVENT_NAME: 'push', GITHUB_EVENT_PATH: event,
        GITHUB_SHA: after, GITHUB_REF: ref, GITHUB_OUTPUT: output },
    });
    return Object.fromEntries(readFileSync(output, 'utf8').trim().split('\n').map((line) => {
      const separator = line.indexOf('=');
      return [line.slice(0, separator), JSON.parse(line.slice(separator + 1))];
    }));
  };
  assert.deepEqual(flags(run('refs/heads/main')), { ...none, android: true });
  const release = run('refs/tags/v1.0.0');
  assert.deepEqual(flags(release), all);
  assert.equal(release.apple_matrix.include.length, 6);
});
