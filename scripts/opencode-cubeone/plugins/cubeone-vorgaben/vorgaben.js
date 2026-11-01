import path from "node:path"

const SCAN_LIMIT = 200_000

export const FULL = "cubeone-vorgabe:"
export const REFERENCE = "cubeone-verweis:"

function unquote(value) {
  const text = value.trim()
  if (text.startsWith('"') && text.endsWith('"')) return JSON.parse(text)
  if (text.startsWith("'") && text.endsWith("'")) return text.slice(1, -1)
  return text
}

/** Parses a rule file: a small front matter with `titel`, `pfade` (list) and `inhalt` (regex), then the rule text. */
export function parseRule(id, source) {
  const text = source.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n")
  const match = /^---\n([\s\S]*?)\n---\n?/.exec(text)
  if (!match) return undefined
  const rule = { id, title: id, patterns: [], content: undefined, body: text.slice(match[0].length).trim() }
  let list
  for (const line of match[1].split("\n")) {
    const item = /^\s+-\s+(.+)$/.exec(line)
    if (item && list) {
      list.push(unquote(item[1]))
      continue
    }
    list = undefined
    const field = /^(\w+):\s*(.*)$/.exec(line)
    if (!field) continue
    const [, key, value] = field
    if (key === "titel" && value) rule.title = unquote(value)
    if (key === "pfade") {
      list = rule.patterns
      if (value.trim()) rule.patterns.push(unquote(value))
    }
    if (key === "inhalt" && value) rule.content = new RegExp(unquote(value), "i")
  }
  rule.matchers = rule.patterns.map(globToRegExp)
  return rule.body && (rule.matchers.length || rule.content) ? rule : undefined
}

/** `**` crosses folders, `*` and `?` stay inside one, `{a,b}` is a choice. Case-insensitive. */
export function globToRegExp(glob) {
  let out = ""
  let depth = 0
  for (let index = 0; index < glob.length; index++) {
    const char = glob[index]
    if (char === "*" && glob[index + 1] === "*") {
      const slash = glob[index + 2] === "/"
      out += slash ? "(?:.*/)?" : ".*"
      index += slash ? 2 : 1
    } else if (char === "*") out += "[^/]*"
    else if (char === "?") out += "[^/]"
    else if (char === "{") {
      out += "(?:"
      depth++
    } else if (char === "}" && depth) {
      out += ")"
      depth--
    } else if (char === "," && depth) out += "|"
    else out += char.replace(/[.+^$()|[\]\\]/g, "\\$&")
  }
  return new RegExp(`^${out}$`, "i")
}

/** Path relative to the project, with forward slashes. A file outside the project is matched by its name only. */
export function projectPath(file, directory) {
  const normalized = path.resolve(directory || ".", file)
  if (directory) {
    const relative = path.relative(path.resolve(directory), normalized)
    if (relative && !relative.startsWith("..") && !path.isAbsolute(relative)) return relative.split(path.sep).join("/")
  }
  return path.basename(normalized)
}

/** A pattern applies to the file or to one of its folders, so `**\/*auth*` covers `src/auth/callback.ts`. */
export function matchesPath(rule, relative) {
  const parts = relative.split("/").filter(Boolean)
  for (let end = parts.length; end > 0; end--) {
    const candidate = parts.slice(0, end).join("/")
    if (rule.matchers.some((matcher) => matcher.test(candidate))) return true
  }
  return false
}

export function matchesContent(rule, text) {
  return Boolean(rule.content && text && rule.content.test(text.slice(0, SCAN_LIMIT)))
}

const PATCH_FILE = /^\*\*\* (?:Add|Update|Delete) File: (.+)$|^\*\*\* Move to: (.+)$/gm

/** Files a tool call touches, and the text it writes. */
export function touched(tool, input) {
  const files = []
  let written = ""
  if (!input || typeof input !== "object") return { files, written }
  const filePath = input.path ?? input.filePath ?? input.file_path
  if (typeof filePath === "string" && filePath) files.push(filePath)
  if (typeof input.content === "string" && tool !== "read") written += input.content
  for (const key of ["newString", "new_string"]) if (typeof input[key] === "string") written += `\n${input[key]}`
  if (Array.isArray(input.edits)) {
    for (const edit of input.edits) if (typeof edit?.newString === "string") written += `\n${edit.newString}`
  }
  if (typeof input.patchText === "string") {
    for (const match of input.patchText.matchAll(PATCH_FILE)) files.push((match[1] ?? match[2]).trim())
    written += `\n${input.patchText
      .split("\n")
      .filter((line) => line.startsWith("+"))
      .join("\n")}`
  }
  return { files, written }
}

export const WRITING_TOOLS = new Set(["edit", "write", "apply_patch", "multiedit", "patch"])
export const FILE_TOOLS = new Set(["read", ...WRITING_TOOLS])

/** Rules that apply to these files, each with the files it applies to. */
export function applicable(rules, files, text, directory) {
  const found = new Map()
  const relatives = files.map((file) => projectPath(file, directory))
  for (const rule of rules) {
    const hits = relatives.filter((relative) => matchesPath(rule, relative))
    if (!hits.length && matchesContent(rule, text)) hits.push(...(relatives.length ? relatives : ["(Inhalt)"]))
    if (hits.length) found.set(rule.id, { rule, files: hits })
  }
  return [...found.values()]
}

export function fullBlock(rule, files) {
  return [
    `--- ${FULL}${rule.id} | Vorgabe ${rule.title} gilt für ${files.join(", ")} ---`,
    rule.body,
    `--- Ende Vorgabe ${rule.title} ---`,
  ].join("\n")
}

export function referenceBlock(rule, files) {
  return `(${REFERENCE}${rule.id} Vorgabe ${rule.title} gilt auch für ${files.join(", ")}. Der Text steht weiter oben.)`
}

/** Rule ids whose full text is still in the conversation the model sees. */
export function visibleRules(messages) {
  const visible = new Set()
  const text = typeof messages === "string" ? messages : JSON.stringify(messages ?? [])
  for (const match of text.matchAll(/cubeone-vorgabe:([a-z0-9_-]+)/gi)) visible.add(match[1].toLowerCase())
  return visible
}

/** Text the model sees from a tool result, for content rules. */
export function resultText(result) {
  if (!result) return ""
  if (typeof result.content === "string") return result.content
  if (Array.isArray(result.content)) {
    return result.content.map((part) => (part?.type === "text" ? part.text : "")).join("\n")
  }
  if (typeof result.output === "string") return result.output
  return ""
}

/** Appends text to a tool result without changing how its own part is shown. */
export function withAppended(result, text) {
  const base = result ?? {}
  if (typeof base.content === "string") return { ...base, content: `${base.content}\n\n${text}` }
  if (Array.isArray(base.content)) return { ...base, content: [...base.content, { type: "text", text }] }
  const shown = typeof base.output === "string" ? base.output : base.output === undefined ? "" : JSON.stringify(base.output, null, 2)
  return { ...base, content: shown ? `${shown}\n\n${text}` : text }
}
