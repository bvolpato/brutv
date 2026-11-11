#!/usr/bin/env node
import { appendFileSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const appleRoutine = [
  { name: 'iOS unit tests', target: 'ios-unit', action: 'test', scheme: 'BruTV', simulator: 'iPhone 18 Pro', tests: 'BruTVTests' },
  { name: 'iPhone UI smoke', target: 'iphone-smoke', action: 'test', scheme: 'BruTV', simulator: 'iPhone 18 Pro', tests: 'BruTVUITests/BruTVUITests/testAppLaunchAndLoginScreen BruTVUITests/BruTVUITests/testDemoLoginButton BruTVUITests/BruTVUITests/testSectionNavigation' },
  { name: 'tvOS simulator build', target: 'tvos', action: 'build', scheme: 'BruTV-tvOS', destination: 'generic/platform=tvOS Simulator', tests: '' },
  { name: 'Mac Catalyst build', target: 'catalyst', action: 'build', scheme: 'BruTV', destination: 'generic/platform=macOS,variant=Mac Catalyst', tests: '' },
];

const appleFull = [
  appleRoutine[0],
  { name: 'iPhone UI tests', target: 'iphone-ui', action: 'test', scheme: 'BruTV', simulator: 'iPhone 18 Pro', tests: 'BruTVUITests' },
  { name: 'iPad UI tests', target: 'ipad-ui', action: 'test', scheme: 'BruTV', simulator: 'iPad Pro 13-inch (M5)', tests: 'BruTVUITests' },
  { name: 'iPhone Duo UI tests', target: 'duo-ui', action: 'test', scheme: 'BruTV', simulator: 'iPhone Duo', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-1', tests: 'BruTVUITests' },
  appleRoutine[2],
  appleRoutine[3],
];

const platforms = ['core', 'apple', 'android', 'vega', 'ps5', 'web', 'release_tools'];
const scopes = new Set(['changed', 'apple', 'android', 'vega', 'ps5', 'web', 'full']);
const emptyFlags = () => Object.fromEntries(platforms.map((key) => [key, false]));
const allFlags = () => Object.fromEntries(platforms.map((key) => [key, true]));
const normalize = (file) => file.replaceAll('\\', '/').replace(/^\.\//, '');
const isDocumentation = (file) => {
  const base = file.split('/').at(-1).toLowerCase();
  return /\.md$/.test(base)
    || (file.startsWith('docs/') && /\.txt$/.test(base))
    || /^(readme|privacy|changelog|contributing|code_of_conduct)\.txt$/.test(base)
    || /^(license|licence)([-_.].*)?$/.test(base)
    || /^(copying|notice)([-_.].*)?$/.test(base)
    || ['.gitignore', '.gitattributes'].includes(base)
    || file === '.github/dependabot.yml';
};

export function planChangedPaths(paths, { scope = 'changed' } = {}) {
  if (!scopes.has(scope)) throw new RangeError(`Unknown CI scope: ${scope}`);
  const flags = emptyFlags();
  let fullAppleUI = false;

  if (scope === 'full') {
    Object.assign(flags, allFlags());
    fullAppleUI = true;
  } else if (scope !== 'changed') {
    flags[scope] = true;
    if (scope === 'apple') flags.core = true;
  } else {
    for (const rawPath of paths) {
      const file = normalize(String(rawPath));
      if (!file || isDocumentation(file)) continue;

      if (file === '.github/workflows/ci.yml' || /^tools\/ci-plan\.(mjs|test\.mjs)$/.test(file)) {
        Object.assign(flags, allFlags());
      } else if (file === 'tools/join-page.test.mjs' || file.startsWith('docs/')) {
        flags.web = true;
      } else if (file.startsWith('mobile/android/')) {
        flags.android = true;
      } else if (file.startsWith('mobile/vega/')) {
        flags.vega = true;
      } else if (file.startsWith('mobile/ps5/')) {
        flags.ps5 = true;
      } else if (file.startsWith('mobile/ios/')) {
        if (/\/linux-tools\//.test(`/${file}`) || /\/tests\//i.test(`/${file}`) || /\.(sh|py)$/i.test(file)) {
          flags.release_tools = true;
        } else {
          flags.apple = true;
          flags.core = true;
        }
      } else if (['build.sh', 'release.sh', 'capture-screenshots.sh', 'tools/brutv-login-qr.py', 'uv.toml'].includes(file)) {
        flags.release_tools = true;
      } else if (/^tools\/make-[^/]+\.swift$/.test(file)) {
        flags.apple = true;
      } else if (file === 'test.sh') {
        flags.core = true;
        flags.release_tools = true;
      } else {
        Object.assign(flags, allFlags());
      }
    }
  }

  const appleMatrix = flags.apple ? (fullAppleUI ? appleFull : appleRoutine) : [];
  return { ...flags, apple_matrix: { include: appleMatrix.map((row) => ({ ...row })) } };
}

function validSha(value) {
  return typeof value === 'string' && /^[0-9a-f]{7,64}$/i.test(value) && !/^0+$/.test(value);
}

function gitPaths(args) {
  const output = execFileSync('git', args, { encoding: 'buffer', maxBuffer: 32 * 1024 * 1024 });
  return output.toString('utf8').split('\0').filter(Boolean);
}

function fallbackPaths() {
  console.warn('CI planner: diff base is missing or invalid; selecting all routine checks.');
  try {
    return [...gitPaths(['ls-tree', '-r', '--name-only', '-z', 'HEAD']), '__ci_plan_diff_unavailable__'];
  } catch {
    return ['__ci_plan_diff_unavailable__'];
  }
}

function readEvent(eventPath) {
  if (!eventPath) return {};
  try { return JSON.parse(readFileSync(eventPath, 'utf8')); } catch { return {}; }
}

function determinePlan() {
  const event = readEvent(process.env.GITHUB_EVENT_PATH);
  const name = process.env.GITHUB_EVENT_NAME || '';
  const sha = process.env.GITHUB_SHA || '';
  const ref = process.env.GITHUB_REF || '';
  if (name === 'push' && /^refs\/tags\/v/i.test(ref)) return planChangedPaths([], { scope: 'full' });

  try {
    if (name === 'workflow_dispatch') {
      const scope = event.inputs?.scope || process.env.INPUT_SCOPE || 'changed';
      if (scope !== 'changed') return planChangedPaths([], { scope });
      return planChangedPaths(gitPaths(['diff', '--name-only', '-z', 'HEAD^..HEAD']));
    }
    if (name === 'pull_request') {
      const base = event.pull_request?.base?.sha;
      const head = event.pull_request?.head?.sha || sha;
      if (!validSha(base) || !validSha(head)) return planChangedPaths(fallbackPaths());
      return planChangedPaths(gitPaths(['diff', '--name-only', '-z', `${base}...${head}`]));
    }
    if (name === 'push') {
      const before = event.before;
      const head = sha || event.after;
      if (!validSha(before) || !validSha(head)) return planChangedPaths(fallbackPaths());
      return planChangedPaths(gitPaths(['diff', '--name-only', '-z', `${before}..${head}`]));
    }
  } catch {
    return planChangedPaths(fallbackPaths());
  }
  return planChangedPaths(fallbackPaths());
}

function runCli() {
  const plan = determinePlan();
  for (const key of platforms) console.log(`${key}=${plan[key]}`);
  console.log(`apple_matrix=${JSON.stringify(plan.apple_matrix)}`);
  const outputFile = process.env.GITHUB_OUTPUT;
  if (outputFile) {
    const output = [...platforms.map((key) => `${key}=${plan[key]}`), `apple_matrix=${JSON.stringify(plan.apple_matrix)}`].join('\n');
    appendFileSync(outputFile, `${output}\n`);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) runCli();
