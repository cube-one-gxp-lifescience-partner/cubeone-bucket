import { createHash } from "node:crypto"
import { readFileSync, readdirSync, statSync } from "node:fs"
import path from "node:path"

const RULES_DIR = [".cursor", "rules"]
const LEGACY_FILE = ".cursorrules"

function unquote(value) {
  const text = value.trim()
  if (text.startsWith('"') && text.endsWith('"')) return JSON.parse(text)
  if (text.startsWith("'") && text.endsWith("'")) return text.slice(1, -1)
  return text
}

/** Splits a Cursor `.mdc` front matter (`description`, `globs`, `alwaysApply`, ...) from the rule text below it. */
export function parseFrontmatter(source) {
  const text = source.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n")
  const match = /^---\n([\s\S]*?)\n---\n?/.exec(text)
  if (!match) return { attrs: {}, body: text.trim() }
  const attrs = {}
  let listKey
  for (const line of match[1].split("\n")) {
    const item = /^\s+-\s+(.+)$/.exec(line)
    if (item && listKey) {
      attrs[listKey].push(unquote(item[1]))
      continue
    }
    listKey = undefined
    const field = /^([\w-]+):\s*(.*)$/.exec(line)
    if (!field) continue
    const [, key, value] = field
    if (!value.trim()) {
      attrs[key] = []
      listKey = key
      continue
    }
    attrs[key] = unquote(value)
  }
  return { attrs, body: text.slice(match[0].length).trim() }
}

/** Lowercase, `-`-separated, matches the `^[a-z0-9]+(-[a-z0-9]+)*$` id shape the Skill docs recommend. */
export function slugify(value) {
  const slug = value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
  return slug || "regel"
}

function titleCase(stem) {
  const text = stem
    .replace(/[-_]+/g, " ")
    .trim()
    .replace(/\b\w/g, (char) => char.toUpperCase())
  return text || stem
}

/** A path is only ever this project's: the hash keeps ids unique across projects on a shared server. */
export function skillIdFor(absolutePath, stem) {
  const hash = createHash("sha1").update(absolutePath).digest("hex").slice(0, 6)
  return `cursor-${slugify(stem)}-${hash}`
}

function globList(attrs) {
  if (Array.isArray(attrs.globs)) return attrs.globs.filter((glob) => typeof glob === "string" && glob.trim())
  if (typeof attrs.globs === "string" && attrs.globs.trim()) {
    return attrs.globs
      .split(/[,\n]+/)
      .map((glob) => glob.trim())
      .filter(Boolean)
  }
  return []
}

/** Translates one Cursor rule file into an OpenCode `Skill.Info`-shaped object, or `undefined` if it is empty. */
export function convertRule(absolutePath, source, stemOverride) {
  const { attrs, body } = parseFrontmatter(source)
  if (!body) return undefined
  const stem = stemOverride ?? path.basename(absolutePath).replace(/\.(mdc|md)$/i, "")
  const globs = globList(attrs)
  const always = attrs.alwaysApply === "true" || attrs.alwaysApply === true
  const notes = []
  if (typeof attrs.description === "string" && attrs.description.trim()) notes.push(attrs.description.trim())
  if (globs.length) notes.push(`Galt in Cursor für Dateien wie ${globs.join(", ")}.`)
  if (always) notes.push("War in Cursor für jede Datei aktiv; hier als normale Fähigkeit verfügbar, nicht erzwungen.")
  const description = (notes.join(" ") || `Aus der Cursor-Regel „${stem}“ dieses Projekts übernommen.`).slice(0, 1024)
  return {
    id: skillIdFor(absolutePath, stem),
    name: `Cursor: ${titleCase(stem)}`,
    description,
    path: absolutePath,
    content: [
      `Automatisch aus der Cursor-Regel \`${stem}\` dieses Projekts übersetzt. Gilt nur hier, nur für diese Sitzung.`,
      "",
      body,
    ].join("\n"),
  }
}

function tryReadDir(dir, filter) {
  try {
    return readdirSync(dir)
      .filter(filter)
      .sort()
  } catch {
    return []
  }
}

function tryStat(file) {
  try {
    return statSync(file).mtimeMs
  } catch {
    return undefined
  }
}

/** Every Cursor rule found in `directory`: `.cursor/rules/*.mdc` and, as one skill, a legacy `.cursorrules` file. */
export function discoverCursorSkills(directory) {
  const skills = []
  const rulesDir = path.join(directory, ...RULES_DIR)
  const names = tryReadDir(rulesDir, (name) => /\.(mdc|md)$/i.test(name))
  for (const name of names) {
    const file = path.join(rulesDir, name)
    try {
      const skill = convertRule(file, readFileSync(file, "utf8"))
      if (skill) skills.push(skill)
    } catch {
      continue
    }
  }
  const legacy = path.join(directory, LEGACY_FILE)
  try {
    const skill = convertRule(legacy, readFileSync(legacy, "utf8"), "projektregeln")
    if (skill) skills.push({ ...skill, name: "Cursor: Projektregeln" })
  } catch {
    // no legacy file, or it could not be read: nothing to add for it
  }
  return skills
}

/** Cheap fingerprint of the rule files in `directory`, to skip re-parsing when nothing changed. */
export function stamp(directory) {
  const rulesDir = path.join(directory, ...RULES_DIR)
  const names = tryReadDir(rulesDir, (name) => /\.(mdc|md)$/i.test(name))
  const rules = names.map((name) => `${name}:${tryStat(path.join(rulesDir, name))}`).join(",")
  const legacy = tryStat(path.join(directory, LEGACY_FILE))
  return `${rules}|${legacy}`
}
