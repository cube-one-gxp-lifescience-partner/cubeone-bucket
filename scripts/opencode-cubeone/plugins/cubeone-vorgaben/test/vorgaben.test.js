import assert from "node:assert/strict"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"
import plugin, { curatedModels, disableUncurated, loadAlways, loadRules, readDisabled } from "../server.js"
import { applicable, globToRegExp, parseAlwaysRule, touched, visibleRules } from "../vorgaben.js"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..")
const dirs = [path.join(root, "managed", "vorgaben"), path.join(root, "user", "vorgaben")]
const project = path.resolve("/projekt")
const rules = loadRules(dirs)
const ids = (files, text = "") => applicable(rules, files.map((file) => path.join(project, file)), text, project).map((hit) => hit.rule.id).sort()

test("the shipped rules all load", () => {
  assert.deepEqual(rules.map((rule) => rule.id).sort(), [
    "bash",
    "csharp",
    "docker",
    "gitlab-ci",
    "html-css",
    "java",
    "javascript",
    "mcp",
    "oidc",
    "php",
    "powershell",
    "python",
    "r",
    "sicherheit",
    "sql",
    "vba",
  ])
})

test("globs", () => {
  assert.ok(globToRegExp("**/*.{tsx,vue,svelte,css}").test("src/ui/Button.tsx"))
  assert.ok(globToRegExp("**/*.{tsx,vue,svelte,css}").test("Button.tsx"))
  assert.ok(!globToRegExp("**/*.{tsx,vue,svelte,css}").test("src/ui/Button.ts"))
  assert.ok(globToRegExp("**/*auth*").test("src/auth"))
})

test("a file gets only the rule whose glob matches it", () => {
  assert.deepEqual(ids(["src/app.py"]), ["python"])
  assert.deepEqual(ids(["db/schema.sql"]), ["sicherheit", "sql"])
  assert.deepEqual(ids([".gitlab-ci.yml"]), ["gitlab-ci"])
  assert.deepEqual(ids(["src/auth/callback.ts"]), ["oidc"])
})

test("folders above the project do not count", () => {
  const outside = path.resolve("/repos/oauth-demo")
  assert.deepEqual(applicable(rules, [path.join(outside, "README.md")], "", path.join(outside, "app")).map((hit) => hit.rule.id), [])
  assert.deepEqual(applicable(rules, [path.join(project, "README.md")], "", project), [])
})

test("apply_patch files and added lines", () => {
  const patch = "*** Begin Patch\n*** Update File: src/auth/token.ts\n@@\n-old\n+const issuer = 'https://id'\n*** Add File: src/ui/Card.vue\n+<template/>\n*** End Patch"
  const result = touched("apply_patch", { patchText: patch })
  assert.deepEqual(result.files, ["src/auth/token.ts", "src/ui/Card.vue"])
  assert.match(result.written, /issuer/)
  assert.doesNotMatch(result.written, /old/)
})

test("visible rules come from the full block only", () => {
  assert.deepEqual([...visibleRules([{ text: "--- cubeone-vorgabe:oidc | x ---" }, { text: "(cubeone-verweis:design ...)" }])], ["oidc"])
})

function harness(extraOptions = {}) {
  const hooks = {}
  const ctx = {
    options: { dirs, ...extraOptions },
    location: { directory: project },
    session: {
      get: async () => ({ location: { directory: project } }),
      hook: async (name, callback) => (hooks[name] = callback),
    },
    tool: { hook: async (name, callback) => (hooks[name] = callback) },
  }
  return { ctx, hooks }
}

test("first change without the rule is stopped once, with the rule", async () => {
  const { ctx, hooks } = harness()
  await plugin.setup(ctx)
  await hooks.context({ sessionID: "s1", messages: [] })
  const call = { tool: "write", sessionID: "s1", input: { path: path.join(project, "src/app.py"), content: "x" } }
  await assert.rejects(hooks["execute.before"]({ ...call }), (error) => {
    assert.match(error.message, /cubeone-vorgabe:python/)
    assert.match(error.message, /PEP 8/)
    assert.doesNotMatch(error.message, /SQLFluff/)
    return true
  })
  await hooks["execute.before"]({ ...call })
})

test("a read appends the rule once, then a reference", async () => {
  const { ctx, hooks } = harness()
  await plugin.setup(ctx)
  await hooks.context({ sessionID: "s2", messages: [] })
  const read = () => ({
    tool: "read",
    sessionID: "s2",
    status: "completed",
    input: { path: path.join(project, "db/schema.sql") },
    result: { content: "select 1" },
  })
  const first = read()
  await hooks["execute.after"](first)
  assert.match(first.result.content, /cubeone-vorgabe:sql/)
  assert.match(first.result.content, /SQLFluff/)
  assert.doesNotMatch(first.result.content, /PEP 8/)
  const second = read()
  await hooks["execute.after"](second)
  assert.match(second.result.content, /cubeone-verweis:sql/)
  assert.doesNotMatch(second.result.content, /SQLFluff/)

  const compacted = { sessionID: "s2", messages: [{ text: "compacted summary" }] }
  await hooks.context(compacted)
  assert.match(compacted.system[0].text, /cubeone-vorgabe:sql/)
  assert.match(compacted.system[0].text, /SQLFluff/)
  const third = read()
  await hooks["execute.after"](third)
  assert.match(third.result.content, /cubeone-verweis:sql/)
  assert.doesNotMatch(third.result.content, /SQLFluff/)
})

test("a stopped edit still puts the rule into the next turn when the error is gone", async () => {
  const { ctx, hooks } = harness()
  await plugin.setup(ctx)
  await hooks.context({ sessionID: "s3", messages: [] })
  const call = { tool: "edit", sessionID: "s3", input: { path: path.join(project, "src/app.py"), content: "x" } }
  await assert.rejects(hooks["execute.before"](call), /cubeone-vorgabe:python/)
  const next = { sessionID: "s3", messages: [{ text: "the tool failed" }] }
  await hooks.context(next)
  assert.match(next.system[0].text, /cubeone-vorgabe:python/)
  assert.match(next.system[0].text, /PEP 8/)
  await hooks["execute.before"](call)
})

test("parseAlwaysRule takes the title from the first heading, else falls back to the id", () => {
  const withHeading = parseAlwaysRule("kundenrechner", "# Kundenrechner\n\nText.")
  assert.equal(withHeading.title, "Kundenrechner")
  assert.match(withHeading.body, /# Kundenrechner/)
  const withoutHeading = parseAlwaysRule("x", "Nur Text, keine Überschrift.")
  assert.equal(withoutHeading.title, "x")
  assert.equal(parseAlwaysRule("leer", "   \n\n  "), undefined)
})

function tempDir() {
  return mkdtempSync(path.join(os.tmpdir(), "vorgaben-test-"))
}

test("loadAlways reads every .md file in the one folder it is given", () => {
  const dir = tempDir()
  try {
    writeFileSync(path.join(dir, "a.md"), "# A\n\nEins.")
    writeFileSync(path.join(dir, "b.md"), "Zwei, ohne Überschrift.")
    writeFileSync(path.join(dir, "c.txt"), "wird ignoriert")
    assert.deepEqual(loadAlways(dir).map((rule) => rule.id).sort(), ["a", "b"])
    assert.deepEqual(loadAlways(undefined), [])
    assert.deepEqual(loadAlways(path.join(dir, "fehlt-nicht")), [])
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("readDisabled lowercases ids and tolerates a missing or broken file", () => {
  const dir = tempDir()
  try {
    const file = path.join(dir, "deaktiviert.json")
    writeFileSync(file, JSON.stringify({ disabled: ["Design", "paketinstallation"] }))
    assert.deepEqual([...readDisabled(file)].sort(), ["design", "paketinstallation"])
    assert.deepEqual(readDisabled(path.join(dir, "fehlt.json")), new Set())
    assert.deepEqual(readDisabled(undefined), new Set())
    writeFileSync(file, "kein json")
    assert.deepEqual(readDisabled(file), new Set())
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("an always rule reaches the system prompt every turn, and a disabled one does not", async () => {
  const alwaysDir = tempDir()
  const stateDir = tempDir()
  const disabledFile = path.join(stateDir, "deaktiviert.json")
  try {
    writeFileSync(path.join(alwaysDir, "kundenrechner.md"), "# Kundenrechner\n\nNichts Verdächtiges auf WKS-Rechnern.")
    const { ctx, hooks } = harness({ rulesOptional: alwaysDir, disabledFile })
    await plugin.setup(ctx)
    const on = { sessionID: "always-on", messages: [] }
    await hooks.context(on)
    assert.match(on.system[0].text, /Kundenrechner/)

    writeFileSync(disabledFile, JSON.stringify({ disabled: ["kundenrechner"] }))
    const off = { sessionID: "always-off", messages: [] }
    await hooks.context(off)
    assert.equal(off.system, undefined)
  } finally {
    rmSync(alwaysDir, { recursive: true, force: true })
    rmSync(stateDir, { recursive: true, force: true })
  }
})

test("a managed vorgabe cannot be disabled even if its id appears in the disabled file", async () => {
  const dir = tempDir()
  const disabledFile = path.join(dir, "deaktiviert.json")
  try {
    writeFileSync(disabledFile, JSON.stringify({ disabled: ["python"] }))
    const { ctx, hooks } = harness({ disabledFile })
    await plugin.setup(ctx)
    const call = { tool: "write", sessionID: "guard", input: { path: path.join(project, "src/app.py"), content: "x" } }
    await hooks.context({ sessionID: "guard", messages: [] })
    await assert.rejects(hooks["execute.before"](call), /cubeone-vorgabe:python/)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

function modelDraft(models) {
  return {
    models,
    list: (providerID) => models.filter((model) => model.providerID === providerID),
    update: (providerID, id, edit) => edit(models.find((model) => model.providerID === providerID && model.id === id)),
  }
}

test("models a user adds to a managed provider are disabled, other providers stay untouched", () => {
  const draft = modelDraft([
    { providerID: "openrouter-zdr", id: "~anthropic/claude-sonnet-latest", enabled: true },
    { providerID: "openrouter-zdr", id: "meta-llama/uncurated", enabled: true },
    { providerID: "other", id: "x", enabled: true },
  ])
  disableUncurated(draft, curatedModels({ "openrouter-zdr": ["~anthropic/claude-sonnet-latest"] }))
  assert.deepEqual(
    draft.models.map((model) => model.enabled),
    [true, false, true],
  )
})

test("malformed model options curate nothing", () => {
  assert.deepEqual(curatedModels(undefined), {})
  assert.deepEqual(curatedModels(["a"]), {})
  assert.deepEqual(curatedModels({ p: "a", q: ["b", 1] }), { q: ["b"] })
})

test("the plugin registers the model filter only when models are configured", async () => {
  const transforms = []
  const { ctx } = harness({ models: { "openrouter-zdr": ["a"] } })
  ctx.model = { transform: async (callback) => transforms.push(callback) }
  await plugin.setup(ctx)
  assert.equal(transforms.length, 1)
  const draft = modelDraft([{ providerID: "openrouter-zdr", id: "b", enabled: true }])
  transforms[0](draft)
  assert.equal(draft.models[0].enabled, false)

  const bare = harness()
  bare.ctx.model = { transform: async () => assert.fail("no models configured") }
  await plugin.setup(bare.ctx)
})

test("the managed config curates exactly the models it defines", () => {
  const text = readFileSync(path.join(root, "managed", "opencode.jsonc"), "utf8")
  const config = JSON.parse(text.replace(/^\s*\/\/.*$/gm, ""))
  const vorgaben = config.plugins.find((entry) => entry.package?.endsWith("/cubeone-vorgaben"))
  for (const [providerID, provider] of Object.entries(config.providers)) {
    assert.deepEqual(vorgaben.options.models[providerID], Object.keys(provider.models))
  }
})
