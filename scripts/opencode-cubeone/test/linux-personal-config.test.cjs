const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const installer = fs.readFileSync(path.join(__dirname, '../Install-OpenCodeRemote.ps1'), 'utf8');
const python = installer.match(/python3 - "\$USER_CONFIG" "\$STAGE\/user\/opencode\.jsonc" <<'PY'[^\n]*\n([\s\S]*?)\nPY/)[1];
const bash = (() => {
  if (process.platform !== 'win32') return 'bash';
  const git = spawnSync('git', ['--exec-path'], { encoding: 'utf8' });
  if (git.status === 0) {
    const gitBash = path.resolve(git.stdout.trim(), '../../..', 'bin', 'bash.exe');
    if (fs.existsSync(gitBash)) return gitBash;
  }
  return path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe');
})();
const toPosix = (file) => process.platform === 'win32' ? file.replace(/\\/g, '/').replace(/^([A-Za-z]):/, (_, drive) => '/' + drive.toLowerCase()) : file;

function fixture(context, original) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cubeone-mcp-merge-'));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const destination = path.join(directory, 'opencode.jsonc');
  const template = path.join(directory, 'template.jsonc');
  fs.writeFileSync(destination, original);
  fs.writeFileSync(template, JSON.stringify({ mcp: { servers: { trace: { type: 'remote', url: 'https://trace.example/mcp' }, custom: { url: 'https://template.example/mcp' } } } }));
  return { directory, destination, template };
}
function merge(files) {
  return spawnSync('python3', ['-c', python, files.destination, files.template], { encoding: 'utf8' });
}

test('Linux merge preserves BOM, escaped strings, URLs, permissions and personal MCP entries', (context) => {
  const files = fixture(context, '\ufeff{/* c */ "literal":"literal,}","array":"x,]","escaped":"a\\\"b\\\\c", // line\n"mcp":{"servers":{"custom":{"url":"https://personal.example/mcp"},},},}');
  const before = fs.statSync(files.destination);
  const originalBytes = fs.readFileSync(files.destination);
  const result = merge(files);
  assert.equal(result.status, 0, result.error?.message ?? result.stderr);
  const current = JSON.parse(fs.readFileSync(files.destination, 'utf8'));
  assert.equal(current.literal, 'literal,}');
  assert.equal(current.array, 'x,]');
  assert.equal(current.escaped, 'a"b\\c');
  assert.equal(current.mcp.servers.custom.url, 'https://personal.example/mcp');
  assert.equal(current.mcp.servers.trace.url, 'https://trace.example/mcp');
  const after = fs.statSync(files.destination);
  assert.equal(after.ino, before.ino);
  assert.equal(after.mode, before.mode);
  assert.equal(after.uid, before.uid);
  const backups = fs.readdirSync(files.directory).filter((name) => name.includes('.bak-cubeone-mcp-'));
  assert.equal(backups.length, 1);
  assert.deepEqual(fs.readFileSync(path.join(files.directory, backups[0])), originalBytes);
  const first = fs.readFileSync(files.destination);
  const second = merge(files);
  assert.equal(second.status, 0, second.error?.message ?? second.stderr);
  assert.deepEqual(fs.readFileSync(files.destination), first);
  assert.equal(fs.readdirSync(files.directory).filter((name) => name.includes('.bak-cubeone-mcp-')).length, 1);
});

test('Linux merge adds missing structures but malformed configuration remains byte-for-byte unchanged', (context) => {
  for (const original of ['{}', '{"name":"hello"}']) {
    const files = fixture(context, original);
    const result = merge(files);
    assert.equal(result.status, 0, result.error?.message ?? result.stderr);
    assert.equal(JSON.parse(fs.readFileSync(files.destination)).mcp.servers.trace.url, 'https://trace.example/mcp');
  }
  for (const original of ['', '{', '[]', '{"mcp":"invalid"}', '{"mcp":{"servers":[]}}', '{/* unterminated']) {
    const files = fixture(context, original);
    const result = merge(files);
    assert.equal(result.error, undefined, result.error?.message ?? result.stderr);
    assert.notEqual(result.status, 0);
    assert.equal(fs.readFileSync(files.destination, 'utf8'), original);
    assert.equal(fs.readdirSync(files.directory).filter((name) => name.includes('.bak-cubeone-mcp-')).length, 0);
    assert.ok(!result.stderr.includes(original) || original.length < 2);
  }
});

test('Linux merge without Python keeps the existing personal file', (context) => {
  const files = fixture(context, '{"personal":"unchanged"}');
  const section = installer.slice(installer.indexOf('USER_CONFIG="$HOME_DIR/'), installer.indexOf('if [ ! -e "$HOME_DIR/.config/opencode/vorgaben/design.md"'));
  const configDir = path.join(files.directory, '.config', 'opencode');
  fs.mkdirSync(configDir, { recursive: true });
  const user = path.join(configDir, 'opencode.jsonc');
  fs.writeFileSync(user, '{"personal":"unchanged"}');
  fs.mkdirSync(path.join(files.directory, 'user'));
  fs.copyFileSync(files.template, path.join(files.directory, 'user', 'opencode.jsonc'));
  const script = 'set -eu\ncommand() { return 1; }\nHOME_DIR="$TEST_HOME"\nSTAGE="$TEST_HOME"\n' + section;
  const result = spawnSync(bash, ['-s'], { input: script, encoding: 'utf8', env: { ...process.env, TEST_HOME: toPosix(files.directory) } });
  assert.equal(result.status, 0, result.error?.message ?? result.stderr);
  assert.match(result.stderr, /python3 unavailable/);
  assert.equal(fs.readFileSync(user, 'utf8'), '{"personal":"unchanged"}');
});

test('Linux managed write failure aborts without falling back onto personal configuration', (context) => {
  const files = fixture(context, 'personal sentinel');
  const section = installer.slice(installer.indexOf('ROOT=/etc/opencode'), installer.indexOf('copy_tree() {'));
  assert.ok(section.includes('exit 1'));
  assert.ok(!section.includes('ROOT="$HOME_DIR'));
  const script = 'set -eu\nid() { printf 123; }\nmkdir() { return 1; }\ncommand() { return 1; }\n' + section;
  const result = spawnSync(bash, ['-s'], { input: script, encoding: 'utf8' });
  assert.equal(result.error, undefined, result.error?.message ?? result.stderr);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /personal configuration was not changed/);
  assert.equal(fs.readFileSync(files.destination, 'utf8'), 'personal sentinel');
});
