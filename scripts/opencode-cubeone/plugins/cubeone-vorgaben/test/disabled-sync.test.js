import assert from "node:assert/strict"
import * as fs from "node:fs"
import { mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import plugin from "../server.js"

const { DisabledSync, replaceDisabled } = createRequire(import.meta.url)("../disabled-sync.cjs")

test("server RPC writes its configured file and preserves profile propagation", async () => {
  const home = mkdtempSync(path.join(os.tmpdir(), "vorgaben-sync-"))
  try {
    const file = path.join(home, "custom", "disabled.json")
    let registered
    await plugin.setup({
      options: { disabledFile: file },
      rpc: { register: async (contract, methods) => (registered = { contract, methods }) },
      session: { hook: async () => {} },
      tool: { hook: async () => {} },
    })
    assert.deepEqual(registered.contract, DisabledSync)
    await assert.rejects(registered.methods.replace(["invalid;id"]), /Invalid rule IDs/)
    assert.deepEqual(replaceDisabled(["design"], file, { home }), { committed: true, profileFailures: 0 })
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), { disabled: ["design"] })
    const profile = path.join(home, ".local", "config", "opencode-people", "person", "opencode")
    mkdirSync(profile, { recursive: true })
    const profileFile = path.join(profile, "vorgaben-deaktiviert.json")
    writeFileSync(profileFile, "malformed")
    replaceDisabled(["mcp", "design", "mcp"], file, { home })
    assert.deepEqual(JSON.parse(readFileSync(profileFile, "utf8")), { disabled: ["design", "mcp"] })
    assert.deepEqual(replaceDisabled([], file, { home }), { committed: true, profileFailures: 0 })
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), { disabled: [] })
    if (process.platform !== "win32") assert.equal(statSync(file).mode & 0o777, 0o600)
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test("Windows and Linux paths are resolved on the server with no shell commands", () => {
  for (const [platform, paths, home] of [
    ["win32", path.win32, "C:\\Users\\Remote User"],
    ["linux", path.posix, "/home/remote user"],
  ]) {
    const writes = []
    const renamed = []
    const io = {
      mkdirSync: () => {},
      mkdtempSync: (prefix) => `${prefix}test`,
      lstatSync: () => { throw Object.assign(new Error("missing"), { code: "ENOENT" }) },
      existsSync: () => false,
      writeFileSync: (...args) => writes.push(args),
      renameSync: (...args) => renamed.push(args),
      rmSync: () => {},
      readdirSync: () => { throw Object.assign(new Error("missing"), { code: "ENOENT" }) },
    }
    replaceDisabled(["design"], "~/.config/opencode/aus.json", { fs: io, path: paths, home, platform })
    assert.equal(renamed[0][1], paths.join(home, ".config/opencode/aus.json"))
    assert.deepEqual(JSON.parse(writes[0][1]), { disabled: ["design"] })
    assert.equal(writes[0][2].mode, 0o600)
  }
})

test("invalid IDs cannot write files and filesystem failures propagate", () => {
  const io = { mkdirSync: () => { throw new Error("write attempted") } }
  for (const ids of [null, {}, [1], [""], ["a".repeat(81)], ["../rule"], ["a;whoami"], ["a\n"], ["Design"]]) {
    assert.throws(() => replaceDisabled(ids, "/unused", { fs: io }), /Invalid rule IDs/)
  }
  assert.throws(() => replaceDisabled(["design"], "/unused", { fs: io }), /write attempted/)
})

test("existing selection retains its inode and permissions; staging errors leave content intact", () => {
  const home = mkdtempSync(path.join(os.tmpdir(), "vorgaben-metadata-"))
  try {
    const file = path.join(home, "central.json")
    const original = JSON.stringify({ disabled: [] })
    writeFileSync(file, original, { mode: 0o640 })
    const before = statSync(file)
    const denied = Object.assign(new Error("staging denied"), { code: "EACCES" })
    assert.throws(() => replaceDisabled(["design"], file, { home, fs: {
      ...fs, writeFileSync: () => { throw denied },
    } }), /staging denied/)
    assert.equal(readFileSync(file, "utf8"), original)
    replaceDisabled(["design"], file, { home })
    const after = statSync(file)
    assert.equal(after.ino, before.ino)
    assert.equal(after.mode, before.mode)
    assert.equal(after.uid, before.uid)
    assert.equal(after.gid, before.gid)
    assert.deepEqual(fs.readdirSync(home), ["central.json"])
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test("a failed rename of a new selection never exposes staged content", () => {
  const home = mkdtempSync(path.join(os.tmpdir(), "vorgaben-rename-"))
  try {
    const file = path.join(home, "central.json")
    assert.throws(() => replaceDisabled(["design"], file, { home, fs: {
      ...fs, renameSync: () => { throw new Error("rename denied") },
    } }), /rename denied/)
    assert.equal(fs.existsSync(file), false)
    assert.deepEqual(fs.readdirSync(home), [])
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test("symlink resolution uses the physical target on Windows and Linux", () => {
  for (const [platform, paths, home] of [
    ["win32", path.win32, "C:\\Users\\Remote"],
    ["linux", path.posix, "/home/remote"],
  ]) {
    const target = paths.join(home, "physical", "selection.json")
    const writes = []
    const io = {
      mkdirSync: () => {},
      lstatSync: () => ({ isSymbolicLink: () => true }),
      realpathSync: () => target,
      mkdtempSync: (prefix) => `${prefix}test`,
      writeFileSync: (...args) => writes.push(args),
      existsSync: () => true,
      copyFileSync: () => {},
      readFileSync: () => Buffer.from('{"disabled":["design"]}'),
      rmSync: () => {},
      renameSync: () => assert.fail("must not replace the symlink or its target inode"),
      readdirSync: () => [],
    }
    assert.deepEqual(replaceDisabled(["design"], "~/central.json", { fs: io, path: paths, home, platform }),
      { committed: true, profileFailures: 0 })
    assert.equal(writes[1][0], target)
    assert.equal(writes[1].length, 2)
  }
})

test("existing symlink targets are updated without replacing the link", { skip: process.platform === "win32" }, () => {
  const home = mkdtempSync(path.join(os.tmpdir(), "vorgaben-link-"))
  try {
    const target = path.join(home, "target.json")
    const link = path.join(home, "central.json")
    writeFileSync(target, JSON.stringify({ disabled: [] }))
    fs.symlinkSync(target, link)
    replaceDisabled(["design"], link, { home })
    assert.equal(fs.lstatSync(link).isSymbolicLink(), true)
    assert.deepEqual(JSON.parse(readFileSync(target, "utf8")), { disabled: ["design"] })
    fs.unlinkSync(target)
    assert.throws(() => replaceDisabled([], link, { home }), /ENOENT/)
    assert.equal(fs.lstatSync(link).isSymbolicLink(), true)
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})
