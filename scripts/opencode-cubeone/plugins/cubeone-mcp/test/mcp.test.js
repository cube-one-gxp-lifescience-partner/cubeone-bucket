import assert from "node:assert/strict"
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import Module, { createRequire } from "node:module"
import http from "node:http"
import net from "node:net"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"
import plugin, { CallbackRelay, labelOf, unavailableNote } from "../server.js"

const servers = [
  { name: "cube-note", title: "Outline", status: { status: "connected" } },
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
  assert.equal(labelOf({ name: "cube-note", title: "Outline" }), "cube note")
  assert.match(unavailableNote([{ name: "cube-note", title: "Outline", status: { status: "needs_auth" } }]), /cube note \(Anmeldung nötig\)/)
  assert.doesNotMatch(unavailableNote([{ name: "cube-note", title: "Outline", status: { status: "needs_auth" } }]), /Outline/)
})

test("the context hook adds the note for the session's directory", async () => {
  let hook
  let asked
  let registered
  await plugin.setup({
    rpc: { register: async (definition, methods) => (registered = { definition, methods }) },
    session: { get: async () => ({ location: { directory: "C:/p" } }), hook: async (_name, callback) => (hook = callback) },
    mcp: { list: async (input) => ((asked = input), { data: servers }) },
  })
  assert.deepEqual(registered.definition, CallbackRelay)
  assert.deepEqual(CallbackRelay.events, {})
  await assert.rejects(registered.methods.send({ port: 0, target: "/callback?code=x" }, {}), /Invalid callback relay input/)
  const input = { sessionID: "s", system: [] }
  await hook(input)
  assert.deepEqual(asked, { location: { directory: "C:/p" } })
  assert.match(input.system[0].text, /LAB11/)
})

function loadModule() {
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

function loadGui() {
  return loadModule().default
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
  assert.equal(view.rows.find((row) => row.label === "cube note").detail, "angemeldet")
  assert.equal(view.rows.find((row) => row.label === "cube project").detail, "nicht angemeldet")
  assert.equal(toasts[0].title, "MCP-Anmeldung nötig")
  assert.equal(toasts[0].description, "LAB11")

  calls.length = 0
  lab.run()
  await new Promise((resolve) => setTimeout(resolve, 20))
  assert.deepEqual(calls.slice(0, 2), [["get", "mcp_1"], ["connect", "m1"]])
  assert.deepEqual(opened, ["https://lab11.cubeone.de/oauth/authorize?x"])
  controller.abort()
  cleanup()
})

test("the cube project row signs in with the plugin's browser method", async () => {
  const gui = loadGui()
  const added = []
  const opened = []
  const calls = []
  let connected = false
  const client = {
    mcp: { list: async () => ({ data: [] }) },
    integration: {
      get: async (input) => {
        if (input.integrationID !== "redmine") throw new Error("unknown")
        return { data: { id: "redmine", methods: [{ id: "browser", type: "oauth" }], connections: connected ? [{ id: "c1" }] : [] } }
      },
      oauth: {
        connect: async (input) => {
          calls.push([input.integrationID, input.methodID])
          connected = true
          return { data: { url: "https://project.cubeone.de/oauth/authorize?x" } }
        },
      },
    },
  }
  const session = { server: { id: "sidecar", client }, directory: "C:/p" }
  const controller = new AbortController()
  const cleanup = gui.setup({
    t: (key) => gui.i18n.de[key] ?? key,
    add: (_registry, value) => added.push(value),
    toast: { show: () => {} },
    system: { openExternal: (url) => opened.push(url) },
    sessions: { current: () => session },
    signal: controller.signal,
  })
  added[0].show({ session })
  await new Promise((resolve) => setTimeout(resolve, 20))
  const row = added[0].show({ session }).rows.find((item) => item.label === "cube project")
  row.run()
  await new Promise((resolve) => setTimeout(resolve, 20))
  assert.deepEqual(calls, [["redmine", "browser"]])
  assert.deepEqual(opened, ["https://project.cubeone.de/oauth/authorize?x"])
  controller.abort()
  cleanup()
})

function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer()
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

test("a remote session replays the browser's callback on the server, without a second SSH connection", async () => {
  const port = await freePort()
  const order = []
  const originalLoad = Module._load
  Module._load = function (request, ...rest) {
    if (request === "@opencode/plugin/gui/browser") return { Browser: { id: "browser" } }
    return originalLoad.call(this, request, ...rest)
  }
  const url = "https://git.cubeone.de/oauth/authorize?redirect_uri=" + encodeURIComponent(`http://127.0.0.1:${port}/callback`)
  const module = loadModule()
  let stopMain = () => {}
  try {
    const gui = module.default
    const added = []
    const relays = []
    let connected = false
    const client = {
      mcp: {
        list: async () => ({
          data: [{ name: "cube-git", title: "cube git", status: { status: connected ? "connected" : "needs_auth" }, integrationID: "mcp_git" }],
        }),
      },
      integration: {
        get: async () => ({ data: { methods: [{ id: "browser", type: "oauth" }] } }),
        oauth: { connect: async () => ({ data: { url } }) },
      },
      rpc: (definition) => {
        assert.deepEqual(definition, CallbackRelay)
        return {
          send: async (input, options) => {
            relays.push({ input, options })
            connected = true
            return 0
          },
        }
      },
      shell: { create: async () => { throw new Error("Callbacks must not use shell commands") } },
    }
    const session = {
      server: { id: "coding-vm-1", client },
      get location() { return { directory: "/home/cubeone/app" } },
    }
    const controller = new AbortController()
    let provided
    stopMain = gui.main({ provide: (token, impl) => (provided = { token, impl }) })
    assert.equal(provided.token, module.Callback)
    const cleanup = gui.setup({
      main: (token) => {
        assert.equal(token, module.Callback)
        return {
          listen: async (text) => provided.impl.listen(text),
          wait: async (id) => provided.impl.wait(id),
          release: async (id) => provided.impl.release(id),
        }
      },
      t: (key) => gui.i18n.de[key] ?? key,
      add: (_registry, value) => added.push(value),
      toast: { show: (options) => order.push(["toast", options.title]) },
      system: { openExternal: (target) => order.push(["system", target]) },
      sessions: { current: () => session },
      signal: controller.signal,
      use: () => () => ({
        status: "active",
        value: { canOpen: () => true, open: (_session, target) => order.push(["browser", target]) },
      }),
    })
    added[0].show({ session })
    await new Promise((resolve) => setTimeout(resolve, 20))
    added[0].show({ session }).rows.find((item) => item.label === "cube git").run()
    await new Promise((resolve) => setTimeout(resolve, 50))
    assert.deepEqual(order.find((entry) => entry[0] === "browser"), ["browser", url])

    const page = await fetch(`http://127.0.0.1:${port}/callback?code=abc_123&state=xyz-9`)
    assert.equal(page.status, 200)
    assert.match(await page.text(), /Anmeldung wird abgeschlossen/)
    await new Promise((resolve) => setTimeout(resolve, 50))
    assert.equal(relays.length, 1)
    assert.deepEqual(relays[0].input, { port, target: "/callback?code=abc_123&state=xyz-9" })
    assert.deepEqual(relays[0].options.location, { directory: "/home/cubeone/app" })
    assert.equal(relays[0].options.signal, controller.signal)
    await assert.rejects(fetch(`http://127.0.0.1:${port}/callback?code=again`))

    controller.abort()
    cleanup()
  } finally {
    stopMain()
    Module._load = originalLoad
  }
})

test("the local listener answers only plain GET callbacks and gives way when the port is taken", async () => {
  const module = loadModule()
  const service = module.callbackService()
  try {
  assert.equal(await service.listen("0"), "")
  assert.equal(await service.listen("70000"), "")
  const port = await freePort()
  const id = await service.listen(String(port))
  assert.ok(id)
  assert.equal(await service.listen(String(port)), "")
  assert.equal((await fetch(`http://127.0.0.1:${port}/favicon.ico`)).status, 404)
  const raw = await new Promise((resolve, reject) =>
    http.get({ host: "127.0.0.1", port, path: "/callback?x='y" }, (response) => resolve(response.statusCode)).on("error", reject),
  )
  assert.equal(raw, 404)
  const pending = service.wait(id)
  service.release(id)
  assert.equal(await pending, "")
  } finally {
    service.dispose()
  }
})

test("the GUI and server share one RPC contract and pass callbacks as data", async () => {
  const module = loadModule()
  assert.deepEqual(module.CallbackRelay, CallbackRelay)
  assert.equal(module.directoryOf({ location: { directory: "C:/current" }, directory: "C:/old" }), "C:/current")
  assert.equal(module.directoryOf({ directory: "C:/old" }), "C:/old")
  const calls = []
  const client = {
    rpc: () => ({ send: async (...args) => (calls.push(args), 0) }),
    shell: { create: async () => { throw new Error("Callbacks must not use shell commands") } },
  }
  const location = { directory: "C:/remote" }
  assert.equal(await module.relayOnServer(client, location, 44637, "/callback?code=a1&state=b2"), 0)
  assert.deepEqual(calls[0], [{ port: 44637, target: "/callback?code=a1&state=b2" }, { location, signal: undefined }])
  for (const target of ["/callback?code='x'", "/callback?code=$(id)", "callback", "/admin?code=x"]) {
    await assert.rejects(module.relayOnServer(client, location, 44637, target), /Invalid callback relay input/)
  }
  await assert.rejects(module.relayOnServer(client, location, 0, "/callback?code=x"), /Invalid callback relay input/)
  await assert.rejects(module.relayOnServer(client, {}, 44637, "/callback?code=x"), /Missing callback relay location/)
  assert.equal(calls.length, 1)
  assert.doesNotMatch(readFileSync(new URL("../gui-experimental.cjs", import.meta.url), "utf8"), /shell\.create|curl -fsS|wget -q/)
})
test("the settings switch holds the browser open until the SSH forward is listening", async () => {
  const require = createRequire(import.meta.url)
  delete require.cache[require.resolve("../gui-experimental.cjs")]
  const original = Module._load
  Module._load = function (request, ...rest) {
    if (request === "solid-js") return { createSignal: (value) => [() => value, () => {}] }
    if (request === "effect") return { Schema: { String: "String" } }
    if (request === "@opencode/plugin/gui") return { ComposerPill: "ComposerPill", Plugin: { define: (definition) => definition } }
    return original.call(this, request, ...rest)
  }
  const gui = require("../gui-experimental.cjs")
  Module._load = original
  const url = "http://127.0.0.1:44637/callback?code=1"
  assert.equal(gui.externalUrl({ _tag: "Request", tag: "FilesOpenExternal", payload: { url } }), url)
  assert.equal(gui.externalUrl({ _tag: "Request", tag: "FilesOpenBrowser", payload: { url } }), url)
  assert.equal(gui.externalUrl({ _tag: "Request", tag: "FilesSaveFile", payload: { url } }), undefined)

  let release
  const opened = []
  const guarded = gui.guardPostMessage((message) => opened.push(message.payload.url), () => new Promise((resolve) => (release = resolve)))
  guarded.call({}, { _tag: "Request", tag: "FilesOpenExternal", payload: { url } })
  await new Promise((resolve) => setTimeout(resolve, 20))
  assert.deepEqual(opened, [])
  release()
  await new Promise((resolve) => setTimeout(resolve, 20))
  assert.deepEqual(opened, [url])

  guarded.call({}, { _tag: "Request", tag: "Other", payload: { url: "https://cubeone.de" } })
  assert.deepEqual(opened.at(-1), "https://cubeone.de")
})

test("loopbackPort reads the redirect port and ignores anything that is not a loopback", () => {
  const gui = loadModule()
  const url = "https://git.cubeone.de/oauth/authorize?redirect_uri=" + encodeURIComponent("http://127.0.0.1:46739/callback")
  assert.equal(gui.loopbackPort(url), 46739)
  assert.equal(gui.loopbackPort("http://127.0.0.1:3000/"), 3000)
  assert.equal(gui.loopbackPort("http://127.0.0.1/callback"), undefined)
  assert.equal(gui.loopbackPort("https://git.cubeone.de/oauth/authorize"), undefined)
  assert.equal(gui.loopbackPort("not a url"), undefined)
})

test("no GUI bundle requires a sibling file, because the app shares only its own modules", () => {
  const plugins = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..")
  for (const name of readdirSync(plugins)) {
    let source
    try {
      source = readFileSync(path.join(plugins, name, "gui-experimental.cjs"), "utf8")
    } catch {
      continue
    }
    assert.doesNotMatch(source, /require\(\s*["'`]\.{0,2}\//, name)
  }
})
