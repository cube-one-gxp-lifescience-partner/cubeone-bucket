const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const readManifest = (name) => JSON.parse(fs.readFileSync(path.join(root, 'bucket', `${name}.json`), 'utf8'));
const desktop = readManifest('opencode-desktop');
const config = readManifest('opencode-cubeone');

test('Desktop keeps the upstream 2.2.6 download, hash, CLI and shortcut', () => {
    assert.equal(desktop.version, '2.2.6');
    assert.equal(desktop.architecture['64bit'].url, 'https://opencode.ai/files/bin/2.2.6/opencode-desktop-win-x64.exe#/dl.7z');
    assert.equal(desktop.architecture['64bit'].hash, 'ac52d2403711eee195924f7b5ac6d8609415bb07b9fff3b1206004a1f8a02906');
    assert.deepEqual(desktop.bin, [['resources\\opencode-cli.exe', 'opencode']]);
    assert.deepEqual(desktop.shortcuts, [['OpenCode.exe', 'OpenCode']]);
    assert.equal(desktop.autoupdate.architecture['64bit'].url, 'https://opencode.ai/files/bin/$version/opencode-desktop-win-x64.exe#/dl.7z');
});

test('Desktop contains no configuration download, installer or managed uninstaller', () => {
    assert.doesNotMatch(JSON.stringify(desktop), /cubeone|ProgramData|RequireManagedUpdate/i);
    assert.equal(desktop.uninstaller, undefined);
    assert.equal(desktop.installer.script.length, 3);
    assert.match(desktop.installer.script[0], /Expand-7zipArchive/);
});

test('configuration has its own matching version and a one-way Desktop dependency', () => {
    assert.equal(config.version, '1.1.21');
    assert.match(config.url, /\/opencode-cubeone-1\.1\.21\.zip$/);
    assert.equal(config.depends, 'opencode-desktop');
    assert.equal(desktop.depends, undefined);
    assert.equal(config.extract_to, undefined);
    assert.equal(config.bin, undefined);
    assert.equal(config.shortcuts, undefined);
    assert.match(config.hash, /^[a-f0-9]{64}$/);
    assert.doesNotMatch(JSON.stringify(config), /PLACEHOLDER|NOT READY FOR RELEASE/);
    const archive = fs.readFileSync(path.join(root, 'files', path.basename(config.url)));
    assert.equal(crypto.createHash('sha256').update(archive).digest('hex'), config.hash);
});

test('configuration installer uses the root scripts and requires successful managed updates', () => {
    const script = config.installer.script.join('\n');
    assert.match(script, /-File "\$dir\\Install-OpenCodeCubeOne\.ps1" -SourceDir "\$dir" -RequireManagedUpdate/);
    assert.match(script, /if \(\$LASTEXITCODE -ne 0\) \{\s+throw /);
    assert.doesNotMatch(script, /FullInstall|ssh|wsl|Remove-Item|catch/i);
});

test('configuration uninstall and update cannot delete managed or personal files', () => {
    assert.equal(config.uninstaller, undefined);
    assert.equal(config.pre_uninstall, undefined);
    assert.equal(config.post_uninstall, undefined);
    assert.equal(config.pre_install, undefined);
    assert.equal(config.post_install, undefined);
    assert.match(config.notes.join('\n'), /Personal files.*retained/);
});

test('migration documents the old uninstaller hazard and ordered forced reinstall', () => {
    const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8');
    assert.match(readme, /close OpenCode Desktop AND its server/);
    assert.match(readme, /old installed `uninstaller\.script`/);
    assert.match(readme, /scoop update opencode-desktop --force\s+scoop install opencode-cubeone/);
    assert.match(readme, /external auto-updater must explicitly include \*\*`opencode-cubeone`\*\*/);
    assert.doesNotMatch(readme, /scoop prefix opencode-desktop/);
    assert.match(readme, /\$source = scoop prefix opencode-cubeone/);
});
