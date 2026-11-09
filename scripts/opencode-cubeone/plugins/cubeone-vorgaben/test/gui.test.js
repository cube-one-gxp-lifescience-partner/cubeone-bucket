import assert from "node:assert/strict"
import * as fs from "node:fs"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
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
    if (request === "effect") return { Schema: { String: "String" } }
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
  assert.equal(gui.titleOf("vorgabe", "bash", '---\ntitel: "Bash Coding Standards"\n---\n# x'), "Bash Coding Standards")
  assert.equal(gui.titleOf("always", "design", "---\ntitel: Design\n---\n# Icons\n"), "Design")
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

test("main lists the configured folders and toggles only optional rules", () => {
  const gui = loadGui()
  const root = tempDir()
  try {
    const folders = ["rules", "optional", "vorgaben", "eigene"].map((name) => path.join(root, name))
    for (const folder of folders) mkdirSync(folder)
    writeFileSync(path.join(folders[0], "geheimnisse.md"), "# Geheimnisse\n\nNichts in Git.")
    writeFileSync(path.join(folders[1], "paket.md"), "# Paketinstallation\n\nScoop.")
    writeFileSync(path.join(folders[2], "oidc.md"), "---\ntitel: OIDC\n---\nText")
    const options = { rulesMandatory: folders[0], rulesOptional: folders[1], dirs: [folders[2], folders[3]], disabledFile: path.join(root, "aus.json") }
    let provided
    gui.default.main({ options, provide: (token, impl) => (provided = { token, impl }) })
    assert.equal(provided.token, gui.Vorgaben)
    const first = JSON.parse(provided.impl.list())
    assert.deepEqual(first.rules.map((rule) => rule.id).sort(), ["geheimnisse", "oidc", "paket"])
    assert.deepEqual(first.disabled, [])
    assert.deepEqual(JSON.parse(provided.impl.toggle("paket")).disabled, ["paket"])
    assert.deepEqual(JSON.parse(provided.impl.toggle("geheimnisse")).disabled, ["paket"])
    assert.deepEqual(JSON.parse(provided.impl.toggle("oidc")).disabled, ["paket"])
    assert.deepEqual(JSON.parse(provided.impl.toggle("unknown")).disabled, ["paket"])
    writeFileSync(options.disabledFile, "invalid JSON")
    assert.deepEqual(JSON.parse(provided.impl.list()).disabled, [])
    assert.deepEqual(JSON.parse(provided.impl.toggle("paket")).disabled, ["paket"])
    assert.deepEqual(JSON.parse(provided.impl.toggle("paket")).disabled, [])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("remote synchronization uses the session RPC, not a shell, and rejects invalid IDs", async () => {
  const gui = loadGui()
  const sync = createRequire(import.meta.url)("../disabled-sync.cjs")
  assert.deepEqual(gui.DisabledSync, sync.DisabledSync)
  for (const directory of ["C:\\Users\\remote\\repo", "/home/remote/repo"]) {
    const calls = []
    const session = { directory, server: { id: "ssh:remote", client: {
      rpc: (contract) => {
        assert.deepEqual(contract, sync.DisabledSync)
        return { replace: async (...args) => (calls.push(args), { committed: true, profileFailures: 0 }) }
      },
    } } }
    await gui.writeRemoteDisabled(session, new Set(["Design", "mcp"]))
    assert.deepEqual(calls[0][0], ["design", "mcp"])
    assert.deepEqual(calls[0][1].location, { directory })
    await assert.rejects(gui.writeRemoteDisabled(session, ["design'; rm -rf /"]))
    assert.equal(calls.length, 1)
  }
  await assert.rejects(gui.writeRemoteDisabled({ directory: "/repo", server: { client: {
    rpc: () => ({ replace: async () => { throw new Error("unavailable") } }),
  } } }, []), /unavailable/)
  assert.equal(gui.isRemoteSession({ server: { id: "ssh:coding-vm-1" } }), true)
  assert.equal(gui.isRemoteSession({ server: { id: "sidecar" } }), false)
  assert.equal(gui.isRemoteSession(undefined), false)
})

test("the pill shows what main lists, mandatory rules without a button, and toggles optional ones", async () => {
  const gui = loadGui()
  const added = []
  const texts = { "tier.mandatory": "Pflicht", "tier.optional.on": "aktiv", "tier.optional.off": "aus" }
  let disabled = []
  const rules = [
    { id: "geheimnisse", kind: "always", tier: "mandatory", title: "Geheimnisse" },
    { id: "paket", kind: "always", tier: "optional", title: "Paketinstallation" },
  ]
  const toggled = []
  const controller = new AbortController()
  const cleanup = gui.default.setup({
    t: (key) => texts[key] ?? key,
    add: (_registry, value) => added.push(value),
    signal: controller.signal,
    main: (token) => {
      assert.equal(token, gui.Vorgaben)
      return {
        list: async () => JSON.stringify({ rules, disabled }),
        toggle: async (id) => (toggled.push(id), (disabled = disabled.includes(id) ? [] : [id]), JSON.stringify({ rules, disabled })),
      }
    },
  })
  const pill = added[0]
  assert.equal(pill.show({}).rows[0].id, "loading")
  await new Promise((resolve) => setTimeout(resolve, 10))
  const view = pill.show({})
  assert.equal(view.icon, "shield")
  const mandatory = view.rows.find((row) => row.id === "geheimnisse")
  assert.equal(mandatory.detail, "Pflicht")
  assert.equal(mandatory.run, undefined)
  view.rows.find((row) => row.id === "paket").run()
  await new Promise((resolve) => setTimeout(resolve, 10))
  assert.deepEqual(toggled, ["paket"])
  assert.equal(pill.show({}).rows.find((row) => row.id === "paket").detail, "aus")
  assert.equal(pill.show({}).tone, "warning")
  controller.abort()
  cleanup()
})

test("a failed remote toggle rolls back locally and reports the existing sync error", async () => {
  const gui = loadGui()
  const rules = [{ id: "design", tier: "optional", title: "Design" }]
  let disabled = []
  let pill
  const toggled = []
  const errors = []
  const session = { directory: "C:/repo", server: { id: "ssh:windows", client: {
    rpc: () => ({ replace: async () => { throw new Error("offline") } }),
  } } }
  const cleanup = gui.default.setup({
    t: (key) => key,
    add: (_registry, value) => (pill = value),
    main: () => ({
      list: async () => JSON.stringify({ rules, disabled }),
      toggle: async (id) => {
        toggled.push(id)
        disabled = disabled.length ? [] : [id]
        return JSON.stringify({ rules, disabled })
      },
    }),
    toast: { show: (error) => errors.push(error) },
  })
  try {
    await new Promise((resolve) => setTimeout(resolve, 10))
    // Both initial publication and a toggle use the same failure notification.
    pill.show({ session }).rows[0].run()
    await new Promise((resolve) => setTimeout(resolve, 20))
    assert.deepEqual(toggled, ["design", "design"])
    assert.deepEqual(disabled, [])
    assert.equal(pill.show({}).tone, undefined)
    assert.ok(errors.some((error) => error.description === "sync.failed"))
  } finally {
    cleanup()
  }
})

for (const failure of ["profile", "listing", "central"]) {
  test(`remote ${failure} failure respects the central commit boundary`, async () => {
    const gui = loadGui()
    const { replaceDisabled } = createRequire(import.meta.url)("../disabled-sync.cjs")
    const home = tempDir()
    const file = path.join(home, "central.json")
    const people = path.join(home, ".local", "config", "opencode-people")
    const profiles = ["first", "second"].map((name) => path.join(people, name, "opencode", "vorgaben-deaktiviert.json"))
    const original = JSON.stringify({ disabled: [] })
    writeFileSync(file, original)
    for (const profile of profiles) {
      mkdirSync(path.dirname(profile), { recursive: true })
      writeFileSync(profile, original)
    }
    let failedOnce = false
    const outcomes = []
    const denied = () => Object.assign(new Error("denied"), { code: "EACCES" })
    const io = {
      ...fs,
      readdirSync: (folder) => {
        if (failure === "listing" && folder === people) throw denied()
        return fs.readdirSync(folder).sort()
      },
      writeFileSync: (destination, ...args) => {
        if (failure === "profile" && destination === profiles[1]) throw denied()
        if (failure === "central" && destination === file && !failedOnce) {
          failedOnce = true
          // A partial overwrite must also be restored before reporting failure.
          fs.writeFileSync(destination, "partial")
          throw denied()
        }
        return fs.writeFileSync(destination, ...args)
      },
    }
    const rules = [{ id: "design", tier: "optional", title: "Design" }]
    let disabled = []
    let pill
    const errors = []
    const controller = new AbortController()
    const cleanup = gui.default.setup({
      signal: controller.signal,
      t: (key) => gui.default.i18n.de[key] ?? key,
      add: (_registry, value) => (pill = value),
      main: () => ({
        list: async () => JSON.stringify({ rules, disabled }),
        toggle: async (id) => {
          disabled = disabled.length ? [] : [id]
          return JSON.stringify({ rules, disabled })
        },
      }),
      toast: { show: (error) => errors.push(error) },
    })
    try {
      await new Promise((resolve) => setTimeout(resolve, 10))
      const session = { directory: home, server: { id: "ssh:test", client: {
        rpc: () => ({ replace: async (ids) => {
          const result = replaceDisabled(ids, file, { fs: io, home })
          outcomes.push(result)
          return result
        } }),
      } } }
      // Initial publication succeeds; inject the failure only for the changed selection.
      const healthy = { ...session, server: { ...session.server, client: {
        rpc: () => ({ replace: async () => ({ committed: true, profileFailures: 0 }) }),
      } } }
      pill.show({ session: healthy })
      await new Promise((resolve) => setTimeout(resolve, 10))
      pill.show({ session }).rows[0].run()
      await new Promise((resolve) => setTimeout(resolve, 20))
      const expected = failure === "central" ? [] : ["design"]
      assert.deepEqual(disabled, expected)
      assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).disabled, expected)
      if (failure === "central") {
        assert.equal(fs.readFileSync(file, "utf8"), original)
        assert.ok(errors.some((error) => error.variant === "error"))
      } else {
        assert.deepEqual(outcomes, [{ committed: true, profileFailures: 1 }])
        assert.equal(pill.show({}).tone, "warning")
        assert.deepEqual(JSON.parse(fs.readFileSync(profiles[1], "utf8")).disabled, [])
        if (failure === "profile") {
          assert.deepEqual(JSON.parse(fs.readFileSync(profiles[0], "utf8")).disabled, ["design"])
        }
        assert.ok(errors.some((error) => error.variant === "warning"
          && error.description.includes("Personenprofile") && error.description.includes("gespeichert")))
        assert.ok(!errors.some((error) => error.variant === "error"))
      }
    } finally {
      controller.abort()
      cleanup()
      rmSync(home, { recursive: true, force: true })
    }
  })
}
