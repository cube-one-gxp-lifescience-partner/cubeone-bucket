"use strict"

const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")

// Plain RPC contract, like cubeone-mcp; the GUI inlines it because its bundle cannot load local modules.
exports.DisabledSync = {
  id: "cubeone-vorgaben.disabled",
  methods: {
    replace: {
      input: { type: "array", items: { type: "string", pattern: "^[a-z0-9-]{1,80}$" } },
      output: {
        type: "object",
        properties: { committed: { const: true }, profileFailures: { type: "integer", minimum: 0 } },
        required: ["committed", "profileFailures"],
        additionalProperties: false,
      },
    },
  },
  events: {},
}

/**
 * Persist the GUI selection on the server without involving its shell.
 * @param {unknown} ids - Disabled rule IDs.
 * @param {string} file - Configured server-side selection file.
 * @param {object} [environment] - Filesystem boundary used by tests.
 * @returns {{committed: true, profileFailures: number}} Commit and propagation outcome.
 * @author Marvin Fenßel
 * @created 09.11.2026
 * @changelog 09.11.2026 - Use filesystem writes and a central commit with best-effort propagation.
 */
exports.replaceDisabled = function replaceDisabled(ids, file, environment = {}) {
  if (!Array.isArray(ids) || ids.some((id) => typeof id !== "string" || !/^[a-z0-9-]{1,80}$/.test(id) || /[^a-z0-9-]/.test(id))) {
    throw new Error("Invalid rule IDs")
  }
  const io = environment.fs ?? fs
  const home = environment.home ?? os.homedir()
  const paths = environment.path ?? path
  const configured = file || "~/.config/opencode/vorgaben-deaktiviert.json"
  let target = configured.startsWith("~/") || configured.startsWith("~\\")
    ? paths.join(home, configured.slice(2)) : configured
  const body = JSON.stringify({ disabled: [...new Set(ids)].sort() }, null, 2)
  const write = (destination) => {
    io.mkdirSync(paths.dirname(destination), { recursive: true })
    const exists = io.existsSync(destination)
    io.writeFileSync(destination, body, { mode: 0o600 })
    if (!exists && (environment.platform ?? process.platform) !== "win32") {
      io.chmodSync(destination, 0o600)
    }
  }
  io.mkdirSync(paths.dirname(target), { recursive: true })
  let targetInfo
  try {
    targetInfo = io.lstatSync(target)
  } catch (error) {
    if (error.code !== "ENOENT") throw error
  }
  // Resolve existing links; dangling links reject rather than silently replacing the link itself.
  if (targetInfo?.isSymbolicLink()) target = io.realpathSync(target)
  const staging = io.mkdtempSync(paths.join(paths.dirname(target), ".disabled-sync-"))
  const staged = paths.join(staging, "selection.json")
  const backup = paths.join(staging, "previous.json")
  try {
    io.writeFileSync(staged, body, { mode: 0o600 })
    if (io.existsSync(target)) {
      /**
       * Replacing an existing inode by rename loses Windows ACLs and POSIX extended metadata.
       * Copy into the existing target instead: symlinks, owner and ACLs stay intact. This fallback
       * is not atomic for readers; keep a backup for restoration if the overwrite fails.
       */
      io.copyFileSync(target, backup)
      try {
        io.writeFileSync(target, io.readFileSync(staged))
      } catch (error) {
        try {
          io.writeFileSync(target, io.readFileSync(backup))
        } catch {
          console.warn("Policy selection restoration failed")
        }
        throw error
      }
    } else {
      // Same-filesystem rename commits a fully written new file atomically.
      io.renameSync(staged, target)
    }
  } finally {
    try {
      io.rmSync(staging, { recursive: true, force: true })
    } catch {
      console.warn("Policy selection staging cleanup failed")
    }
  }
  const result = { committed: true, profileFailures: 0 }
  const people = paths.join(home, ".local", "config", "opencode-people")
  let profiles
  try {
    profiles = io.readdirSync(people)
  } catch (error) {
    if (error.code !== "ENOENT") result.profileFailures += 1
    return result
  }
  for (const profile of profiles) {
    try {
      const folder = paths.join(people, profile, "opencode")
      if (io.existsSync(folder) && io.statSync(folder).isDirectory()) {
        write(paths.join(folder, "vorgaben-deaktiviert.json"))
      }
    } catch {
      result.profileFailures += 1
    }
  }
  return result
}
