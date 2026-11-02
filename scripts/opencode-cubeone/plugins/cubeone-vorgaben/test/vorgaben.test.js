import assert from "node:assert/strict"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"
import plugin, { loadAlways, loadRules, readDisabled } from "../server.js"
import { applicable, globToRegExp, parseAlwaysRule, touched, visibleRules } from "../vorgaben.js"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..")
const dirs = [path.join(root, "managed", "vorgaben"), path.join(root, "user", "vorgaben")]
const project = path.resolve("/projekt")
const rules = loadRules(dirs)
const ids = (files, text = "") => applicable(rules, files.map((file) => path.join(project, file)), text, project).map((hit) => hit.rule.id).sort()

test("the shipped rules all load", () => {
  assert.deepEqual(rules.map((rule) => rule.id).sort(), ["design", "mcp", "oidc", "sicherheit"])
})

test("globs", () => {
  assert.ok(globToRegExp("**/*.{tsx,vue,svelte,css}").test("src/ui/Button.tsx"))
  assert.ok(globToRegExp("**/*.{tsx,vue,svelte,css}").test("Button.tsx"))
  assert.ok(!globToRegExp("**/*.{tsx,vue,svelte,css}").test("src/ui/Button.ts"))
  assert.ok(globToRegExp("**/*auth*").test("src/auth"))
})

test("src/auth/callback.ts gets OIDC and not Design", () => {
  assert.deepEqual(ids(["src/auth/callback.ts"]), ["oidc"])
})

test("Button.tsx gets Design and not OIDC", () => {
  assert.deepEqual(ids(["src/components/Button.tsx"]), ["design"])
})

test("a login component gets both", () => {
  assert.deepEqual(ids(["src/auth/Login.tsx"]), ["design", "oidc"])
})

test("security by path and by content", () => {
  assert.deepEqual(ids(["db/schema.sql"]), ["sicherheit"])
  assert.deepEqual(ids(["src/users/user.repository.ts"]), ["sicherheit"])
  assert.deepEqual(ids(["src/routes/users.ts"], "const rows = await db.query('SELECT * FROM users WHERE id = $1', [id])"), ["sicherheit"])
  assert.deepEqual(ids(["src/routes/users.ts"], "export const list = () => []"), [])
})

test("MCP", () => {
  assert.deepEqual(ids(["src/mcp/server.py"]), ["mcp"])
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
  const call = { tool: "write", sessionID: "s1", input: { path: path.join(project, "src/components/Button.tsx"), content: "x" } }
  await assert.rejects(hooks["execute.before"]({ ...call }), (error) => {
    assert.match(error.message, /cubeone-vorgabe:design/)
    assert.match(error.message, /#F47A27/)
    assert.doesNotMatch(error.message, /realm_access/)
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
    input: { path: path.join(project, "src/auth/callback.ts") },
    result: { content: "export async function callback() {}" },
  })
  const first = read()
  await hooks["execute.after"](first)
  assert.match(first.result.content, /cubeone-vorgabe:oidc/)
  assert.match(first.result.content, /realm_access\.roles/)
  assert.doesNotMatch(first.result.content, /Phosphor/)
  const second = read()
  await hooks["execute.after"](second)
  assert.match(second.result.content, /cubeone-verweis:oidc/)
  assert.doesNotMatch(second.result.content, /realm_access/)

  await hooks.context({ sessionID: "s2", messages: [{ text: "compacted summary" }] })
  const third = read()
  await hooks["execute.after"](third)
  assert.match(third.result.content, /cubeone-vorgabe:oidc/)
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
    writeFileSync(disabledFile, JSON.stringify({ disabled: ["oidc"] }))
    const { ctx, hooks } = harness({ disabledFile })
    await plugin.setup(ctx)
    const call = { tool: "write", sessionID: "guard", input: { path: path.join(project, "src/auth/callback.ts"), content: "x" } }
    await hooks.context({ sessionID: "guard", messages: [] })
    await assert.rejects(hooks["execute.before"](call), /cubeone-vorgabe:oidc/)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
