"use strict"

// Plain CommonJS on purpose, like cubeone-mcp's pill: the app provides solid-js and @opencode/plugin/gui, and a
// pill needs no JSX. This file only reads local files, so unlike the MCP pill it needs no async polling.
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { createSignal } = require("solid-js")
const { ComposerPill, Plugin } = require("@opencode/plugin/gui")

// Same four folders and the same disabled-file path as in managed/opencode.jsonc's cubeone-vorgaben options.
const DIRS = [
  { dir: "C:/ProgramData/opencode/rules", kind: "always", tier: "mandatory" },
  { dir: "~/.config/opencode/rules/optional", kind: "always", tier: "optional" },
  { dir: "C:/ProgramData/opencode/vorgaben", kind: "vorgabe", tier: "mandatory" },
  { dir: "~/.config/opencode/vorgaben", kind: "vorgabe", tier: "optional" },
]
const DISABLED_FILE = "~/.config/opencode/vorgaben-deaktiviert.json"

function expand(dir) {
  return dir.startsWith("~/") || dir.startsWith("~\\") ? path.join(os.homedir(), dir.slice(2)) : dir
}

function titleOf(kind, id, text) {
  if (kind === "vorgabe") {
    const match = /^---\n([\s\S]*?)\n---/.exec(text.replace(/\r\n/g, "\n"))
    const field = match && /^titel:\s*(.+)$/m.exec(match[1])
    if (field) return field[1].trim().replace(/^["']|["']$/, "")
  }
  const heading = /^#\s+(.+)$/m.exec(text)
  return heading ? heading[1].trim() : id
}

/** Every rule file from the given folders, each tagged with where it came from. A managed id always wins a clash. */
function listRules(dirs) {
  const found = new Map()
  for (const { dir, kind, tier } of dirs) {
    const base = expand(dir)
    let names
    try {
      names = fs
        .readdirSync(base)
        .filter((name) => name.toLowerCase().endsWith(".md"))
        .sort()
    } catch {
      continue
    }
    for (const name of names) {
      const id = name.slice(0, -3).toLowerCase()
      if (found.has(id)) continue
      try {
        const text = fs.readFileSync(path.join(base, name), "utf8")
        found.set(id, { id, kind, tier, title: titleOf(kind, id, text) })
      } catch {
        continue
      }
    }
  }
  return [...found.values()]
}

function readDisabled(file) {
  try {
    const data = JSON.parse(fs.readFileSync(expand(file), "utf8"))
    return new Set((Array.isArray(data?.disabled) ? data.disabled : []).map((id) => String(id).toLowerCase()))
  } catch {
    return new Set()
  }
}

function writeDisabled(file, disabled) {
  const target = expand(file)
  fs.mkdirSync(path.dirname(target), { recursive: true })
  fs.writeFileSync(target, JSON.stringify({ disabled: [...disabled].sort() }, null, 2))
}

exports.titleOf = titleOf
exports.listRules = listRules
exports.readDisabled = readDisabled
exports.writeDisabled = writeDisabled

exports.default = Plugin.define({
  i18n: {
    en: {
      pill: "Policies",
      title: "Policies",
      "tier.mandatory": "mandatory",
      "tier.optional.on": "active",
      "tier.optional.off": "off",
      "action.disable": "Turn off",
      "action.enable": "Turn on",
      none: "No policies configured",
    },
    de: {
      pill: "Richtlinien",
      title: "Richtlinien",
      "tier.mandatory": "Pflicht",
      "tier.optional.on": "aktiv",
      "tier.optional.off": "aus",
      "action.disable": "Ausschalten",
      "action.enable": "Einschalten",
      none: "Keine Richtlinien eingerichtet",
    },
  },
  setup(ctx) {
    // Everything here is a local file read, so a tick that the toggle bumps is enough to refresh the pill
    // immediately - no polling, no server round-trip, and the next message already sees the new state.
    const [tick, setTick] = createSignal(0)

    const toggle = (id, currentlyDisabled) => {
      const disabled = readDisabled(DISABLED_FILE)
      if (currentlyDisabled) disabled.delete(id)
      else disabled.add(id)
      writeDisabled(DISABLED_FILE, disabled)
      setTick((value) => value + 1)
    }

    ctx.add(ComposerPill, {
      id: "vorgaben",
      order: -9,
      show: () => {
        tick()
        const rules = listRules(DIRS).sort((a, b) => a.title.localeCompare(b.title))
        const disabled = readDisabled(DISABLED_FILE)
        const rows = rules.map((rule) => {
          const isOptional = rule.tier === "optional"
          const isOff = isOptional && disabled.has(rule.id)
          return {
            id: rule.id,
            label: rule.title,
            icon: !isOptional ? "lock" : isOff ? "circle-ban-sign" : "circle-check",
            detail: !isOptional ? ctx.t("tier.mandatory") : ctx.t(isOff ? "tier.optional.off" : "tier.optional.on"),
            run: isOptional ? () => toggle(rule.id, isOff) : undefined,
          }
        })
        if (!rows.length) rows.push({ id: "none", label: ctx.t("none"), icon: "lock" })
        const offCount = rules.filter((rule) => rule.tier === "optional" && disabled.has(rule.id)).length
        return {
          label: offCount ? `${ctx.t("pill")} (${offCount})` : ctx.t("pill"),
          icon: "shield",
          tone: offCount ? "warning" : undefined,
          title: ctx.t("title"),
          rows,
        }
      },
    })
  },
})
