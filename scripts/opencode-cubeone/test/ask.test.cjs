const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { test } = require('node:test');
const root = path.resolve(__dirname, '..');
const config = JSON.parse(fs.readFileSync(path.join(root, 'managed/opencode.jsonc'), 'utf8').replace(/^\/\/[^\r\n]*\r?\n/gm, ''));
const source = fs.readFileSync(path.join(root, 'Update-OpenCodeModels.ps1'), 'utf8');
// A Windows checkout turns the agent prompts into CRLF files, so line endings are not part of the comparison.
const lf = (text) => text.replace(/\r\n/g, '\n');

test('/ask selects a persistent primary agent and keeps the current model', () => {
  assert.equal(config.commands.ask.agent, 'ask');
  assert.equal(config.commands.ask.subagent, false);
  assert.ok(config.commands.ask.template.includes('$ARGUMENTS'));
  assert.ok(!config.commands.ask.template.includes('!`'));
  assert.equal(config.agents.ask.mode, 'primary');
  assert.equal(config.agents.ask.model, undefined);
  assert.equal(config.commands.ask.model, undefined);
  assert.equal(lf(config.agents.ask.system), lf(fs.readFileSync(path.join(root, 'agents/ask.md'), 'utf8')).trim());
});

test('Ask is deny-by-default with only inspection tools allowed', () => {
  const rules = config.agents.ask.permissions;
  assert.deepEqual(rules[0], { action: '*', resource: '*', effect: 'deny' });
  const allowed = rules.filter(rule => rule.effect === 'allow').map(rule => rule.action).sort();
  assert.deepEqual(allowed, ['external_directory', 'glob', 'grep', 'question', 'read', 'skill', 'webfetch', 'websearch']);
  assert.ok(rules.some(rule => rule.action === 'read' && rule.resource === '*.env' && rule.effect === 'deny'));
  assert.ok(rules.some(rule => rule.action === 'read' && rule.resource === '*.env.*' && rule.effect === 'deny'));
  for (const action of ['edit', 'shell', 'subagent', 'execute', 'cube_note_create_document', 'unknown_future_tool']) {
    const last = rules.filter(rule => rule.action === '*' || rule.action === action).at(-1);
    assert.equal(last.effect, 'deny', action);
  }
});

test('offline generator reproduces agent and command definitions without changing other agents', () => {
  const agents = source.slice(source.indexOf('$Agents = [ordered]@{'), source.indexOf('\nfunction Test-EuTag'));
  const generator = source.slice(source.indexOf('$agentConfig = [ordered]@{}'), source.indexOf('\n$PipelineCommand'));
  const commands = source.slice(source.indexOf('    commands     = [ordered]@{'), source.indexOf('    agents       = $agentConfig'));
  const script = `$ProviderId = 'openrouter-zdr'; $AutoRouterModel = 'openrouter/auto'; $DefaultModel = $AutoRouterModel; $SearchModel = '~openai/gpt-luna-latest'; $searchReady = $true; $ReadOnly = @(); $models = [ordered]@{ 'openrouter/auto' = @{ variants = @(@{ id = 'balanced' }, @{ id = 'cost' }, @{ id = 'intelligence' }) } }; $AgentRoot = '${path.join(root, 'agents').replaceAll("'", "''")}';\n${agents}\n${generator}\n$config = [ordered]@{\n${commands}\n}; [ordered]@{ agents = $agentConfig; commands = $config.commands } | ConvertTo-Json -Depth 30 -Compress`;
  const generated = JSON.parse(execFileSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', script], { encoding: 'utf8' }));
  assert.deepEqual({ ...generated.agents.ask, system: lf(generated.agents.ask.system) }, { ...config.agents.ask, system: lf(config.agents.ask.system) });
  assert.deepEqual(generated.commands.ask, config.commands.ask);
  for (const name of ['orchestrator', 'architect', 'researcher', 'developer', 'quick', 'reviewer']) {
    assert.deepEqual(generated.agents[name].model, config.agents[name].model);
  }
  assert.equal(generated.agents.ask.model, undefined);
});
