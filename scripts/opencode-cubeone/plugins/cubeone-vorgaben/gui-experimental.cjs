"use strict"

// Plain CommonJS on purpose, like cubeone-mcp's pill: the app provides solid-js and @opencode/plugin/gui, and a
// pill needs no JSX. The app evaluates this bundle twice. In a window `node:fs` is an inert stand-in, so only `main`,
// in the desktop's main process, reads and writes the rule files, and the window asks it over the `Vorgaben` Ipc.
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { Schema } = require("effect")
const { createSignal } = require("solid-js")
const gui = require("@opencode/plugin/gui")
const { ComposerPill, Plugin } = gui

// Defaults match managed/opencode.jsonc; the plugin's options there win.
const DEFAULTS = {
  rulesMandatory: "C:/ProgramData/opencode/rules",
  rulesOptional: "~/.config/opencode/rules/optional",
  dirs: ["C:/ProgramData/opencode/vorgaben", "~/.config/opencode/vorgaben"],
  disabledFile: "~/.config/opencode/vorgaben-deaktiviert.json",
}
const REFRESH_MS = 30_000

const VORGABEN_SPEC = {
  id: "cubeone-vorgaben",
  methods: {
    list: { output: Schema.String },
    toggle: { input: Schema.String, output: Schema.String },
  },
}
const Vorgaben = gui.Ipc ? gui.Ipc.define(VORGABEN_SPEC) : { kind: "ipc", id: VORGABEN_SPEC.id, spec: VORGABEN_SPEC }

/** The four folders from the plugin's options: the first `dirs` entry is the managed one, the rest are the user's. */
function dirsFrom(options) {
  const text = (value, fallback) => (typeof value === "string" && value ? value : fallback)
  const vorgaben = Array.isArray(options?.dirs) && options.dirs.length ? options.dirs.map(String) : DEFAULTS.dirs
  return [
    { dir: text(options?.rulesMandatory, DEFAULTS.rulesMandatory), kind: "always", tier: "mandatory" },
    { dir: text(options?.rulesOptional, DEFAULTS.rulesOptional), kind: "always", tier: "optional" },
    { dir: vorgaben[0], kind: "vorgabe", tier: "mandatory" },
    ...vorgaben.slice(1).map((dir) => ({ dir, kind: "vorgabe", tier: "optional" })),
  ]
}

function disabledFileFrom(options) {
  return typeof options?.disabledFile === "string" && options.disabledFile ? options.disabledFile : DEFAULTS.disabledFile
}

function expand(dir) {
  return dir.startsWith("~/") || dir.startsWith("~\\") ? path.join(os.homedir(), dir.slice(2)) : dir
}

function plainTitle(value) {
  const text = value.trim()
  if (text.length >= 2 && (text.startsWith('"') || text.startsWith("'")) && text.at(-1) === text[0]) return text.slice(1, -1)
  return text
}

/** The name shown in the pill: `titel` from the front matter, else the first heading, else the file name. */
function titleOf(kind, id, text) {
  const normalized = text.replace(/\r\n/g, "\n")
  const front = /^---\n([\s\S]*?)\n---/.exec(normalized)
  const field = front && /^titel:\s*(.+)$/m.exec(front[1])
  if (field) return plainTitle(field[1])
  const heading = /^#\s+(.+)$/m.exec(normalized)
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

function isRemoteSession(session) {
  const id = session?.server?.id
  return typeof id === "string" && id !== "" && id !== "sidecar"
}

/**
 * The pill stores the off-switch on this PC. An SSH or WSL session applies rules on that server, so the same
 * file has to be written there too. Ids are limited to the rule-file alphabet, which keeps the shell text inert.
 */
function remoteDisableCommand(ids) {
  const disabled = [...ids].map((id) => String(id).toLowerCase()).sort()
  if (disabled.some((id) => !/^[a-z0-9-]{1,80}$/.test(id))) throw new Error("Fehler: Die Auswahlliste ist ungültig.")
  const body = JSON.stringify({ disabled })
  return [
    "umask 077",
    'file="$HOME/.config/opencode/vorgaben-deaktiviert.json"',
    'mkdir -p "$HOME/.config/opencode"',
    `printf '%s\\n' '${body}' > "$file"`,
    'if [ -d "$HOME/.local/config/opencode-people" ]; then',
    '  find "$HOME/.local/config/opencode-people" -mindepth 2 -maxdepth 2 -type d -name opencode | while IFS= read -r cfg; do',
    '    target="$cfg/vorgaben-deaktiviert.json"',
    '    if [ -L "$target" ] || [ ! -e "$target" ]; then ln -sfn "$file" "$target"; else cp -f "$file" "$target" && chmod 600 "$target"; fi',
    "  done",
    "fi",
  ].join("\n")
}

const SYNC_TIMEOUT_MS = 8_000

async function writeRemoteDisabled(session, ids) {
  const client = session?.server?.client
  if (!client?.shell?.create || !client?.shell?.get) throw new Error("remote-shell")
  const command = remoteDisableCommand(ids)
  const location = { directory: session.directory || "/tmp" }
  const created = await client.shell.create({ location, command, timeout: SYNC_TIMEOUT_MS })
  const id = created?.data?.id
  if (!id) throw new Error("remote-shell")
  try {
    const until = Date.now() + SYNC_TIMEOUT_MS
    let info
    while (Date.now() < until) {
      info = (await client.shell.get({ id, location }))?.data
      if (info?.status && info.status !== "running") break
      await new Promise((resolve) => setTimeout(resolve, 200))
    }
    if (info?.status !== "exited" || (info.exit ?? 0) !== 0) throw new Error("remote-shell")
  } finally {
    void Promise.resolve(client.shell.remove?.({ id, location })).catch(() => {})
  }
}

/** What the window shows: every rule, sorted by title, and the ids of the optional rules that are switched off. */
function snapshot(options) {
  const rules = listRules(dirsFrom(options)).sort((a, b) => a.title.localeCompare(b.title))
  const disabled = readDisabled(disabledFileFrom(options))
  return { rules, disabled: rules.filter((rule) => rule.tier === "optional" && disabled.has(rule.id)).map((rule) => rule.id) }
}

/** Switches one optional rule. A mandatory or unknown id changes nothing, whatever the window sends. */
function toggleRule(options, id) {
  const key = String(id ?? "").toLowerCase()
  const rule = listRules(dirsFrom(options)).find((item) => item.id === key)
  if (rule?.tier === "optional") {
    const file = disabledFileFrom(options)
    const disabled = readDisabled(file)
    if (disabled.has(key)) disabled.delete(key)
    else disabled.add(key)
    writeDisabled(file, disabled)
  }
  return snapshot(options)
}

function parseSnapshot(text) {
  try {
    const data = JSON.parse(text)
    return { rules: Array.isArray(data?.rules) ? data.rules : [], disabled: new Set(Array.isArray(data?.disabled) ? data.disabled : []) }
  } catch {
    return undefined
  }
}

exports.titleOf = titleOf
exports.listRules = listRules
exports.readDisabled = readDisabled
exports.writeDisabled = writeDisabled
exports.dirsFrom = dirsFrom
exports.snapshot = snapshot
exports.toggleRule = toggleRule
exports.isRemoteSession = isRemoteSession
exports.remoteDisableCommand = remoteDisableCommand
exports.Vorgaben = Vorgaben

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
      loading: "Loading policies…",
      failed: "Policies unavailable",
      "sync.failed": "The switch was not saved on the server",
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
      loading: "Richtlinien werden geladen …",
      failed: "Richtlinien nicht lesbar",
      "sync.failed": "Der Schalter wurde auf dem Server nicht gespeichert",
    },
  },
  main(ctx) {
    ctx.provide(Vorgaben, {
      list: () => JSON.stringify(snapshot(ctx.options)),
      toggle: (id) => JSON.stringify(toggleRule(ctx.options, id)),
    })
  },
  setup(ctx) {
    const [state, setState] = createSignal(undefined)
    const accept = (text) => {
      const next = parseSnapshot(text)
      setState(next ?? { error: true, rules: [], disabled: new Set() })
    }
    const fail = () => setState((current) => current ?? { error: true, rules: [], disabled: new Set() })
    const load = () => ctx.main(Vorgaben).list({ signal: ctx.signal }).then(accept, fail)
    const seen = new Set()
    const tails = new Map()
    const enqueue = (session, ids) => {
      const key = String(session.server.id)
      const prev = tails.get(key) ?? Promise.resolve()
      const next = prev.catch(() => {}).then(() => writeRemoteDisabled(session, ids))
      tails.set(key, next)
      return next
    }
    const publish = (session) => {
      if (!isRemoteSession(session)) return
      const key = String(session.server.id)
      if (seen.has(key)) return
      const current = state()
      if (!current || current.error) return
      seen.add(key)
      void enqueue(session, current.disabled).catch(() => {
        seen.delete(key)
        ctx.toast?.show?.({ variant: "error", title: ctx.t("pill"), description: ctx.t("sync.failed") })
      })
    }
    const toggle = (id, session) => {
      const remote = isRemoteSession(session)
      if (remote) seen.add(String(session.server.id))
      ctx.main(Vorgaben).toggle(id, { signal: ctx.signal }).then(async (text) => {
        if (!remote) {
          accept(text)
          return
        }
        try {
          await enqueue(session, parseSnapshot(text)?.disabled ?? [])
          accept(text)
        } catch {
          const back = await ctx.main(Vorgaben).toggle(id, { signal: ctx.signal }).catch(() => undefined)
          if (back) accept(back)
          ctx.toast?.show?.({ variant: "error", title: ctx.t("pill"), description: ctx.t("sync.failed") })
        }
      }, fail)
    }

    void load()
    const timer = setInterval(() => void load(), REFRESH_MS)

    ctx.add(ComposerPill, {
      id: "vorgaben",
      order: -9,
      show: (input) => {
        const current = state()
        if (!current) return { label: ctx.t("pill"), icon: "shield", title: ctx.t("title"), rows: [{ id: "loading", label: ctx.t("loading"), icon: "shield" }] }
        publish(input?.session)
        const rules = current.rules
        const disabled = current.disabled
        const rows = rules.map((rule) => {
          const isOptional = rule.tier === "optional"
          const isOff = isOptional && disabled.has(rule.id)
          return {
            id: rule.id,
            label: rule.title,
            icon: !isOptional ? "lock" : isOff ? "circle-ban-sign" : "circle-check",
            detail: !isOptional ? ctx.t("tier.mandatory") : ctx.t(isOff ? "tier.optional.off" : "tier.optional.on"),
            run: isOptional ? () => void toggle(rule.id, input?.session) : undefined,
          }
        })
        if (current.error) rows.push({ id: "failed", label: ctx.t("failed"), icon: "circle-xmark", tone: "danger", run: () => void load() })
        else if (!rows.length) rows.push({ id: "none", label: ctx.t("none"), icon: "lock" })
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

    return () => clearInterval(timer)
  },
})
