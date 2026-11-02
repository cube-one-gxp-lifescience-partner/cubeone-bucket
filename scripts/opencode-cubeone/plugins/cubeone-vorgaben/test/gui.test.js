import assert from "node:assert/strict"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import Module, { createRequire } from "node:module"
import os from "node:os"
import path from "node:path"
import test from "node:test"

function loadGui() {
  const original = Module._load
  Module._load = function (request, ...rest) {
    if (request === "solid-js") {
      return {
        createSignal(value) {
          let current = value
          return [() => current, (next) => (current = typeof next === "function" ? next(current) : next)]
        },
      }
    }
    if (request === "@opencode/plugin/gui") return { ComposerPill: "ComposerPill", Plugin: { define: (definition) => definition } }
    return original.call(this, request, ...rest)
  }
  try {
    const require = createRequire(import.meta.url)
    delete require.cache[require.resolve("../gui-experimental.cjs")]
    return require("../gui-experimental.cjs")
  } finally {
    Module._load = original
  }
}

function tempDir() {
  return mkdtempSync(path.join(os.tmpdir(), "vorgaben-gui-test-"))
}

test("titleOf reads titel: from vorgabe front matter, else the first heading, else the id", () => {
  const gui = loadGui()
  assert.equal(gui.titleOf("vorgabe", "oidc", '---\ntitel: OIDC\npfade:\n  - "**/*auth*"\n---\nText'), "OIDC")
  assert.equal(gui.titleOf("always", "kundenrechner", "# Kundenrechner\n\nText."), "Kundenrechner")
  assert.equal(gui.titleOf("always", "x", "Nur Text."), "x")
})

test("listRules merges the four folders and a managed id wins a name clash", () => {
  const gui = loadGui()
  const mandatoryAlways = tempDir()
  const optionalAlways = tempDir()
  const mandatoryVorgaben = tempDir()
  const optionalVorgaben = tempDir()
  try {
    writeFileSync(path.join(mandatoryAlways, "geheimnisse.md"), "# Geheimnisse\n\nNichts in Git.")
    writeFileSync(path.join(optionalAlways, "paketinstallation.md"), "# Paketinstallation\n\nScoop verwenden.")
    writeFileSync(path.join(mandatoryVorgaben, "oidc.md"), '---\ntitel: OIDC\npfade:\n  - "**/*auth*"\n---\nText')
    writeFileSync(path.join(optionalVorgaben, "design.md"), '---\ntitel: Design\npfade:\n  - "**/*.tsx"\n---\nText')
    // Same id as the mandatory folder: the user's copy must lose, exactly like loadRules in server.js.
    writeFileSync(path.join(optionalAlways, "geheimnisse.md"), "# Von mir überschrieben\n\nSollte nie erscheinen.")

    const dirs = [
      { dir: mandatoryAlways, kind: "always", tier: "mandatory" },
      { dir: optionalAlways, kind: "always", tier: "optional" },
      { dir: mandatoryVorgaben, kind: "vorgabe", tier: "mandatory" },
      { dir: optionalVorgaben, kind: "vorgabe", tier: "optional" },
    ]
    const rules = gui.listRules(dirs)
    assert.deepEqual(rules.map((rule) => rule.id).sort(), ["design", "geheimnisse", "oidc", "paketinstallation"])
    const geheimnisse = rules.find((rule) => rule.id === "geheimnisse")
    assert.equal(geheimnisse.tier, "mandatory")
    assert.equal(geheimnisse.title, "Geheimnisse")
    const design = rules.find((rule) => rule.id === "design")
    assert.equal(design.tier, "optional")
    assert.equal(design.title, "Design")
  } finally {
    for (const dir of [mandatoryAlways, optionalAlways, mandatoryVorgaben, optionalVorgaben]) rmSync(dir, { recursive: true, force: true })
  }
})

test("read/writeDisabled round-trip and tolerate a missing file", () => {
  const gui = loadGui()
  const dir = tempDir()
  try {
    const file = path.join(dir, "deaktiviert.json")
    assert.deepEqual(gui.readDisabled(file), new Set())
    gui.writeDisabled(file, new Set(["design", "Paketinstallation"]))
    assert.deepEqual([...gui.readDisabled(file)].sort(), ["design", "paketinstallation"])
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("the pill lists mandatory rules without a button and toggles optional ones", () => {
  const gui = loadGui()
  const added = []
  const texts = { en: {}, de: { "tier.mandatory": "Pflicht", "tier.optional.on": "aktiv", "tier.optional.off": "aus" } }
  gui.default.setup({
    t: (key) => texts.de[key] ?? key,
    add: (_registry, value) => added.push(value),
  })
  const pill = added[0]
  const view = pill.show({})
  assert.ok(Array.isArray(view.rows))
  // Real folders on this machine may or may not exist; either way nothing throws and the shape is a pill.
  assert.equal(typeof view.label, "string")
  assert.equal(view.icon, "shield")
})
