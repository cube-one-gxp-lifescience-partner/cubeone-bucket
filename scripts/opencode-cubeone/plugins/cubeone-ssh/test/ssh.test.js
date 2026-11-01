import assert from "node:assert/strict"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { test } from "node:test"
import { formatNote, parseSshConfig } from "../ssh.js"
import plugin from "../server.js"

const REAL_CONFIG = `Host coding-vm-1
    HostName 192.168.10.250
    User cubeone
    IdentityFile ~/.ssh/id-coding-vm
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host coding-vm-2
    HostName 192.168.10.249
    User cubeone
    IdentityFile ~/.ssh/id-coding-vm
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host coding-vm-win-1
    HostName 192.168.10.242
    User SWE
    IdentityFile ~/.ssh/id-coding-vm
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host *
    ServerAliveInterval 30
    ServerAliveCountMax 10
    TCPKeepAlive yes
    ConnectTimeout 15
    Compression no
`

test("parses real coding-vm config, skipping the wildcard block", () => {
  const hosts = parseSshConfig(REAL_CONFIG)
  assert.deepEqual(
    hosts.map((h) => h.alias),
    ["coding-vm-1", "coding-vm-2", "coding-vm-win-1"],
  )
  assert.deepEqual(hosts[0], { alias: "coding-vm-1", hostName: "192.168.10.250", user: "cubeone" })
  assert.deepEqual(hosts[2], { alias: "coding-vm-win-1", hostName: "192.168.10.242", user: "SWE" })
})

test("private key paths and wildcard options never surface as hosts", () => {
  const hosts = parseSshConfig(REAL_CONFIG)
  const text = JSON.stringify(hosts)
  assert.ok(!text.includes("id-coding-vm"))
  assert.ok(!text.includes("ServerAliveInterval"))
})

test("a Host line can carry several concrete aliases", () => {
  const hosts = parseSshConfig("Host foo bar\n    HostName example.internal\n    User svc\n")
  assert.deepEqual(
    hosts.map((h) => h.alias),
    ["foo", "bar"],
  )
  assert.equal(hosts[1].hostName, "example.internal")
})

test("a Match block does not attach to the previous Host", () => {
  const hosts = parseSshConfig("Host jump\n    HostName jump.internal\n\nMatch host *.example.com\n    User nobody\n")
  assert.equal(hosts.length, 1)
  assert.equal(hosts[0].user, undefined)
})

test("an alias without HostName still gets listed by name alone", () => {
  const hosts = parseSshConfig("Host plain\n    User someone\n")
  assert.equal(formatNote(hosts), "Bekannte Ziele aus der lokalen SSH-Konfiguration (~/.ssh/config): plain. Verbindung über pty_spawn mit ssh, nicht-interaktiv mit -o BatchMode=yes -o StrictHostKeyChecking=accept-new, wie in der Shell-Regel beschrieben.")
})

test("formatNote is empty for no hosts", () => {
  assert.equal(formatNote([]), "")
  assert.equal(formatNote(undefined), "")
})

test("formatNote joins alias, user and hostname", () => {
  const hosts = parseSshConfig(REAL_CONFIG)
  const note = formatNote(hosts)
  assert.ok(note.includes("coding-vm-1 (cubeone@192.168.10.250)"))
  assert.ok(note.includes("coding-vm-win-1 (SWE@192.168.10.242)"))
  assert.ok(!note.includes("Host *"))
})

test("plugin appends the note to the session system prompt", async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), "cubeone-ssh-test-"))
  const configPath = path.join(dir, "config")
  writeFileSync(configPath, REAL_CONFIG, "utf8")
  try {
    let hook
    const ctx = {
      options: { configPath },
      session: {
        hook: async (name, cb) => {
          if (name === "context") hook = cb
        },
      },
    }
    await plugin.setup(ctx)
    const input = { sessionID: "s1", system: [{ type: "text", text: "base" }] }
    await hook(input)
    assert.equal(input.system.length, 2)
    assert.ok(input.system[1].text.includes("coding-vm-1"))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("plugin stays silent when the config file is missing", async () => {
  let hook
  const ctx = {
    options: { configPath: path.join(os.tmpdir(), "cubeone-ssh-test-missing-" + Date.now()) },
    session: {
      hook: async (name, cb) => {
        if (name === "context") hook = cb
      },
    },
  }
  await plugin.setup(ctx)
  const input = { sessionID: "s1", system: [] }
  await hook(input)
  assert.deepEqual(input.system, [])
})
