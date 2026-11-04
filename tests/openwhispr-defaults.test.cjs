const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '../bucket/openwhispr.json'), 'utf8'));
const start = manifest.post_install.indexOf("$defaultsSource = @'") + 1;
const end = manifest.post_install.indexOf("'@", start);
assert.ok(start > 0 && end > start);
const source = manifest.post_install.slice(start, end).join('\n');
const unpack = (archive) => {
  const bodyOffset = 8 + archive.readUInt32LE(4);
  const header = JSON.parse(archive.subarray(16, 16 + archive.readUInt32LE(12)));
  const entry = header.files['preload.js'];
  return { header, text: archive.subarray(bodyOffset + Number(entry.offset), bodyOffset + Number(entry.offset) + entry.size).toString() };
};
const fixture = (seedPrefix = '') => {
  const preload = Buffer.from(seedPrefix + 'globalThis.originalPreloadRan = true;');
  const header = { files: { 'preload.js': { offset: '0', size: preload.length, integrity: { algorithm: 'SHA256', blockSize: 16, hash: '', blocks: [] } }, 'untouched.txt': { offset: String(preload.length), size: 4 } } };
  const json = Buffer.from(JSON.stringify(header));
  const padded = Math.ceil(json.length / 4) * 4;
  const prefix = Buffer.alloc(16 + padded);
  prefix.writeUInt32LE(4, 0);
  prefix.writeUInt32LE(8 + padded, 4);
  prefix.writeUInt32LE(4 + padded, 8);
  prefix.writeUInt32LE(json.length, 12);
  json.copy(prefix, 16);
  return Buffer.concat([prefix, preload, Buffer.from('KEEP')]);
};
const patch = (archivePath) => vm.runInNewContext(source, { require, Buffer, process: { argv: ['node', 'defaults.cjs', archivePath] }, console: { log() {} } });
const withArchive = (context, callback) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'openwhispr-defaults-test-'));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const archivePath = path.join(directory, 'app.asar');
  fs.writeFileSync(archivePath, fixture());
  patch(archivePath);
  callback(archivePath);
};

test('fresh renderer receives current preferences before the original preload', (context) => {
  withArchive(context, (archivePath) => {
    const values = new Map();
    const localStorage = { get length() { return values.size; }, setItem(key, value) { values.set(key, value); } };
    const renderer = { localStorage, console };
    vm.runInNewContext(unpack(fs.readFileSync(archivePath)).text, renderer);
    assert.equal(renderer.originalPreloadRan, true);
    assert.equal(values.get('transcriptionMode'), 'local');
    assert.equal(values.get('useLocalWhisper'), 'true');
    assert.equal(values.get('localTranscriptionProvider'), 'nvidia');
    assert.equal(values.get('parakeetModel'), 'orukeet-v0.1.0');
    assert.equal(values.get('dictationKey'), 'RightControl');
    assert.equal(values.get('cleanupProvider'), 'openrouter');
    assert.equal(values.get('cleanupModel'), '~anthropic/claude-haiku-latest');
    assert.equal(values.get('useDictationAgent'), 'false');
    assert.equal(values.get('enterpriseSetupMode'), 'manual');
    assert.equal(values.get('autoUpdatesEnabled'), 'false');
    assert.equal(values.get('onboardingCompleted'), 'true');
    assert.equal(values.get('authenticationSkipped'), 'true');
    assert.equal(values.get('skipAuth'), 'true');
    assert.ok(![...values.keys()].some((key) => /api.?key|token|secret/i.test(key)));
    const snapshot = [...values];
    vm.runInNewContext(unpack(fs.readFileSync(archivePath)).text, renderer);
    assert.deepEqual([...values], snapshot);
  });
});

test('existing profiles remain untouched, including deliberately missing preferences', (context) => {
  withArchive(context, (archivePath) => {
    const values = new Map([['onboardingCompleted', 'true'], ['dictationKey', 'F8']]);
    const localStorage = { get length() { return values.size; }, setItem(key, value) { values.set(key, value); } };
    vm.runInNewContext(unpack(fs.readFileSync(archivePath)).text, { localStorage, console });
    assert.deepEqual([...values], [['onboardingCompleted', 'true'], ['dictationKey', 'F8']]);
  });
});

test('archive patch preserves other files, updates integrity and is idempotent', (context) => {
  withArchive(context, (archivePath) => {
    const first = fs.readFileSync(archivePath);
    const { header, text } = unpack(first);
    const bodyOffset = 8 + first.readUInt32LE(4);
    const other = header.files['untouched.txt'];
    assert.equal(first.subarray(bodyOffset + Number(other.offset), bodyOffset + Number(other.offset) + other.size).toString(), 'KEEP');
    const integrity = header.files['preload.js'].integrity;
    assert.equal(integrity.hash, crypto.createHash('sha256').update(text).digest('hex'));
    const bytes = Buffer.from(text);
    for (let offset = 0; offset < bytes.length; offset += integrity.blockSize) {
      assert.equal(integrity.blocks[offset / integrity.blockSize], crypto.createHash('sha256').update(bytes.subarray(offset, offset + integrity.blockSize)).digest('hex'));
    }
    patch(archivePath);
    assert.deepEqual(fs.readFileSync(archivePath), first);
  });
});

test('upgrade replaces the earlier seed rather than stacking preloads', (context) => {
  withArchive(context, (archivePath) => {
    const legacy = '// cubeone-openwhispr-defaults-v1\n(() => {\n  globalThis.legacySeedRan = true;\n})();\n';
    fs.writeFileSync(archivePath, fixture(legacy));
    patch(archivePath);
    const text = unpack(fs.readFileSync(archivePath)).text;
    assert.ok(!text.includes('cubeone-openwhispr-defaults-v1'));
    const values = new Map();
    const renderer = { localStorage: { get length() { return values.size; }, setItem(key, value) { values.set(key, value); } }, console };
    vm.runInNewContext(text, renderer);
    assert.equal(renderer.legacySeedRan, undefined);
    assert.equal(renderer.originalPreloadRan, true);
    assert.equal(values.get('onboardingCompleted'), 'true');
    const first = fs.readFileSync(archivePath);
    patch(archivePath);
    assert.deepEqual(fs.readFileSync(archivePath), first);
  });
});

test('unavailable browser storage does not break the original preload', (context) => {
  withArchive(context, (archivePath) => {
    let warned = false;
    const renderer = { console: { warn() { warned = true; } } };
    vm.runInNewContext(unpack(fs.readFileSync(archivePath)).text, renderer);
    assert.equal(warned, true);
    assert.equal(renderer.originalPreloadRan, true);
  });
});

test('manifest uses the application runtime and matches first-start hotkey', () => {
  const hook = manifest.post_install.join('\n');
  assert.ok(hook.includes("$env:ELECTRON_RUN_AS_NODE = '1'"));
  assert.ok(hook.includes('$env:ELECTRON_RUN_AS_NODE = $savedRunAsNode'));
  assert.ok(hook.includes('DICTATION_KEY=RightControl'));
  assert.ok(!hook.includes('$envText ='));
});
