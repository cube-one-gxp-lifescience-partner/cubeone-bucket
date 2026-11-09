import { readdirSync, readFileSync, statSync } from "node:fs"
import disabledSync from "./disabled-sync.cjs"
import os from "node:os"
import path from "node:path"
import {
  FILE_TOOLS,
  WRITING_TOOLS,
  applicable,
  fullBlock,
  parseAlwaysRule,
  parseRule,
  referenceBlock,
  resultText,
  touched,
  visibleRules,
  withAppended,
} from "./vorgaben.js"

const RELOAD_MS = 10_000

function expand(dir) {
  return dir.startsWith("~/") || dir.startsWith("~\\") ? path.join(os.homedir(), dir.slice(2)) : dir
}

/** Earlier folders win: a user file cannot replace a managed rule with the same name. */
export function loadRules(dirs) {
  const rules = new Map()
  for (const dir of dirs.map(expand)) {
    let names
    try {
      names = readdirSync(dir).filter((name) => name.toLowerCase().endsWith(".md")).sort()
    } catch {
      continue
    }
    for (const name of names) {
      const id = name.slice(0, -3).toLowerCase()
      if (rules.has(id)) continue
      try {
        const rule = parseRule(id, readFileSync(path.join(dir, name), "utf8"))
        if (rule) rules.set(id, rule)
      } catch {
        continue
      }
    }
  }
  return [...rules.values()]
}

/** Rules that hold in every session, regardless of file. Just one folder: there is no managed/optional override here. */
export function loadAlways(dir) {
  if (!dir) return []
  const base = expand(dir)
  let names
  try {
    names = readdirSync(base).filter((name) => name.toLowerCase().endsWith(".md")).sort()
  } catch {
    return []
  }
  const rules = []
  for (const name of names) {
    try {
      const rule = parseAlwaysRule(name.slice(0, -3).toLowerCase(), readFileSync(path.join(base, name), "utf8"))
      if (rule) rules.push(rule)
    } catch {
      continue
    }
  }
  return rules
}

/** Ids disabled from the Richtlinien GUI. Missing, unreadable or malformed files just mean nothing is disabled. */
export function readDisabled(file) {
  if (!file) return new Set()
  try {
    const data = JSON.parse(readFileSync(expand(file), "utf8"))
    return new Set((Array.isArray(data?.disabled) ? data.disabled : []).map((id) => String(id).toLowerCase()))
  } catch {
    return new Set()
  }
}

/** `{ providerID: [modelID, ...] }` from the options. Anything that is not a list of strings is dropped. */
export function curatedModels(option) {
  if (!option || typeof option !== "object" || Array.isArray(option)) return {}
  return Object.fromEntries(
    Object.entries(option)
      .filter(([, ids]) => Array.isArray(ids))
      .map(([providerID, ids]) => [providerID, ids.filter((id) => typeof id === "string")]),
  )
}

/**
 * A user or project config can add models to a managed provider, and policies cannot address single models. Those
 * models are disabled here. Removing them from the draft is not enough: the provider config adds them back.
 */
export function disableUncurated(draft, curated) {
  for (const [providerID, ids] of Object.entries(curated)) {
    const allowed = new Set(ids)
    for (const model of draft.list(providerID) ?? []) {
      if (!allowed.has(model.id)) draft.update(providerID, model.id, (entry) => (entry.enabled = false))
    }
  }
}

function stamp(dirs) {
  return dirs
    .map(expand)
    .map((dir) => {
      try {
        return readdirSync(dir)
          .map((name) => `${name}:${statSync(path.join(dir, name)).mtimeMs}`)
          .join(",")
      } catch {
        return ""
      }
    })
    .join("|")
}

export default {
  id: "cubeone-vorgaben",
  async setup(ctx) {
    const dirs = Array.isArray(ctx.options?.dirs) ? ctx.options.dirs.filter((dir) => typeof dir === "string") : []
    const gate = ctx.options?.gate !== false
    const rulesOptional = typeof ctx.options?.rulesOptional === "string" ? ctx.options.rulesOptional : undefined
    const disabledFile = typeof ctx.options?.disabledFile === "string" ? ctx.options.disabledFile : undefined
    if (ctx.rpc?.register) {
      await ctx.rpc.register(disabledSync.DisabledSync, {
        replace: async (ids) => disabledSync.replaceDisabled(ids, disabledFile),
      })
    }
    const curated = curatedModels(ctx.options?.models)
    if (Object.keys(curated).length) await ctx.model.transform((draft) => disableUncurated(draft, curated))

    let rules = loadRules(dirs)
    // A vorgabe can only be disabled if it is not also managed: the first folder in dirs always wins.
    let mandatoryIds = new Set(loadRules(dirs.slice(0, 1)).map((rule) => rule.id))
    let loadedStamp = stamp(dirs)
    let checkedAt = Date.now()
    const currentRules = () => {
      if (Date.now() - checkedAt > RELOAD_MS) {
        checkedAt = Date.now()
        const next = stamp(dirs)
        if (next !== loadedStamp) {
          loadedStamp = next
          rules = loadRules(dirs)
          mandatoryIds = new Set(loadRules(dirs.slice(0, 1)).map((rule) => rule.id))
        }
      }
      const disabled = readDisabled(disabledFile)
      return disabled.size ? rules.filter((rule) => mandatoryIds.has(rule.id) || !disabled.has(rule.id)) : rules
    }

    let always = loadAlways(rulesOptional)
    let alwaysStamp = rulesOptional ? stamp([rulesOptional]) : ""
    let alwaysCheckedAt = Date.now()
    const currentAlways = () => {
      if (!rulesOptional) return []
      if (Date.now() - alwaysCheckedAt > RELOAD_MS) {
        alwaysCheckedAt = Date.now()
        const next = stamp([rulesOptional])
        if (next !== alwaysStamp) {
          alwaysStamp = next
          always = loadAlways(rulesOptional)
        }
      }
      const disabled = readDisabled(disabledFile)
      return disabled.size ? always.filter((rule) => !disabled.has(rule.id)) : always
    }

    const sessions = new Map()
    const stateOf = (sessionID) => {
      let state = sessions.get(sessionID)
      if (!state) {
        // matched keeps every rule that applied this session. A compacted history or a dropped tool
        // error would otherwise forget it, and the next step would edit without the text.
        state = { visible: new Set(), shown: new Set(), matched: new Map(), directory: undefined }
        sessions.set(sessionID, state)
      }
      return state
    }
    const note = (state, hits) => {
      for (const hit of hits) {
        const previous = state.matched.get(hit.rule.id)
        if (!previous) {
          state.matched.set(hit.rule.id, { rule: hit.rule, files: [...hit.files] })
          continue
        }
        for (const file of hit.files) if (!previous.files.includes(file)) previous.files.push(file)
      }
    }
    const directoryOf = async (sessionID, state) => {
      if (state.directory === undefined) {
        const info = await ctx.session.get({ sessionID }).catch(() => undefined)
        state.directory = info?.location?.directory ?? info?.directory ?? ctx.location?.directory ?? ""
      }
      return state.directory
    }
    const known = (state, id) => state.visible.has(id) || state.shown.has(id)

    await ctx.session.hook("context", (input) => {
      const state = stateOf(input.sessionID)
      state.visible = visibleRules(input.messages)
      state.shown.clear()
      // A rule that already matched stays due until its full text is in the conversation again.
      // Putting it here, before any tool runs, is what the model reads even when the earlier
      // tool error was dropped or the history was compacted.
      const due = []
      for (const hit of state.matched.values()) {
        if (state.visible.has(hit.rule.id)) continue
        due.push(hit)
        state.shown.add(hit.rule.id)
      }
      // Every session, fresh from disk each time: an off switch in the GUI takes effect on the very next message.
      const active = currentAlways()
      const parts = []
      if (active.length) parts.push(active.map((rule) => rule.body).join("\n\n"))
      if (due.length) parts.push(due.map((hit) => fullBlock(hit.rule, hit.files)).join("\n\n"))
      if (parts.length) input.system = [...(input.system ?? []), { type: "text", text: parts.join("\n\n") }]
    })

    // A first change to a file whose rule the model has not seen yet does not run. The error carries the rule, so
    // the retry is made with it in view.
    await ctx.tool.hook("execute.before", async (input) => {
      if (!gate || !WRITING_TOOLS.has(input.tool)) return
      const active = currentRules()
      if (!active.length) return
      const state = stateOf(input.sessionID)
      const { files, written } = touched(input.tool, input.input)
      const hits = applicable(active, files, written, await directoryOf(input.sessionID, state))
      note(state, hits)
      const missing = hits.filter((hit) => !known(state, hit.rule.id))
      if (!missing.length) return
      for (const hit of missing) state.shown.add(hit.rule.id)
      throw new Error(
        [
          "Dieser Schritt wurde nicht ausgeführt, weil für die Datei eine Vorgabe gilt, die noch nicht im Kontext stand.",
          "Lies die Vorgabe und wiederhole den Schritt so, dass er ihr entspricht.",
          "",
          ...missing.map((hit) => fullBlock(hit.rule, hit.files)),
        ].join("\n"),
      )
    })

    await ctx.tool.hook("execute.after", async (input) => {
      if (input.status !== "completed" || !FILE_TOOLS.has(input.tool)) return
      const active = currentRules()
      if (!active.length) return
      try {
        const state = stateOf(input.sessionID)
        const { files, written } = touched(input.tool, input.input)
        const text = input.tool === "read" ? resultText(input.result) : written
        const hits = applicable(active, files, text, await directoryOf(input.sessionID, state))
        note(state, hits)
        if (!hits.length) return
        const blocks = hits.map((hit) => {
          if (known(state, hit.rule.id)) return referenceBlock(hit.rule, hit.files)
          state.shown.add(hit.rule.id)
          return fullBlock(hit.rule, hit.files)
        })
        input.result = withAppended(input.result, blocks.join("\n\n"))
      } catch {
        return
      }
    })
  },
}
