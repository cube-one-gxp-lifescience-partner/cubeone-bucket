import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import Module, { createRequire } from "node:module"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { DatabaseSync } from "node:sqlite"
import { fileURLToPath } from "node:url"

const here = path.dirname(fileURLToPath(import.meta.url))
const source = path.join(here, "..", "gui-experimental.cjs")

// Everything below runs on synthetic folders and in-process SQLite files. No real Desktop profile, ssh, key or network.
// The Desktop SDK is a stub: the real bundle contract (a CommonJS file whose default export is Plugin.define's result and
// whose requires are limited to the shared modules) is checked on the source text and on the stub's view of the file.
const requested = []

// The SDK stub stays installed for the whole run: `main` requires "electron" when it runs, not when the file loads.
let currentElectron
const originalLoad = Module._load
Module._load = function stubbedLoad(request, ...rest) {
  requested.push(request)
  if (request === "effect") return { Schema: { Boolean: "Schema.Boolean" } }
  if (request === "@opencode/plugin/gui") return { Plugin: { define: (definition) => definition } }
  if (request === "electron") return currentElectron ?? { app: { getPath: () => { throw new Error("electron stub not set") } } }
  return originalLoad.call(this, request, ...rest)
}
process.on("exit", () => {
  Module._load = originalLoad
})

function loadPlugin({ electron } = {}) {
  currentElectron = electron
  const require = createRequire(import.meta.url)
  delete require.cache[require.resolve(source)]
  return require(source)
}
const plugin = loadPlugin()

const STATE_TABLE =
  "CREATE TABLE `state` (\n\t`name` text NOT NULL,\n\t`key` text NOT NULL,\n\t`value` text NOT NULL,\n\t`updated_at` integer NOT NULL,\n\tCONSTRAINT `state_pk` PRIMARY KEY(`name`, `key`)\n)"
const VALUE = (names) => JSON.stringify(names.map((name) => ({ id: name, target: name, name })))
const ALIAS_CONFIG = "Host coding-vm-1 coding-vm-2\nHost *\nHost !blocked\nHost build-win-1\nHost CODING-VM-1\n# Host hidden\nHost with.dot -oBad\nHost good3 *.example # note\n    HostName x\n"
const ALIASES = ["coding-vm-1", "coding-vm-2", "good3"]

function sandbox() {
  const root = mkdtempSync(path.join(os.tmpdir(), "ssh-hosts-test-"))
  const home = path.join(root, "home")
  const userData = path.join(root, "userData")
  mkdirSync(path.join(home, ".ssh"), { recursive: true })
  mkdirSync(userData, { recursive: true })
  writeFileSync(path.join(home, ".ssh", "config"), ALIAS_CONFIG)
  return { root, home, userData, db: path.join(userData, "drafts.sqlite"), cleanup: () => rmSync(root, { recursive: true, force: true }) }
}

/** The state table as the Desktop app creates it, plus unrelated rows that must never change. */
function createDatabase(file, { sshValue, noSshRow = false, table = STATE_TABLE } = {}) {
  const db = new DatabaseSync(file)
  db.exec(table)
  if (table === STATE_TABLE) {
    const insert = db.prepare("INSERT INTO state VALUES (?, ?, ?, ?)")
    insert.run("plugin.wsl", "servers", '[{"id":"keep"}]', 11)
    insert.run("opencode.global.dat", "layout", '{"a":1}', 12)
    insert.run("plugin.cubeone-ssh-hosts", "other", "x", 13)
    if (!noSshRow) insert.run("plugin.ssh", "servers", sshValue, 7)
  }
  db.close()
}

function readRows(file) {
  const db = new DatabaseSync(file, { readOnly: true })
  try {
    return db.prepare("SELECT name, key, value, typeof(value) AS type, updated_at FROM state ORDER BY name, key").all().map((row) => ({ ...row }))
  } finally {
    db.close()
  }
}

const sshRow = (rows) => rows.find((row) => row.name === "plugin.ssh" && row.key === "servers")
const others = (rows) => rows.filter((row) => !(row.name === "plugin.ssh" && row.key === "servers"))
const sha = (file) => createHash("sha256").update(readFileSync(file)).digest("hex")

test("parseAliases keeps explicit, plain, non-Windows aliases once, whatever the case, and nothing else", () => {
  assert.deepEqual(plugin.parseAliases(ALIAS_CONFIG), ALIASES)
  assert.deepEqual(plugin.parseAliases("\uFEFFHOST a\r\nhost\tb c\r\nHostname d\r\nHost e-WIN-x f_g -h -oProxyCommand=x 'q' \"z\"\r\n"), ["a", "b", "c"])
  assert.deepEqual(plugin.parseAliases("Host *\nHost !a b? *.c\nHost\n"), [])
  const many = Array.from({ length: 250 }, (_, index) => `h${index}`)
  assert.equal(plugin.parseAliases(`Host ${many.join(" ")}`).length, 200)
  assert.deepEqual(plugin.parseAliases(`Host ${"a".repeat(80)} ${"b".repeat(81)}`), ["a".repeat(80)])
})

test("readAliases reads only the current user's ssh config as text and gives none for anything unusual", () => {
  const box = sandbox()
  try {
    assert.deepEqual(plugin.readAliases(box.home), ALIASES)
    assert.deepEqual(plugin.readAliases(path.join(box.root, "nowhere")), [])
    rmSync(path.join(box.home, ".ssh", "config"))
    mkdirSync(path.join(box.home, ".ssh", "config"))
    assert.deepEqual(plugin.readAliases(box.home), [])
    rmSync(path.join(box.home, ".ssh", "config"), { recursive: true })
    writeFileSync(path.join(box.home, ".ssh", "config"), `Host ok\n${"# filler\n".repeat(200000)}`)
    assert.deepEqual(plugin.readAliases(box.home), [])
  } finally {
    box.cleanup()
  }
})

test("a missing row and a valid empty list (also with whitespace) are filled with the aliases", () => {
  for (const sshValue of [undefined, "[]", " [ ] ", "\n[\r\n]\t"]) {
    const box = sandbox()
    try {
      createDatabase(box.db, sshValue === undefined ? { noSshRow: true } : { sshValue })
      const before = readRows(box.db)
      const result = plugin.seedServers({ userData: box.userData, home: box.home, now: () => 4242 })
      assert.deepEqual(result, { status: "seeded", count: 3 })
      const after = readRows(box.db)
      assert.equal(sshRow(after).value, VALUE(ALIASES))
      assert.equal(sshRow(after).type, "text")
      assert.equal(sshRow(after).updated_at, 4242)
      assert.deepEqual(others(after), others(before), "an unrelated row changed")
      assert.deepEqual(
        JSON.parse(sshRow(after).value).map((entry) => Object.keys(entry).join(",")),
        ["id,target,name", "id,target,name", "id,target,name"],
      )
    } finally {
      box.cleanup()
    }
  }
})

test("a list with entries stays byte for byte, with its timestamp, also with custom entries", () => {
  for (const sshValue of [
    '[{"id":"mine","target":"user@10.0.0.9","name":"My server"}]',
    '[{"id":"coding-vm-1","target":"custom","name":"Mine"}]',
    "[null]",
    " [ 1 ] ",
  ]) {
    const box = sandbox()
    try {
      createDatabase(box.db, { sshValue })
      const before = readRows(box.db)
      assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home, now: () => 9 }), { status: "kept" })
      assert.deepEqual(readRows(box.db), before)
    } finally {
      box.cleanup()
    }
  }
})

test("a malformed, non-array, null, empty-text or non-text value is left as it is and is not settled", () => {
  const values = ["not json", "[", '{"servers":[]}', '"text"', "42", "null", "", "   ", "[]]", "{}"]
  for (const sshValue of values) {
    const box = sandbox()
    try {
      createDatabase(box.db, { sshValue })
      const before = readRows(box.db)
      assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "invalid" }, JSON.stringify(sshValue))
      assert.deepEqual(readRows(box.db), before)
    } finally {
      box.cleanup()
    }
  }
  // A blob that spells an empty list is not text, so it is not a plain empty list either.
  const box = sandbox()
  try {
    createDatabase(box.db, { sshValue: "x" })
    const db = new DatabaseSync(box.db)
    db.prepare("UPDATE state SET value = ? WHERE name = 'plugin.ssh'").run(new Uint8Array([0x5b, 0x5d]))
    db.close()
    const before = readRows(box.db)
    assert.equal(sshRow(before).type, "blob")
    assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "invalid" })
    assert.deepEqual(readRows(box.db), before)
  } finally {
    box.cleanup()
  }
})

test("without a plain alias nothing is read from or written to the database", () => {
  const box = sandbox()
  try {
    createDatabase(box.db, { sshValue: "[]" })
    const before = sha(box.db)
    for (const config of ["Host *\nHost !x\nHost a-win-b\n", "", "HostName only\n"]) {
      writeFileSync(path.join(box.home, ".ssh", "config"), config)
      assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "no-aliases" })
    }
    rmSync(path.join(box.home, ".ssh"), { recursive: true })
    assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "no-aliases" })
    assert.equal(sha(box.db), before)
  } finally {
    box.cleanup()
  }
})

test("a database that does not exist yet is never created, nor is its folder", () => {
  const box = sandbox()
  try {
    assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "no-database" })
    assert.deepEqual(readdirSync(box.userData), [])
    const missing = path.join(box.root, "no", "userData")
    assert.deepEqual(plugin.seedServers({ userData: missing, home: box.home }), { status: "no-database" })
    assert.equal(existsSync(path.join(box.root, "no")), false)
    mkdirSync(box.db)
    assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "no-database" })
    assert.deepEqual(readdirSync(box.userData), ["drafts.sqlite"])
  } finally {
    box.cleanup()
  }
})

test("a database without the state table, or with a different one, is not changed and gets no schema", () => {
  for (const table of ["CREATE TABLE other(a text)", "CREATE TABLE state(name text, key text)"]) {
    const box = sandbox()
    try {
      createDatabase(box.db, { table })
      const before = sha(box.db)
      assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "schema" })
      assert.equal(sha(box.db), before)
      const db = new DatabaseSync(box.db, { readOnly: true })
      const names = db.prepare("SELECT name FROM sqlite_master ORDER BY name").all().map((row) => row.name)
      db.close()
      assert.deepEqual(names, [table.includes("other") ? "other" : "state"])
    } finally {
      box.cleanup()
    }
  }
})

test("a file that is not a database, or an empty file, is not changed", () => {
  const box = sandbox()
  try {
    writeFileSync(box.db, "this is not an sqlite database, it is longer than a header would be .......................")
    const before = sha(box.db)
    assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "error" })
    assert.equal(sha(box.db), before)
    writeFileSync(box.db, "")
    assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "schema" })
    assert.equal(readFileSync(box.db).length, 0)
  } finally {
    box.cleanup()
  }
})

test("a second run is settled and changes nothing: row, timestamp and file contents", () => {
  const box = sandbox()
  try {
    createDatabase(box.db, { noSshRow: true })
    assert.equal(plugin.seedServers({ userData: box.userData, home: box.home, now: () => 1 }).status, "seeded")
    const rows = readRows(box.db)
    assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home, now: () => 2 }), { status: "kept" })
    assert.deepEqual(readRows(box.db), rows)
  } finally {
    box.cleanup()
  }
})

test("a writer that holds the database makes the seed an error without a change; a list it commits meanwhile is never overwritten", async () => {
  const box = sandbox()
  try {
    createDatabase(box.db, { sshValue: "[]" })
    const holder = new DatabaseSync(box.db)
    holder.exec("BEGIN IMMEDIATE")
    const blocked = plugin.seedServers({ userData: box.userData, home: box.home, busyMs: 50 })
    assert.deepEqual(blocked, { status: "error" })
    holder.exec("ROLLBACK")
    holder.close()
    assert.equal(sshRow(readRows(box.db)).value, "[]")

    // A second process writes a list with entries while the seed waits for the lock: the conditional write must lose.
    const script = [
      'const { DatabaseSync } = require("node:sqlite")',
      "const db = new DatabaseSync(process.argv[1])",
      'db.exec("BEGIN IMMEDIATE")',
      'process.stdout.write("locked\\n")',
      "setTimeout(() => {",
      `  db.prepare("UPDATE state SET value = ?, updated_at = 99 WHERE name = 'plugin.ssh'").run('[{"id":"user","target":"user","name":"user"}]')`,
      '  db.exec("COMMIT")',
      "  db.close()",
      "}, 400)",
    ].join("\n")
    const child = spawn(process.execPath, ["-e", script, box.db], { stdio: ["ignore", "pipe", "inherit"] })
    const exited = new Promise((resolve) => {
      child.on("exit", resolve)
    })
    await new Promise((resolve) => {
      child.stdout.once("data", resolve)
    })
    const result = plugin.seedServers({ userData: box.userData, home: box.home, busyMs: 5000 })
    assert.equal(await exited, 0)
    assert.deepEqual(result, { status: "kept" })
    const row = sshRow(readRows(box.db))
    assert.equal(row.value, '[{"id":"user","target":"user","name":"user"}]')
    assert.equal(row.updated_at, 99)
  } finally {
    box.cleanup()
  }
})

test("a concurrent reader (the app) does not stop the seed", () => {
  const box = sandbox()
  try {
    createDatabase(box.db, { sshValue: "[]" })
    const reader = new DatabaseSync(box.db, { readOnly: true })
    assert.equal(reader.prepare("SELECT value FROM state WHERE name = 'plugin.ssh'").get().value, "[]")
    assert.equal(plugin.seedServers({ userData: box.userData, home: box.home }).status, "seeded")
    assert.equal(reader.prepare("SELECT value FROM state WHERE name = 'plugin.ssh'").get().value, VALUE(ALIASES))
    reader.close()
  } finally {
    box.cleanup()
  }
})

function mainContext({ markerValue = false, throwingStore = false } = {}) {
  const calls = { store: [], set: [], logs: [] }
  const ctx = {
    storage: {
      store(key, options) {
        calls.store.push({ key, options })
        if (throwingStore) throw new Error("no store")
        return { value: markerValue, set: (value) => calls.set.push(value) }
      },
    },
    log: { write: (level, message, data) => calls.logs.push({ level, message, data }) },
  }
  return { ctx, calls }
}

function withHome(home, body) {
  const saved = { USERPROFILE: process.env.USERPROFILE, HOME: process.env.HOME }
  process.env.USERPROFILE = home
  process.env.HOME = home
  try {
    return body()
  } finally {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[name]
      else process.env[name] = value
    }
  }
}

test("main seeds once, then sets its own marker; the marker store is a boolean that starts false", () => {
  const box = sandbox()
  try {
    createDatabase(box.db, { sshValue: "[]" })
    const loaded = loadPlugin({ electron: { app: { getPath: (name) => (name === "userData" ? box.userData : "") } } })
    const { ctx, calls } = mainContext()
    withHome(box.home, () => loaded.default.main(ctx))
    assert.equal(calls.store.length, 1)
    assert.equal(calls.store[0].key, "seeded")
    assert.deepEqual(calls.store[0].options, { schema: "Schema.Boolean", initial: false })
    assert.deepEqual(calls.set, [true])
    assert.equal(sshRow(readRows(box.db)).value, VALUE(ALIASES))
    assert.equal(calls.logs[0].level, "info")
    assert.equal(calls.logs[0].message, "cubeone-ssh-hosts: seeded (3)")
    for (const log of calls.logs) assert.equal(JSON.stringify(log).includes(box.root), false, "a path reached the log")
  } finally {
    box.cleanup()
  }
})

test("main marks an existing nonempty list as settled and never opens the database once its marker is set", () => {
  const box = sandbox()
  try {
    createDatabase(box.db, { sshValue: '[{"id":"mine","target":"mine","name":"mine"}]' })
    const loaded = loadPlugin({ electron: { app: { getPath: () => box.userData } } })
    const first = mainContext()
    withHome(box.home, () => loaded.default.main(first.ctx))
    assert.deepEqual(first.calls.set, [true])
    assert.equal(sshRow(readRows(box.db)).value, '[{"id":"mine","target":"mine","name":"mine"}]')

    // Marker true: even a list the user emptied later is not filled again, and the database is not opened.
    const db = new DatabaseSync(box.db)
    db.prepare("UPDATE state SET value = '[]' WHERE name = 'plugin.ssh'").run()
    db.close()
    const before = sha(box.db)
    const second = mainContext({ markerValue: true })
    withHome(box.home, () => loaded.default.main(second.ctx))
    assert.deepEqual(second.calls.set, [])
    assert.equal(second.calls.logs.length, 0)
    assert.equal(sha(box.db), before)
  } finally {
    box.cleanup()
  }
})

test("main leaves the marker false for no alias, no database, no schema, an invalid value and an error, so the next start retries", () => {
  const cases = [
    ["no-aliases", (box) => { writeFileSync(path.join(box.home, ".ssh", "config"), "Host *\n"); createDatabase(box.db, { sshValue: "[]" }) }],
    ["no-database", () => {}],
    ["schema", (box) => createDatabase(box.db, { table: "CREATE TABLE other(a text)" })],
    ["invalid", (box) => createDatabase(box.db, { sshValue: "not json" })],
    ["error", (box) => writeFileSync(box.db, "garbage garbage garbage garbage garbage garbage garbage garbage garbage")],
  ]
  for (const [expected, prepare] of cases) {
    const box = sandbox()
    try {
      prepare(box)
      const loaded = loadPlugin({ electron: { app: { getPath: () => box.userData } } })
      const { ctx, calls } = mainContext()
      withHome(box.home, () => loaded.default.main(ctx))
      assert.deepEqual(calls.set, [], expected)
      assert.equal(calls.logs[0].message, `cubeone-ssh-hosts: ${expected}`)
      assert.equal(calls.logs[0].level, "warn")
    } finally {
      box.cleanup()
    }
  }
})

test("main never throws: a failing marker store, log or electron only ends the attempt, and the list stays as it is", () => {
  const box = sandbox()
  try {
    createDatabase(box.db, { sshValue: "[]" })
    const loaded = loadPlugin({ electron: { app: { getPath: () => { throw new Error("no electron") } } } })
    const broken = mainContext({ throwingStore: true })
    assert.doesNotThrow(() => withHome(box.home, () => loaded.default.main(broken.ctx)))
    assert.equal(broken.calls.logs[0].level, "warn")
    const noApp = mainContext()
    assert.doesNotThrow(() => withHome(box.home, () => loaded.default.main(noApp.ctx)))
    assert.deepEqual(noApp.calls.set, [])
    assert.equal(sshRow(readRows(box.db)).value, "[]")
    const hostile = { storage: { store: () => { throw new Error("x") } }, log: { write: () => { throw new Error("log") } } }
    assert.doesNotThrow(() => loaded.default.main(hostile))
  } finally {
    box.cleanup()
  }
})

test("the bundle is GUI-only main code: a single CommonJS file that requires only shared modules and Node built-ins", () => {
  const text = readFileSync(source, "utf8")
  const code = text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "")
  const required = [...code.matchAll(/require\("([^"]+)"\)/g)].map((match) => match[1]).sort()
  assert.deepEqual(required, ["@opencode/plugin/gui", "effect", "electron", "node:fs", "node:os", "node:path", "node:sqlite"])
  assert.equal(/require\("\.\.?\//.test(code), false, "the bundle requires a sibling file")
  assert.match(code, /exports\.default = Plugin\.define\(\{\s*main\(ctx\)/)
  assert.equal(/\bsetup\s*\(/.test(code), false, "there is no window part")
  // No process, network, ssh, key, registry, settings write, PATH lookup or other plugin's storage.
  assert.equal(/child_process|spawn|execFile|execSync|\bfetch\(|node:(http|https|net|tls)|WebContents|shell\./i.test(code), false)
  assert.equal(/writeFile|appendFile|rename|unlink|rmSync|mkdir|copyFile|createWriteStream|openSync/.test(code), false, "the plugin writes files")
  assert.equal(/ssh\.exe|ssh-keygen|id_rsa|\.pem|OpenRouter|HKLM|reg\.exe|wsl|Principal|settings/i.test(code), false)
  assert.equal(/process\.env|which|where\.exe/.test(code), false, "no PATH or environment lookup")
  assert.equal(/CREATE |ALTER |DROP |PRAGMA (?!busy_timeout|table_info)|DELETE FROM|VACUUM/.test(code), false, "the plugin changes a schema or deletes rows")
  assert.deepEqual([...code.matchAll(/INSERT INTO (\w+)/g)].map((match) => match[1]), ["state"])
})

test("the package is a plugin directory with one GUI export and no server part", () => {
  const manifest = JSON.parse(readFileSync(path.join(here, "..", "package.json"), "utf8"))
  assert.equal(manifest.name, "cubeone-ssh-hosts")
  assert.deepEqual(manifest.exports, { "./gui-experimental": "./gui-experimental.cjs" })
  assert.equal(existsSync(path.join(here, "..", "server.js")), false)
  assert.equal(requested.includes("node:child_process"), false)
})
