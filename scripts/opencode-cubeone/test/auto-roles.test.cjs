const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

// The generator runs on synthetic catalog and endpoint files in a temporary directory. Nothing here touches the
// network, an API key or the installed configuration.
const root = path.resolve(__dirname, '..');
const generator = path.join(root, 'Update-OpenCodeModels.ps1');
const stripComments = (text) => text.split(/\r?\n/).filter((line) => !line.trimStart().startsWith('//')).join('\n');
const managed = JSON.parse(stripComments(fs.readFileSync(path.join(root, 'managed/opencode.jsonc'), 'utf8')));
const memory = JSON.parse(stripComments(fs.readFileSync(path.join(root, 'user/opencode-mem.jsonc'), 'utf8')));

const pwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' });
const skip = pwsh.status === 0 ? false : 'pwsh is not available';

const AUTO = 'openrouter/auto';
const EU_MODEL = 'mistralai/mistral-medium-3-5';
const SEARCH_ALIAS = '~openai/gpt-luna-latest';
const SEARCH_MODEL = 'openai/gpt-6-luna';
const US_ONLY_ALIAS = '~openai/gpt-sol-latest';
const US_ONLY_MODEL = 'openai/gpt-6.1-sol';
const SENTINEL = '// sentinel: a failed run must leave this file alone\n';
const ROLES = {
  orchestrator: 'intelligence',
  architect: 'intelligence',
  developer: 'balanced',
  reviewer: 'balanced',
  quick: 'cost',
  researcher: 'cost',
};
const TIERS = { balanced: 'medium', cost: 'low', intelligence: 'max' };

function catalogEntry(id, inputs, extra = {}) {
  return {
    id,
    name: `Vendor: ${id}`,
    context_length: 262144,
    architecture: { input_modalities: inputs },
    supported_parameters: ['tools', 'reasoning'],
    top_provider: { max_completion_tokens: 16384 },
    pricing: { prompt: '0.000001', completion: '0.000002' },
    ...extra,
  };
}

function endpoint(model, tag, extra = {}) {
  return {
    model_id: model,
    tag,
    safety_retention: false,
    supported_parameters: ['tools', 'temperature'],
    pricing: { prompt: '0.000001', completion: '0.000002', discount: 0 },
    ...extra,
  };
}

/** A catalog with one EU model that reads images and PDFs, a US-only model and the native search model. */
function fixture() {
  return {
    catalog: [
      catalogEntry(AUTO, ['text'], { name: 'Auto Router' }),
      catalogEntry(EU_MODEL, ['text', 'image', 'file']),
      catalogEntry(SEARCH_ALIAS, ['text', 'image', 'file'], { alias_target: { slug: SEARCH_MODEL } }),
      catalogEntry(SEARCH_MODEL, ['text', 'image', 'file']),
      catalogEntry(US_ONLY_ALIAS, ['text', 'image', 'file'], { alias_target: { slug: US_ONLY_MODEL } }),
      catalogEntry(US_ONLY_MODEL, ['text', 'image', 'file']),
    ],
    endpoints: [
      endpoint(EU_MODEL, 'mistral/eu'),
      endpoint(SEARCH_MODEL, 'azure/eu', { native_tools: { 'openrouter:web_search': true } }),
      endpoint(US_ONLY_MODEL, 'vendor/us'),
    ],
  };
}

function run(data) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cubeone-auto-roles-'));
  try {
    fs.writeFileSync(path.join(dir, 'catalog.json'), JSON.stringify({ data: data.catalog }));
    fs.writeFileSync(path.join(dir, 'zdr.json'), JSON.stringify({ data: data.endpoints }));
    const out = path.join(dir, 'managed.jsonc');
    fs.writeFileSync(out, SENTINEL);
    const result = spawnSync(
      'pwsh',
      ['-NoProfile', '-NonInteractive', '-File', generator, '-OutFile', out,
        '-CatalogFile', path.join(dir, 'catalog.json'), '-ZdrEndpointsFile', path.join(dir, 'zdr.json')],
      { encoding: 'utf8' },
    );
    const text = fs.readFileSync(out, 'utf8');
    return {
      status: result.status,
      output: `${result.stdout}\n${result.stderr}`,
      untouched: text === SENTINEL,
      config: result.status === 0 ? JSON.parse(stripComments(text)) : undefined,
    };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

const bodies = (entry) => [entry.body, ...entry.variants.map((variant) => variant.body)];

function assertRoles(config) {
  assert.equal(config.model, `openrouter-zdr/${AUTO}`);
  assert.ok(!config.model.includes('#'), 'the root model carries no variant');
  for (const [name, variant] of Object.entries(ROLES)) {
    assert.deepEqual(config.agents[name].model, { providerID: 'openrouter-zdr', model: AUTO, variant }, name);
  }
  assert.equal(config.agents.ask.model, undefined, 'Ask keeps inheriting the current model');
}

test('managed config: root model is Auto without a variant and the roles pick only a variant', () => {
  assertRoles(managed);
  assert.deepEqual(Object.keys(managed.agents).sort(), [...Object.keys(ROLES), 'ask'].sort());
  for (const name of Object.keys(managed.agents)) {
    assert.equal(managed.commands[name]?.model, undefined, `command ${name} adds no model override`);
  }
});

test('managed config: every variant of Auto repeats the EU and ZDR body with only the cost tier changed', () => {
  const auto = managed.providers['openrouter-zdr'].models[AUTO];
  assert.deepEqual(auto.variants.map((variant) => variant.id), ['balanced', 'cost', 'intelligence']);
  const [first] = bodies(auto);
  for (const body of bodies(auto)) {
    assert.deepEqual(body.plugins[0].allowed_models, first.plugins[0].allowed_models);
    assert.ok(body.plugins[0].allowed_models.length > 0);
    assert.deepEqual(body.provider, first.provider);
    assert.equal(body.provider.zdr, true);
    assert.equal(body.provider.data_collection, 'deny');
    assert.equal(body.provider.allow_fallbacks, false);
    assert.ok(body.provider.only.length > 0);
  }
  assert.deepEqual(
    bodies(auto).map((body) => body.plugins[0].cost_tier),
    ['medium', 'medium', 'low', 'max'],
  );
  for (const variant of auto.variants) {
    assert.equal(variant.body.plugins[0].cost_tier, TIERS[variant.id], variant.id);
  }
  assert.ok(auto.capabilities.input.includes('image') && auto.capabilities.input.includes('pdf'));
});

test('managed prompts equal the agent files (line endings aside) and name the Auto variants, not fixed models', () => {
  const lf = (text) => text.replace(/\r\n/g, '\n');
  for (const name of Object.keys(managed.agents)) {
    const file = lf(fs.readFileSync(path.join(root, 'agents', `${name}.md`), 'utf8')).trim();
    assert.equal(lf(managed.agents[name].system), file, name);
  }
  const prompt = lf(managed.agents.orchestrator.system);
  const expected = [
    ['architect', 'Intelligence'],
    ['researcher', 'Cost'],
    ['developer', 'Balanced'],
    ['quick', 'Cost'],
    ['reviewer', 'Balanced'],
  ];
  for (const [name, variant] of expected) {
    assert.ok(prompt.includes(`\`${name}\` (Auto (ZDR, EU), variant ${variant}`), `${name} label`);
  }
  for (const stale of ['Claude Opus', 'Claude Sonnet', 'Claude Haiku', 'GPT-6', 'zero-data-retention web search']) {
    assert.ok(!prompt.includes(stale), `stale label ${stale}`);
  }
});
test('managed config: websearch and the native search backend are unchanged', () => {
  assert.deepEqual(managed.websearch, { provider: 'cubeone-zdr' });
  const stt = managed.plugins.find((plugin) => plugin.package?.endsWith('cubeone-stt'));
  assert.equal(stt.options.search, true);
  assert.equal(stt.options.search_model, SEARCH_ALIAS);
  assert.equal(stt.options.search_endpoint, 'azure/eu');
  assert.equal(stt.options.model, 'mistralai/voxtral-mini-transcribe-3-0');
});

// Plugins are found by their package folder, never by their position in the list, so a new plugin cannot break these.
const pluginNamed = (config, name) => config.plugins.find((plugin) => (plugin.package ?? plugin).endsWith?.(`/${name}`));

test('managed config: the GUI-only ssh hosts plugin is listed once, with no options, and its folder exists', () => {
  const entries = managed.plugins.filter((plugin) => (plugin.package ?? plugin).endsWith?.('/cubeone-ssh-hosts'));
  assert.equal(entries.length, 1);
  assert.deepEqual(entries[0], { package: 'C:/ProgramData/opencode/cubeone/plugins/cubeone-ssh-hosts' });
  const folder = path.join(root, 'plugins', 'cubeone-ssh-hosts');
  assert.ok(fs.existsSync(path.join(folder, 'gui-experimental.cjs')));
  assert.equal(fs.existsSync(path.join(folder, 'server.js')), false, 'the plugin has no server part');
});

test('generator: writes the same ssh hosts plugin entry as the committed managed config', { skip }, () => {
  const result = run(fixture());
  assert.equal(result.status, 0, result.output);
  assert.deepEqual(pluginNamed(result.config, 'cubeone-ssh-hosts'), pluginNamed(managed, 'cubeone-ssh-hosts'));
  assert.deepEqual(
    result.config.plugins.map((plugin) => (plugin.package ?? plugin)).filter((name) => name.includes('/cubeone/plugins/')).sort(),
    managed.plugins.map((plugin) => (plugin.package ?? plugin)).filter((name) => name.includes('/cubeone/plugins/')).sort(),
    'the generator and the committed managed config list different cube one plugins',
  );
});

test('memory seed: Auto at the cost tier on the managed provider', () => {
  assert.equal(memory.opencodeProvider, 'openrouter-zdr');
  assert.equal(memory.opencodeModel, AUTO);
  assert.equal(memory.opencodeVariant, 'cost');
  const auto = managed.providers[memory.opencodeProvider].models[memory.opencodeModel];
  assert.ok(auto.variants.some((variant) => variant.id === memory.opencodeVariant));
});

test('generator: default model and roles come out as Auto with the role variants', { skip }, () => {
  const result = run(fixture());
  assert.equal(result.status, 0, result.output);
  assertRoles(result.config);
  assert.deepEqual(result.config.agents.researcher.model, { providerID: 'openrouter-zdr', model: AUTO, variant: 'cost' });
});

test('generator: Auto is limited to EU models with image and PDF input and every variant repeats that limit', { skip }, () => {
  const result = run(fixture());
  assert.equal(result.status, 0, result.output);
  const auto = result.config.providers['openrouter-zdr'].models[AUTO];
  for (const body of bodies(auto)) {
    assert.deepEqual([...body.plugins[0].allowed_models].sort(), [EU_MODEL, SEARCH_MODEL].sort());
    assert.ok(!body.plugins[0].allowed_models.includes(US_ONLY_MODEL), 'a model without an EU endpoint is not widened in');
    assert.deepEqual([...body.provider.only].sort(), ['azure/eu', 'mistral/eu']);
    assert.equal(body.provider.zdr, true);
    assert.equal(body.provider.data_collection, 'deny');
    assert.equal(body.provider.allow_fallbacks, false);
    assert.equal(body.provider.sort, 'price');
  }
  assert.deepEqual(
    auto.variants.map((variant) => [variant.id, variant.body.plugins[0].cost_tier]),
    [['balanced', 'medium'], ['cost', 'low'], ['intelligence', 'max']],
  );
  assert.equal(result.config.providers['openrouter-zdr'].body.provider.zdr, true);
});

test('generator: the native search backend does not depend on the chat model of the researcher', { skip }, () => {
  const result = run(fixture());
  assert.equal(result.status, 0, result.output);
  const stt = result.config.plugins.find((plugin) => plugin.package.endsWith('cubeone-stt'));
  assert.deepEqual(
    { search: stt.options.search, model: stt.options.search_model, endpoint: stt.options.search_endpoint },
    { search: true, model: SEARCH_ALIAS, endpoint: 'azure/eu' },
  );
  assert.deepEqual(result.config.websearch, { provider: 'cubeone-zdr' });
  assert.notEqual(result.config.agents.researcher.model.model, SEARCH_ALIAS);
});

test('generator: without native search the researcher is dropped and the other roles stay on Auto', { skip }, () => {
  const data = fixture();
  data.endpoints = data.endpoints.filter((entry) => entry.model_id !== SEARCH_MODEL);
  const result = run(data);
  assert.equal(result.status, 0, result.output);
  assert.equal(result.config.agents.researcher, undefined);
  assert.equal(result.config.websearch, false);
  assert.equal(result.config.agents.developer.model.model, AUTO);
});

const failClosed = [
  ['the router is missing from the catalog', (data) => {
    data.catalog = data.catalog.filter((entry) => entry.id !== AUTO);
  }],
  ['no model has an EU endpoint', (data) => {
    data.endpoints = data.endpoints.map((entry) => ({ ...entry, tag: 'vendor/us' }));
  }],
  ['the only EU models take no PDF', (data) => {
    data.catalog = data.catalog.map((entry) => ({ ...entry, architecture: { input_modalities: ['text', 'image'] } }));
  }],
  ['the only EU models take no image', (data) => {
    data.catalog = data.catalog.map((entry) => ({ ...entry, architecture: { input_modalities: ['text', 'file'] } }));
  }],
  ['the EU endpoints keep Safety Retention', (data) => {
    data.endpoints = data.endpoints.map((entry) => ({ ...entry, safety_retention: true }));
  }],
  ['the EU endpoints have no tool support', (data) => {
    data.endpoints = data.endpoints.map((entry) => ({ ...entry, supported_parameters: ['temperature'] }));
  }],
];
for (const [name, change] of failClosed) {
  test(`generator fails closed and writes nothing when ${name}`, { skip }, () => {
    const data = fixture();
    change(data);
    const result = run(data);
    assert.notEqual(result.status, 0, 'the run must fail');
    assert.ok(result.untouched, 'no config may be written');
    assert.ok(result.output.includes('could not be built'), result.output);
  });
}

test('generator never falls back to the old Sonnet alias or to SALE when Auto is missing', { skip }, () => {
  const data = fixture();
  data.catalog.push(
    catalogEntry('~anthropic/claude-sonnet-latest', ['text', 'image', 'file'], { alias_target: { slug: 'anthropic/claude-sonnet-5.5' } }),
    catalogEntry('anthropic/claude-sonnet-5.5', ['text', 'image', 'file']),
  );
  data.endpoints.push(endpoint('anthropic/claude-sonnet-5.5', 'amazon-bedrock/eu-west-1'));
  data.catalog = data.catalog.filter((entry) => entry.id !== AUTO);
  const result = run(data);
  assert.notEqual(result.status, 0);
  assert.ok(result.untouched);
});
