import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import vm from 'node:vm';

const html = readFileSync(new URL('../docs/join.html', import.meta.url), 'utf8');
const script = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)]
  .map(match => match[1]).find(source => source.includes('function parseDeepLink'));

function loadPage({readyState = 'complete', qr = true, language = 'en', clipboard} = {}) {
  const elements = new Map();
  function element() {
    const classes = new Set();
    return {
      innerHTML: '', innerText: '', textContent: '', hidden: true, value: '',
      classList: {
        toggle(name, enabled) { enabled ? classes.add(name) : classes.delete(name); },
        add(name) { classes.add(name); }, remove(name) { classes.delete(name); },
        contains(name) { return classes.has(name); },
      },
      setAttribute(name, value) { this[name] = value; },
      querySelector() { return {setAttribute() {}}; },
      appendChild() {}, insertBefore() {},
      focus() { this.focused = true; }, select() { this.selected = true; },
    };
  }
  const get = id => {
    if (!elements.has(id)) elements.set(id, element());
    return elements.get(id);
  };
  const events = new Map();
  const document = {readyState, documentElement: {lang: 'en'}, getElementById: get,
    querySelector: () => get('action-group')};
  const location = new URL('https://bvolpato.github.io/brutv/join.html#server=https%3A%2F%2Fexample.invalid&username=fixture&password=synthetic');
  const encoded = [];
  const sandbox = {document, URLSearchParams, navigator: {language, userAgent: 'Desktop', clipboard},
    location, setTimeout() {}, addEventListener: (name, callback) => events.set(name, callback)};
  sandbox.window = sandbox;
  if (qr) sandbox.qrcode = () => ({addData: data => encoded.push(data), make() {}, createSvgTag: () => '<svg></svg>'});
  const context = vm.createContext(sandbox);
  vm.runInContext(script, context);
  return {context, get, events, encoded, document};
}

test('initializes after DOMContentLoaded has already fired', () => {
  const page = loadPage();
  const link = new URL(page.get('btn-open-app').href);
  assert.equal(link.protocol, 'brutv:');
  assert.equal(link.searchParams.get('password'), 'synthetic');
  assert.deepEqual(page.encoded, [link.href]);
  assert.equal(page.get('lang-en').classList.contains('active'), true);
});

test('ignores query credentials and reads sign-in details from the fragment', () => {
  const page = loadPage();
  page.context.location = new URL('https://bvolpato.github.io/brutv/join.html?server=https%3A%2F%2Fexample.invalid&username=fixture&password=synthetic');
  assert.equal(page.context.parseDeepLink(), 'brutv://login');

  page.context.location.hash = 'm3u=https%3A%2F%2Fexample.invalid%2Fplaylist.m3u';
  const link = new URL(page.context.parseDeepLink());
  assert.equal(link.searchParams.get('m3u'), 'https://example.invalid/playlist.m3u');
  assert.equal(link.searchParams.has('password'), false);
});

test('waits for DOM readiness when the script loads during parsing', () => {
  const page = loadPage({readyState: 'loading'});
  assert.equal(page.encoded.length, 0);
  page.events.get('DOMContentLoaded')();
  assert.equal(page.encoded.length, 1);
});

test('QR generator failure offers a local fallback without an image request', () => {
  const page = loadPage({qr: false, language: 'pt-BR'});
  assert.equal(page.get('qr-code').innerHTML, '');
  assert.match(page.get('qr-code').textContent, /copie/i);
  assert.equal(page.document.documentElement.lang, 'pt-BR');
  assert.match(page.get('btn-open-app').href, /^brutv:\/\/login/);
});

test('copies the sign-in link only after the clipboard accepts it', async () => {
  let copied;
  const page = loadPage({clipboard: {writeText: async value => { copied = value; }}});
  await page.context.copySetupLink();
  assert.equal(copied, page.get('btn-open-app').href);
  assert.match(page.get('toast').innerText, /copied to clipboard/i);
});

test('clipboard denial selects a manual copy field without claiming success', async () => {
  const page = loadPage({clipboard: {writeText: async () => { throw new Error('NotAllowedError'); }}});
  await page.context.copySetupLink();
  const input = page.get('manual-link');
  assert.equal(input.value, page.get('btn-open-app').href);
  assert.equal(input.hidden, false);
  assert.equal(input.selected, true);
  assert.doesNotMatch(page.get('toast').innerText, /copied/i);
});
