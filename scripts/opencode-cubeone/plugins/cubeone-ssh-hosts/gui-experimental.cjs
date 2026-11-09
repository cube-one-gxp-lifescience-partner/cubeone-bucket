"use strict"

// GUI-only plugin without a window part, in plain CommonJS like the other cube one GUI plugins. The app evaluates this
// bundle twice; the `main` setup runs once in the desktop's Electron main process, as the signed-in user. Node built-ins
// and `electron` are inert stand-ins in a window, so everything that touches the machine stays inside `main`.
//
// What it does: the Desktop app's built-in SSH plugin keeps its server list in the row (name 'plugin.ssh', key
// 'servers') of the state table in drafts.sqlite in the app's userData folder. A row that holds an empty list, or no
// row at all, is a list the user never filled. This plugin writes the plain Linux aliases of the user's own
// ~/.ssh/config into that row, but only then. It never creates the database or changes its schema, never touches any
// other row, never replaces a list that has entries or a value it does not recognise, and starts no process.
// The app reads the list once and caches it, so a seeded list can first show on the NEXT start of the Desktop app.
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { Schema } = require("effect")
const { Plugin } = require("@opencode/plugin/gui")

const STATE_NAME = "plugin.ssh"
const STATE_KEY = "servers"
const MARKER_KEY = "seeded"
// A name becomes an ssh argument in the app: letters, digits and '-', starting with a letter or digit.
const ALIAS = /^[A-Za-z0-9][A-Za-z0-9-]{0,79}$/
const MAX_ALIASES = 200
const MAX_CONFIG_BYTES = 1024 * 1024
const BUSY_MS = 1000
const STATE_COLUMNS = ["name", "key", "value", "updated_at"]

// Writes only a row whose value is text that is valid JSON and an array without elements (whitespace allowed). The
// CASE evaluates in order, so json_type never sees text that is not valid JSON (that would raise an error). A JSON
// null, an object, any other value, a blob or a list with entries leaves the row as it is. A missing row is inserted.
const UPSERT = `INSERT INTO state(name, key, value, updated_at) VALUES (?, ?, ?, ?)
ON CONFLICT(name, key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
WHERE CASE
  WHEN typeof(state.value) <> 'text' THEN 0
  WHEN json_valid(state.value) = 0 THEN 0
  ELSE json_type(state.value) = 'array' AND json_array_length(state.value) = 0
END`

/** The explicit, plain aliases of Host lines: no wildcard, no negation, no '-win-' host, each once whatever the case. */
function parseAliases(text) {
  const seen = new Set()
  const aliases = []
  for (const raw of String(text).replace(/^\uFEFF/, "").split(/\r\n|\n|\r/)) {
    const match = /^host\s+(.+)$/i.exec(raw.replace(/#.*$/, "").trim())
    if (!match) continue
    for (const token of match[1].split(/\s+/)) {
      if (/[*?!]/.test(token) || !ALIAS.test(token) || /-win-/i.test(token)) continue
      const key = token.toLowerCase()
      if (seen.has(key)) continue
      seen.add(key)
      aliases.push(token)
    }
  }
  return aliases.slice(0, MAX_ALIASES)
}

/** The aliases of <home>/.ssh/config, read as text only. A missing, unreadable, non-regular or huge file gives none. */
function readAliases(home) {
  try {
    const file = path.join(home, ".ssh", "config")
    const info = fs.statSync(file)
    if (!info.isFile() || info.size > MAX_CONFIG_BYTES) return []
    return parseAliases(fs.readFileSync(file, "utf8"))
  } catch {
    return []
  }
}

/** Only an existing regular file: opening a database that is missing would create it. */
function existingDatabase(userData) {
  try {
    const file = path.join(userData, "drafts.sqlite")
    return fs.lstatSync(file).isFile() ? file : undefined
  } catch {
    return undefined
  }
}

function hasEntries(value) {
  if (typeof value !== "string") return false
  try {
    const parsed = JSON.parse(value)
    return Array.isArray(parsed) && parsed.length > 0
  } catch {
    return false
  }
}

/**
 * Fills an empty or missing server list of the app's SSH plugin. Returns { status, count? } and never throws.
 *   seeded       the aliases were written
 *   kept         the list already has entries; nothing was written
 *   no-aliases   the SSH config gives no plain alias
 *   no-database  drafts.sqlite does not exist yet (the app creates it)
 *   schema       the database has no state table of the expected shape yet
 *   invalid      the row holds something that is not a plain empty list or a list with entries; left as it is
 *   error        anything else (locked, not a database, ...); nothing was written
 * Only `seeded` and `kept` mean the list is settled.
 */
function seedServers({ userData, home, busyMs = BUSY_MS, now = Date.now }) {
  const aliases = readAliases(home)
  if (aliases.length === 0) return { status: "no-aliases" }
  const file = existingDatabase(userData)
  if (!file) return { status: "no-database" }
  let db
  try {
    const { DatabaseSync } = require("node:sqlite")
    db = new DatabaseSync(file)
    db.exec(`PRAGMA busy_timeout = ${Number(busyMs) | 0}`)
    const columns = db.prepare("PRAGMA table_info(state)").all().map((column) => column.name)
    if (!STATE_COLUMNS.every((name) => columns.includes(name))) return { status: "schema" }
    const value = JSON.stringify(aliases.map((alias) => ({ id: alias, target: alias, name: alias })))
    let outcome
    db.exec("BEGIN IMMEDIATE")
    try {
      const written = db.prepare(UPSERT).run(STATE_NAME, STATE_KEY, value, now())
      if (Number(written.changes) > 0) {
        outcome = { status: "seeded", count: aliases.length }
      } else {
        const row = db.prepare("SELECT value FROM state WHERE name = ? AND key = ?").get(STATE_NAME, STATE_KEY)
        outcome = { status: hasEntries(row?.value) ? "kept" : "invalid" }
      }
      db.exec("COMMIT")
    } catch (error) {
      try {
        db.exec("ROLLBACK")
      } catch {
        // The transaction is already gone.
      }
      throw error
    }
    return outcome
  } catch {
    return { status: "error" }
  } finally {
    try {
      db?.close()
    } catch {
      // Nothing left to release.
    }
  }
}

function run(ctx) {
  let marker
  try {
    marker = ctx.storage.store(MARKER_KEY, { schema: Schema.Boolean, initial: false })
  } catch {
    ctx.log.write("warn", "cubeone-ssh-hosts: marker store unavailable, nothing seeded")
    return
  }
  if (marker.value) return
  let result
  try {
    result = seedServers({ userData: require("electron").app.getPath("userData"), home: os.homedir() })
  } catch {
    result = { status: "error" }
  }
  // Fixed text and a count only: no path, host name or file content reaches the log.
  ctx.log.write(
    result.status === "seeded" || result.status === "kept" ? "info" : "warn",
    `cubeone-ssh-hosts: ${result.status}${result.count ? ` (${result.count})` : ""}`,
  )
  if (result.status === "seeded" || result.status === "kept") marker.set(true)
}

exports.parseAliases = parseAliases
exports.readAliases = readAliases
exports.seedServers = seedServers
exports.default = Plugin.define({
  main(ctx) {
    try {
      run(ctx)
    } catch {
      // A failure here must never reach the app: the list stays as it is and the next start tries again.
    }
  },
})
