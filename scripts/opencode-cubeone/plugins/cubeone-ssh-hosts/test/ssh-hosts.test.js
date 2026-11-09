import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import Module, { createRequire } from "node:module"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { DatabaseSync } from "node:sqlite"
import { fileURLToPath, pathToFileURL } from "node:url"

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
    writeFileSync(box.db, "this is not an sqlite database ".repeat(10))
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
      'db.exec(\"PRAGMA busy_timeout = 5000\")',
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
    ["error", (box) => writeFileSync(box.db, "garbage garbage garbage ".repeat(10))],
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

const FLAT = "ssh.servers"
const settingsFile = (box) => path.join(box.userData, "opencode.settings")
const writeSettings = (box, text) => writeFileSync(settingsFile(box), text)
const entry = (name) => ({ id: name, target: name, name })

test("a missing row with a list with entries under the flat key ssh.servers is never replaced, and no file changes", () => {
  const lists = [
    JSON.stringify({ [FLAT]: [entry("mine")] }),
    JSON.stringify({ other: 1, [FLAT]: [{ id: "x", target: "u@h", name: "Mine", extra: { n: 12345678901234567890 }, text: "äö" }], tail: [1, 2] }),
    `\uFEFF${JSON.stringify({ [FLAT]: [null] })}`,
    `{\n\t"${FLAT}": [ ]\n,"${FLAT}": [1]}`,
  ]
  for (const text of lists) {
    const box = sandbox()
    try {
      createDatabase(box.db, { noSshRow: true })
      writeSettings(box, text)
      const dbBefore = sha(box.db)
      const settingsBefore = sha(settingsFile(box))
      assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "kept" }, text)
      assert.equal(sha(box.db), dbBefore, "the database changed")
      assert.equal(sha(settingsFile(box)), settingsBefore, "the settings file changed")
      assert.equal(readFileSync(settingsFile(box), "utf8"), text)
      assert.equal(readRows(box.db).some((row) => row.name === "plugin.ssh"), false)
    } finally {
      box.cleanup()
    }
  }
})

test("a missing row is seeded when no list would be imported: no file, no key, an empty list, a nested ssh.servers, a blank file", () => {
  const cases = [undefined, "{}", "   \n", JSON.stringify({ [FLAT]: [] }), JSON.stringify({ ssh: { servers: [entry("nested")] } }), JSON.stringify({ other: [entry("a")] }), "\uFEFF{}"]
  for (const text of cases) {
    const box = sandbox()
    try {
      createDatabase(box.db, { noSshRow: true })
      if (text !== undefined) writeSettings(box, text)
      const settingsBefore = text === undefined ? undefined : sha(settingsFile(box))
      assert.equal(plugin.seedServers({ userData: box.userData, home: box.home }).status, "seeded", String(text))
      assert.equal(sshRow(readRows(box.db)).value, VALUE(ALIASES))
      if (text === undefined) assert.equal(existsSync(settingsFile(box)), false, "a settings file was created")
      else assert.equal(sha(settingsFile(box)), settingsBefore, "the settings file changed")
    } finally {
      box.cleanup()
    }
  }
})

test("a missing row with settings that cannot be understood writes nothing: malformed, not an object, null, a string, an object, a number", () => {
  const texts = [
    '{ "ssh.servers": [',
    "not json",
    "[1,2]",
    '"text"',
    "null",
    "42",
    JSON.stringify({ [FLAT]: null }),
    JSON.stringify({ [FLAT]: "[]" }),
    JSON.stringify({ [FLAT]: { id: "a" } }),
    JSON.stringify({ [FLAT]: 0 }),
    JSON.stringify({ [FLAT]: false }),
  ]
  for (const text of texts) {
    const box = sandbox()
    try {
      createDatabase(box.db, { noSshRow: true })
      writeSettings(box, text)
      const dbBefore = sha(box.db)
      assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "invalid" }, text)
      assert.equal(sha(box.db), dbBefore)
      assert.equal(readFileSync(settingsFile(box), "utf8"), text)
    } finally {
      box.cleanup()
    }
  }
})

test("a missing row with a settings file that is a folder, or too big, writes nothing", () => {
  const box = sandbox()
  try {
    createDatabase(box.db, { noSshRow: true })
    const dbBefore = sha(box.db)
    mkdirSync(settingsFile(box))
    assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "invalid" })
    rmSync(settingsFile(box), { recursive: true })
    writeSettings(box, `{"a":"${"x".repeat(1024 * 1024)}","${FLAT}":[]}`)
    assert.deepEqual(plugin.seedServers({ userData: box.userData, home: box.home }), { status: "invalid" })
    assert.equal(sha(box.db), dbBefore)
  } finally {
    box.cleanup()
  }
})

test("the flat key is only consulted while the row is missing: an existing row decides alone", () => {
  const nonempty = JSON.stringify({ [FLAT]: [entry("legacy")] })
  const box = sandbox()
  try {
    // An empty list in the row wins over a list in the settings, because the app ignores the settings then.
    createDatabase(box.db, { sshValue: "[]" })
    writeSettings(box, nonempty)
    assert.equal(plugin.seedServers({ userData: box.userData, home: box.home }).status, "seeded")
    assert.equal(sshRow(readRows(box.db)).value, VALUE(ALIASES))
    assert.equal(readFileSync(settingsFile(box), "utf8"), nonempty)
  } finally {
    box.cleanup()
  }
  for (const [sshValue, expected] of [['[{"id":"mine"}]', "kept"], ["not json", "invalid"], ["null", "invalid"]]) {
    const other = sandbox()
    try {
      createDatabase(other.db, { sshValue })
      writeSettings(other, "{ malformed")
      const before = readRows(other.db)
      assert.equal(plugin.seedServers({ userData: other.userData, home: other.home }).status, expected)
      assert.deepEqual(readRows(other.db), before)
      assert.equal(readFileSync(settingsFile(other), "utf8"), "{ malformed")
    } finally {
      other.cleanup()
    }
  }
})

test("a row that appears while the seed waits for the lock is kept, and the settings are read only after the lock is held", async () => {
  const box = sandbox()
  try {
    createDatabase(box.db, { noSshRow: true })
    writeSettings(box, JSON.stringify({ [FLAT]: [] }))
    const script = [
      'const { DatabaseSync } = require("node:sqlite")',
      "const db = new DatabaseSync(process.argv[1])",
      'db.exec(\"PRAGMA busy_timeout = 5000\")',
      'db.exec("BEGIN IMMEDIATE")',
      'process.stdout.write("locked\\n")',
      "setTimeout(() => {",
      `  db.prepare("INSERT INTO state VALUES ('plugin.ssh', 'servers', ?, 77)").run('[{"id":"user","target":"user","name":"user"}]')`,
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
    assert.equal(row.updated_at, 77)
  } finally {
    box.cleanup()
  }
})

test("main treats a legacy list as settled, and leaves the marker false for unreadable settings so the next start retries", () => {
  const cases = [
    [JSON.stringify({ [FLAT]: [entry("legacy")] }), true, "kept"],
    ["{ malformed", false, "invalid"],
    [JSON.stringify({ [FLAT]: null }), false, "invalid"],
  ]
  for (const [text, settled, status] of cases) {
    const box = sandbox()
    try {
      createDatabase(box.db, { noSshRow: true })
      writeSettings(box, text)
      const loaded = loadPlugin({ electron: { app: { getPath: () => box.userData } } })
      const { ctx, calls } = mainContext()
      withHome(box.home, () => loaded.default.main(ctx))
      assert.deepEqual(calls.set, settled ? [true] : [], text)
      assert.equal(calls.logs[0].message, `cubeone-ssh-hosts: ${status}`)
      assert.equal(readRows(box.db).some((row) => row.name === "plugin.ssh"), false)
    } finally {
      box.cleanup()
    }
  }
})

test("a database that vanishes between the check and the open is never created again", () => {
  const box = sandbox()
  try {
    createDatabase(box.db, { sshValue: "[]" })
    const result = plugin.seedServers({
      userData: box.userData,
      home: box.home,
      hooks: { afterGuard: () => rmSync(box.db, { force: true }) },
    })
    assert.deepEqual(result, { status: "error" })
    assert.equal(existsSync(box.db), false, "the database was created")
    assert.deepEqual(readdirSync(box.userData), [])
  } finally {
    box.cleanup()
  }
})

test("a missing file is not created by the write mode the plugin uses, and that mode still opens and writes an existing file", () => {
  const box = sandbox()
  try {
    const missing = path.join(box.userData, "never-created.sqlite")
    const location = pathToFileURL(missing)
    location.search = "?mode=rw"
    assert.throws(() => new DatabaseSync(location), /unable to open database file/)
    assert.equal(existsSync(missing), false, "mode=rw created the file")
    // The control that shows the URI is really interpreted: without it the same call creates the file.
    const created = new DatabaseSync(pathToFileURL(missing))
    created.close()
    assert.equal(existsSync(missing), true)
    rmSync(missing)
    // And mode=rw writes an existing database.
    createDatabase(box.db, { sshValue: "[]" })
    const writable = pathToFileURL(box.db)
    writable.search = "?mode=rw"
    const db = new DatabaseSync(writable)
    db.prepare("UPDATE state SET updated_at = 5 WHERE name = 'plugin.wsl'").run()
    db.close()
    assert.equal(readRows(box.db).find((row) => row.name === "plugin.wsl").updated_at, 5)
  } finally {
    box.cleanup()
  }
})

test("a database that is replaced by an empty file between the check and the open is not written to", () => {
  const box = sandbox()
  try {
    createDatabase(box.db, { sshValue: "[]" })
    const result = plugin.seedServers({
      userData: box.userData,
      home: box.home,
      hooks: { afterGuard: () => writeFileSync(box.db, "") },
    })
    assert.deepEqual(result, { status: "schema" })
    assert.equal(readFileSync(box.db).length, 0)
  } finally {
    box.cleanup()
  }
})

test("every writable open in the plugin goes through the mode=rw URL, and there is no fallback to a plain path", () => {
  const code = readFileSync(source, "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "")
  const opens = [...code.matchAll(/new DatabaseSync\(([^)]*)\)/g)].map((match) => match[1])
  assert.deepEqual(opens, ["location"])
  assert.match(code, /location\.search = "\?mode=rw"/)
  assert.match(code, /pathToFileURL\(file\)/)
  assert.equal(/readOnly|mode=rwc|mode=memory|:memory:/.test(code), false)
})

test("databases in folders with spaces, a hash sign, a percent sign, a plus sign and non-ASCII letters are found and seeded", () => {
  for (const folder of ["with space", "hash#sign", "percent%20sign", "plus+and&amp", "gr\u00F6\u00DFe \u00E4\u00F6"]) {
    const box = sandbox()
    try {
      const userData = path.join(box.root, folder, "ai.opencode.desktop")
      mkdirSync(userData, { recursive: true })
      const db = path.join(userData, "drafts.sqlite")
      createDatabase(db, { noSshRow: true })
      assert.equal(plugin.seedServers({ userData, home: box.home }).status, "seeded", folder)
      assert.equal(sshRow(readRows(db)).value, VALUE(ALIASES))
      assert.deepEqual(readdirSync(userData).sort(), ["drafts.sqlite"])
    } finally {
      box.cleanup()
    }
  }
})
test("the served bundle loads the way the app loads it: Function wrapper, default export with a main setup only", () => {
  const code = readFileSync(source, "utf8")
  const shared = { effect: { Schema: { Boolean: "Schema.Boolean" } }, "@opencode/plugin/gui": { Plugin: { define: (definition) => definition } } }
  const required = []
  const nodeRequire = createRequire(import.meta.url)
  const hostRequire = (request) => {
    required.push(request)
    if (shared[request]) return shared[request]
    if (request === "electron" || request.startsWith("node:")) return nodeRequire(request)
    throw new Error(`Plugin GUI bundle requires a module the app does not share: ${request}`)
  }
  const module = { exports: {} }
  Function("require", "module", "exports", code)(hostRequire, module, module.exports)
  const definition = Object.hasOwn(module.exports, "default") ? module.exports.default : module.exports
  assert.deepEqual(Object.keys(definition).sort(), ["main"])
  assert.equal(typeof definition.main, "function")
  assert.deepEqual([...new Set(required)].sort(), ["@opencode/plugin/gui", "effect", "node:fs", "node:os", "node:path", "node:url"])
})
test("the bundle is GUI-only main code: a single CommonJS file that requires only shared modules and Node built-ins", () => {
  const text = readFileSync(source, "utf8")
  const code = text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "")
  const required = [...code.matchAll(/require\("([^"]+)"\)/g)].map((match) => match[1]).sort()
  assert.deepEqual(required, ["@opencode/plugin/gui", "effect", "electron", "node:fs", "node:os", "node:path", "node:sqlite", "node:url"])
  assert.equal(/require\("\.\.?\//.test(code), false, "the bundle requires a sibling file")
  assert.match(code, /exports\.default = Plugin\.define\(\{\s*main\(ctx\)/)
  assert.equal(/\bsetup\s*\(/.test(code), false, "there is no window part")
  // No process, network, ssh, key, registry, settings write, PATH lookup or other plugin's storage.
  assert.equal(/child_process|spawn|execFile|execSync|\bfetch\(|node:(http|https|net|tls)|WebContents|shell\./i.test(code), false)
  assert.equal(/writeFile|appendFile|rename|unlink|rmSync|mkdir|copyFile|createWriteStream|openSync/.test(code), false, "the plugin writes files")
  assert.equal(/ssh\.exe|ssh-keygen|id_rsa|\.pem|OpenRouter|HKLM|reg\.exe|wsl|Principal/i.test(code), false)
  // The settings file is only ever read: its name appears next to a read, never next to a write.
  assert.deepEqual([...code.matchAll(/opencode\.settings/g)].length, 1)
  assert.match(code, /path\.join\(userData, "opencode\.settings"\)[\s\S]{0,200}fs\.lstatSync\(file\)/)
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
