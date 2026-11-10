const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const readManifest = (name) => JSON.parse(fs.readFileSync(path.join(root, 'bucket', `${name}.json`), 'utf8'));
const desktop = readManifest('opencode-desktop');
const config = readManifest('opencode-cubeone');

test('Desktop keeps the upstream download, hash, CLI and shortcut', () => {
    assert.match(desktop.version, /^\d+\.\d+\.\d+$/);
    assert.equal(desktop.architecture['64bit'].url, `https://opencode.ai/files/bin/${desktop.version}/opencode-desktop-win-x64.exe#/dl.7z`);
    assert.match(desktop.architecture['64bit'].hash, /^[a-f0-9]{64}$/);
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
    assert.match(config.version, /^\d+\.\d+\.\d+$/);
    assert.ok(config.url.endsWith(`/opencode-cubeone-${config.version}.zip`));
    assert.equal(config.depends, 'opencode-desktop');
    assert.equal(desktop.depends, undefined);
    assert.equal(config.extract_to, undefined);
    assert.equal(config.bin, undefined);
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

test('builder packs the VM tunnel scripts with their shared helper', () => {
    const builder = fs.readFileSync(path.join(root, 'scripts', 'opencode-cubeone', 'Build-OpenCodeCubeOne.ps1'), 'utf8');
    for (const name of ['OpenCodeVmCommon.ps1', 'Start-OpenCodeWindowsVm.ps1', 'Maintain-OpenCodeWindowsVm.ps1']) {
        assert.ok(builder.includes(`'${name}'`), name);
        assert.ok(fs.existsSync(path.join(root, 'scripts', 'opencode-cubeone', name)), name);
    }
});

test('the auto pin plugin is configured, packed and installed on every path', () => {
    const base = path.join(root, 'scripts', 'opencode-cubeone');
    const read = (name) => fs.readFileSync(path.join(base, name), 'utf8');
    assert.ok(fs.existsSync(path.join(base, 'plugins', 'cubeone-auto-pin', 'server.js')));
    assert.match(read('managed/opencode.jsonc'), /plugins\/cubeone-auto-pin"/);
    for (const name of ['Build-OpenCodeCubeOne.ps1', 'Install-OpenCodeCubeOne.ps1', 'Install-OpenCodeRemote.ps1', 'Update-OpenCodeModels.ps1']) {
        assert.ok(read(name).includes('cubeone-auto-pin'), name);
    }
});

test('Start menu shortcut launches the packed tunnel script and its window stays open', () => {
    assert.equal(config.shortcuts.length, 1);
    const [target, name, args] = config.shortcuts[0];
    assert.match(target, /\\WindowsPowerShell\\v1\.0\\powershell\.exe$/);
    assert.equal(name, 'OpenCode VM verbinden');
    assert.match(args, /-File "\$dir\\Start-OpenCodeWindowsVm\.ps1"$/);
    assert.doesNotMatch(args, /-NoExit|-WindowStyle|-NoPause/);
    const script = fs.readFileSync(path.join(root, 'scripts', 'opencode-cubeone', 'Start-OpenCodeWindowsVm.ps1'), 'utf8');
    assert.match(script, /\[switch\]\$NoPause/);
    assert.match(script, /Read-Host 'Enter druecken zum Schliessen'/);
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
