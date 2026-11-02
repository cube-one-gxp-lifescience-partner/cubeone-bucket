import assert from "node:assert/strict"
import Module, { createRequire } from "node:module"
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
        createEffect(fn) {
          fn()
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

const TCP_LISTEN = `  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0
   1: 0100007F:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12346 1 0000000000000000 100 0 0 10 0
   2: 00000000:0016 0100007F:C350 01 00000000:00000000 00:00000000 00000000     0        0 12347 1 0000000000000000 100 0 0 10 0
`

test("parseListeningPorts keeps only LISTEN (0A) rows, decoded from hex, sorted and de-duplicated", () => {
  const gui = loadGui()
  assert.deepEqual(gui.parseListeningPorts(TCP_LISTEN), [80, 8080])
})

test("parseListeningPorts drops excluded ports and tolerates empty/garbage input", () => {
  const gui = loadGui()
  assert.deepEqual(gui.parseListeningPorts(TCP_LISTEN, new Set([80])), [8080])
  assert.deepEqual(gui.parseListeningPorts(""), [])
  assert.deepEqual(gui.parseListeningPorts(undefined), [])
  assert.deepEqual(gui.parseListeningPorts("not a proc file at all"), [])
})

test("parseSshConfig mirrors ssh.js: only concrete, non-wildcard aliases", () => {
  const gui = loadGui()
  assert.deepEqual(gui.parseSshConfig("Host coding-vm-1\n    HostName 1.2.3.4\n\nHost *\n    ServerAliveInterval 30\n"), ["coding-vm-1"])
})

test("targetOf: sidecar and missing session are local, known aliases are ssh, anything else is wsl", () => {
  const gui = loadGui()
  const hosts = ["coding-vm-1", "coding-vm-2"]
  assert.equal(gui.targetOf({ server: { id: "sidecar" } }, hosts), undefined)
  assert.equal(gui.targetOf(undefined, hosts), undefined)
  assert.deepEqual(gui.targetOf({ server: { id: "coding-vm-1" } }, hosts), { kind: "ssh", id: "coding-vm-1" })
  assert.deepEqual(gui.targetOf({ server: { id: "Ubuntu-24.04" } }, hosts), { kind: "wsl", id: "Ubuntu-24.04" })
})

test("isValidPort accepts 1..65535 only", () => {
  const gui = loadGui()
  assert.equal(gui.isValidPort(3000), true)
  assert.equal(gui.isValidPort("3000"), true)
  assert.equal(gui.isValidPort(0), false)
  assert.equal(gui.isValidPort(65536), false)
  assert.equal(gui.isValidPort("abc"), false)
  assert.equal(gui.isValidPort(undefined), false)
})

test("pickLocalPort keeps the preferred port when free, else the first free port in range", async () => {
  const gui = loadGui()
  assert.equal(await gui.pickLocalPort(3000, async () => false), 3000)
  const taken = new Set([20000, 20001])
  assert.equal(
    await gui.pickLocalPort(3000, async (port) => (port === 3000 ? true : taken.has(port))),
    20002,
  )
})

test("pickLocalPort gives up when the whole range is taken", async () => {
  const gui = loadGui()
  assert.equal(await gui.pickLocalPort(3000, async () => true), undefined)
})

test("the pill is hidden for the local sidecar session and shown for a remote one", () => {
  const gui = loadGui()
  const added = []
  const texts = { pill: "Vorschau", title: "Vorschau auf dem Remote-Ziel" }
  gui.default.setup({
    options: {},
    t: (key) => texts[key] ?? key,
    add: (_registry, value) => added.push(value),
    system: { openExternal: () => {} },
    toast: { show: () => {} },
  })
  const pill = added[0]
  assert.equal(pill.show({ session: { server: { id: "sidecar" }, directory: "/tmp" } }), undefined)
  const view = pill.show({ session: { server: { id: "coding-vm-9" }, directory: "/tmp" } })
  assert.equal(view.label, "Vorschau")
  assert.equal(view.icon, "globe")
})
