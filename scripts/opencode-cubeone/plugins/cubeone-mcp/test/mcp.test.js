import assert from "node:assert/strict"
import Module, { createRequire } from "node:module"
import test from "node:test"
import plugin, { unavailableNote } from "../server.js"

const servers = [
  { name: "cube-note", status: { status: "connected" } },
  { name: "lab11", title: "LAB11", status: { status: "needs_auth", error: "401" }, integrationID: "mcp_1" },
  { name: "seo-audit", status: { status: "failed", error: "timeout" } },
  { name: "old", status: { status: "disabled" } },
]

test("the note names unavailable servers and the login button", () => {
  const note = unavailableNote(servers)
  assert.match(note, /LAB11 \(Anmeldung nötig\)/)
  assert.match(note, /seo-audit \(nicht erreichbar\)/)
  assert.doesNotMatch(note, /cube-note|old/)
  assert.match(note, /Schaltfläche MCP/)
  assert.equal(unavailableNote([servers[0]]), "")
})

test("the context hook adds the note for the session's directory", async () => {
  let hook
  let asked
  await plugin.setup({
    session: { get: async () => ({ location: { directory: "C:/p" } }), hook: async (_name, callback) => (hook = callback) },
    mcp: { list: async (input) => ((asked = input), { data: servers }) },
  })
  const input = { sessionID: "s", system: [] }
  await hook(input)
  assert.deepEqual(asked, { location: { directory: "C:/p" } })
  assert.match(input.system[0].text, /LAB11/)
})

function loadGui() {
  const original = Module._load
  Module._load = function (request, ...rest) {
    if (request === "solid-js") {
      return {
        createSignal(value) {
          let current = value
          return [() => current, (next) => (current = next)]
        },
      }
    }
    if (request === "@opencode/plugin/gui") return { ComposerPill: "ComposerPill", Plugin: { define: (definition) => definition } }
    return original.call(this, request, ...rest)
  }
  try {
    const require = createRequire(import.meta.url)
    delete require.cache[require.resolve("../gui-experimental.cjs")]
    return require("../gui-experimental.cjs").default
  } finally {
    Module._load = original
  }
}

test("the pill lists each server and opens the browser for a login", async () => {
  const gui = loadGui()
  const added = []
  const toasts = []
  const opened = []
  const calls = []
  const client = {
    mcp: { list: async () => ({ data: servers }) },
    integration: {
      get: async (input) => (calls.push(["get", input.integrationID]), { data: { methods: [{ id: "m1", type: "oauth" }] } }),
      oauth: { connect: async (input) => (calls.push(["connect", input.methodID]), { data: { url: "https://lab11.cubeone.de/oauth/authorize?x" } }) },
    },
    experimental: { mcp: { connect: async () => {} } },
  }
  const session = { server: { id: "sidecar", client }, directory: "C:/p" }
  const controller = new AbortController()
  const cleanup = gui.setup({
    t: (key) => gui.i18n.de[key] ?? key,
    add: (_registry, value) => added.push(value),
    toast: { show: (options) => toasts.push(options) },
    system: { openExternal: (url) => opened.push(url) },
    sessions: { current: () => session },
    signal: controller.signal,
  })
  const pill = added[0]
  assert.equal(pill.show({ session }).title, "MCP-Server werden geprüft …")
  await new Promise((resolve) => setTimeout(resolve, 20))
  const view = pill.show({ session })
  assert.equal(view.label, "MCP 1/3")
  assert.equal(view.tone, "danger")
  const lab = view.rows.find((row) => row.label === "LAB11")
  assert.equal(lab.detail, "Anmeldung nötig")
  assert.equal(view.rows.find((row) => row.label === "cube-note").detail, "angemeldet")
  assert.equal(toasts[0].title, "MCP-Anmeldung nötig")
  assert.equal(toasts[0].description, "LAB11")

  lab.run()
  await new Promise((resolve) => setTimeout(resolve, 20))
  assert.deepEqual(calls, [["get", "mcp_1"], ["connect", "m1"]])
  assert.deepEqual(opened, ["https://lab11.cubeone.de/oauth/authorize?x"])
  controller.abort()
  cleanup()
})
