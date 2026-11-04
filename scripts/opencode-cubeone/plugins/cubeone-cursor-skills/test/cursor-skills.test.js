import assert from "node:assert/strict"
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { convertRule, discoverCursorSkills, parseFrontmatter, skillIdFor, slugify, stamp } from "../cursor-skills.js"

function withProject(fn) {
  const dir = mkdtempSync(path.join(os.tmpdir(), "cubeone-cursor-skills-"))
  try {
    return fn(dir)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

test("parseFrontmatter reads description, a glob list and a flag, and keeps the body", () => {
  const { attrs, body } = parseFrontmatter(
    ["---", "description: RPC Service boilerplate", "globs:", "  - \"*.rpc.ts\"", "  - \"*.rpc.js\"", "alwaysApply: false", "---", "", "# Regel", "Text"].join("\n"),
  )
  assert.equal(attrs.description, "RPC Service boilerplate")
  assert.deepEqual(attrs.globs, ["*.rpc.ts", "*.rpc.js"])
  assert.equal(attrs.alwaysApply, "false")
  assert.equal(body, "# Regel\nText")
})

test("parseFrontmatter without --- front matter keeps everything as the body", () => {
  const { attrs, body } = parseFrontmatter("Nur Text, keine Front Matter.")
  assert.deepEqual(attrs, {})
  assert.equal(body, "Nur Text, keine Front Matter.")
})

test("slugify keeps a-z0-9 and single dashes", () => {
  assert.equal(slugify("RPC Service!!"), "rpc-service")
  assert.equal(slugify("ÄÖÜ"), "regel")
  assert.equal(slugify(""), "regel")
})

test("skillIdFor is stable for the same path and differs across paths", () => {
  const a = skillIdFor("/projekt-a/.cursor/rules/security.mdc", "security")
  const b = skillIdFor("/projekt-a/.cursor/rules/security.mdc", "security")
  const c = skillIdFor("/projekt-b/.cursor/rules/security.mdc", "security")
  assert.equal(a, b)
  assert.notEqual(a, c)
  assert.match(a, /^cursor-security-[0-9a-f]{6}$/)
})

test("convertRule carries the description, the globs and the always-applied note into one description", () => {
  const source = ["---", "description: Nur Backend-Code", "globs: **/*.cs, **/*.sql", "alwaysApply: true", "---", "Backend-Regeln."].join("\n")
  const skill = convertRule("/projekt/.cursor/rules/backend.mdc", source)
  assert.equal(skill.name, "Cursor: Backend")
  assert.match(skill.description, /Nur Backend-Code/)
  assert.match(skill.description, /\*\*\/\*\.cs, \*\*\/\*\.sql/)
  assert.match(skill.description, /jede Datei aktiv/)
  assert.equal(skill.path, "/projekt/.cursor/rules/backend.mdc")
  assert.match(skill.content, /Backend-Regeln\./)
})

test("convertRule without a description falls back to a generated one", () => {
  const skill = convertRule("/projekt/.cursor/rules/x.mdc", "---\n---\nInhalt")
  assert.match(skill.description, /aus der Cursor-Regel „x“/i)
})

test("convertRule returns undefined for an empty rule", () => {
  assert.equal(convertRule("/projekt/.cursor/rules/leer.mdc", "---\ndescription: leer\n---\n   "), undefined)
})

test("discoverCursorSkills finds every .mdc rule plus one skill for a legacy .cursorrules file", () => {
  withProject((dir) => {
    mkdirSync(path.join(dir, ".cursor", "rules"), { recursive: true })
    writeFileSync(path.join(dir, ".cursor", "rules", "security.mdc"), "---\ndescription: Security\n---\nKeine Secrets loggen.")
    writeFileSync(path.join(dir, ".cursor", "rules", "api.mdc"), "---\ndescription: API\n---\nVersion jede Route.")
    writeFileSync(path.join(dir, ".cursorrules"), "Alte Projektregeln als ein Block.")
    const skills = discoverCursorSkills(dir)
    assert.deepEqual(skills.map((skill) => skill.name).sort(), ["Cursor: Api", "Cursor: Projektregeln", "Cursor: Security"])
  })
})

test("discoverCursorSkills on a project without Cursor rules returns nothing", () => {
  withProject((dir) => {
    assert.deepEqual(discoverCursorSkills(dir), [])
  })
})

test("stamp changes when a rule file is added and stays the same otherwise", () => {
  withProject((dir) => {
    mkdirSync(path.join(dir, ".cursor", "rules"), { recursive: true })
    const before = stamp(dir)
    assert.equal(stamp(dir), before)
    writeFileSync(path.join(dir, ".cursor", "rules", "neu.mdc"), "---\ndescription: Neu\n---\nText")
    assert.notEqual(stamp(dir), before)
  })
})
