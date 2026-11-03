import { execFileSync } from "node:child_process"

const WEBSEARCH_ID = "cubeone-zdr"
const CHAT_COMPLETIONS = "https://openrouter.ai/api/v1/chat/completions"
const SEARCH_TIMEOUT_MS = 90_000
const MAX_RESULTS = 8

const SEARCH_SYSTEM = [
  "You are a web search backend. Search the web for the user's query with the web search tool. Do not answer from memory.",
  "Then list the most relevant sources, one per line. For each source write two or three factual sentences about what it says on the query, in the language of the query.",
].join(" ")

const BUILD_ORCHESTRATION = `This session was planned by the orchestrator and its plan was approved by the user. Carry it out as the orchestrator would:
- Work through the approved work packages in the plan's order and respect their dependencies. Start independent packages in parallel.
- Delegate each package with the subagent tool to the agent the plan names: developer for implementation, quick for small mechanical changes, reviewer for an independent review, researcher for external facts, architect for design questions. Give each subagent a self-contained task, because it does not see this conversation.
- After each implementation package, let reviewer check it against the plan and fix what it reports before you move on.
- Do small glue changes yourself only when delegating would cost more than the change.
- At the end, check every acceptance criterion of the plan and report which are met, with evidence.`

function option(options, key, fallback) {
  const value = options?.[key]
  return typeof value === "string" && value.trim() ? value.trim() : fallback
}

function metadataOf(info) {
  const metadata = info?.metadata
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) return {}
  return metadata
}

async function mergeMetadata(session, sessionID, key, value) {
  const info = await session.get({ sessionID })
  const previous = metadataOf(info)
  if (previous[key] === value) return
  await session.update({ sessionID, metadata: { ...previous, [key]: value } })
}

function excerpt(text, start) {
  if (!text || typeof start !== "number") return ""
  const from = text.lastIndexOf("\n", start) + 1
  const to = text.indexOf("\n", start)
  return text
    .slice(from, to === -1 ? undefined : to)
    .replace(/\(\[[^\]]*\]\([^)]*\)\)/g, "")
    .replace(/^\s*(?:[-*]|\d+\.)\s+/, "")
    .trim()
}

export function searchResults(json, limit = MAX_RESULTS) {
  const message = json?.choices?.[0]?.message
  const text = typeof message?.content === "string" ? message.content : ""
  const results = new Map()
  for (const annotation of message?.annotations ?? []) {
    const cite = annotation?.type === "url_citation" ? annotation.url_citation : undefined
    const url = cite?.url
    if (typeof url !== "string" || !/^https?:\/\//.test(url) || results.has(url)) continue
    const result = { url, time: {} }
    if (typeof cite.title === "string" && cite.title) result.title = cite.title
    const content = typeof cite.content === "string" && cite.content ? cite.content : excerpt(text, cite.start_index)
    if (content) result.content = content
    results.set(url, result)
    if (results.size >= limit) break
  }
  return [...results.values()]
}

let cachedKey = ""

export function parseRegistryValue(output, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const match = new RegExp(`${escaped}\\s+REG_(?:EXPAND_)?SZ\\s+(\\S+)`).exec(String(output ?? ""))
  return match?.[1]?.trim() ?? ""
}

function queryRegistry(hive, name) {
  const args = ["query", hive, "/v", name]
  if (hive.startsWith("HKLM\\")) args.push("/reg:64")
  const output = execFileSync("reg.exe", args, {
    encoding: "utf8",
    windowsHide: true,
    stdio: ["ignore", "pipe", "ignore"],
  })
  return parseRegistryValue(output, name)
}

// The desktop server keeps the environment it was started with. The key itself
// lives in HKLM\SOFTWARE\cubeone\OpenCode, value OpenRouterApiKey.
function remember(key) {
  if (!key) return ""
  cachedKey = key
  // OpenCode's provider reads this variable from the process. It is not written to disk.
  process.env.OPENROUTER_API_KEY = key
  return key
}

function readApiKey() {
  if (cachedKey) return remember(cachedKey)
  if (process.platform === "win32") {
    try {
      const fromRegistry = queryRegistry("HKLM\\SOFTWARE\\cubeone\\OpenCode", "OpenRouterApiKey")
      if (fromRegistry) return remember(fromRegistry)
    } catch {
      // The value is simply not there.
    }
  }
  const fromEnv = process.env.OPENROUTER_API_KEY?.trim()
  if (fromEnv) return remember(fromEnv)
  if (process.platform !== "win32") return ""
  for (const hive of ["HKCU\\Environment", "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment"]) {
    try {
      const value = queryRegistry(hive, "OPENROUTER_API_KEY")
      if (value) return remember(value)
    } catch {
      continue
    }
  }
  return ""
}

readApiKey()

async function search(query, settings, signal) {
  const apiKey = readApiKey()
  if (!apiKey) throw new Error("OpenRouterApiKey fehlt in HKLM\\SOFTWARE\\cubeone\\OpenCode.")
  const response = await fetch(CHAT_COMPLETIONS, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "https://cubeone.de",
      "X-Title": "OpenCode cube one",
    },
    body: JSON.stringify({
      model: settings.model,
      provider: { zdr: true, data_collection: "deny", only: [settings.endpoint], allow_fallbacks: false },
      messages: [
        { role: "system", content: SEARCH_SYSTEM },
        { role: "user", content: query },
      ],
      tools: [{ type: "openrouter:web_search", parameters: { engine: "native", max_results: MAX_RESULTS } }],
      reasoning: { effort: "low" },
      max_tokens: 2000,
    }),
    signal: AbortSignal.any([signal, AbortSignal.timeout(SEARCH_TIMEOUT_MS)]),
  })
  const json = await response.json().catch(() => ({}))
  if (!response.ok) {
    throw new Error(`Websuche fehlgeschlagen: OpenRouter ${response.status}${json?.error?.message ? `: ${json.error.message}` : ""}`)
  }
  return searchResults(json)
}

export default {
  id: "cubeone-stt",
  async setup(ctx) {
    // Plannotator shares plans through its public share service unless this is set in its process.
    process.env.PLANNOTATOR_SHARE = "disabled"

    const searchSettings = {
      model: option(ctx.options, "search_model", "openai/gpt-6-luna"),
      endpoint: option(ctx.options, "search_endpoint", "azure/eu"),
    }
    const searchEnabled = ctx.options?.search !== false
    const registerSearch = () =>
      ctx.websearch.transform((editor) => {
        editor.add({
          id: WEBSEARCH_ID,
          name: "OpenRouter ZDR (Azure EU)",
          execute: (input, context) => search(input.query, searchSettings, context.signal),
        })
        editor.default.set(WEBSEARCH_ID)
      })
    // OpenCode 2.2.5 drops every web search provider when it reloads its plugins shortly after startup, and it
    // does not run setup again. Session hooks survive, so each turn restores the provider when it is missing.
    const ensureSearch = async () => {
      const listed = await ctx.websearch.providers()
      if (listed?.data?.some((provider) => provider.id === WEBSEARCH_ID)) return
      await registerSearch()
    }
    if (searchEnabled) await registerSearch()

    const orchestrated = new Set()
    await ctx.session.hook("context", async (input) => {
      if (searchEnabled) await ensureSearch().catch(() => {})
      if (input.agent === "orchestrator") {
        if (orchestrated.has(input.sessionID)) return
        orchestrated.add(input.sessionID)
        await mergeMetadata(ctx.session, input.sessionID, "orchestration", true)
        return
      }
      if (input.agent !== "build") return
      if (!orchestrated.has(input.sessionID)) {
        const info = await ctx.session.get({ sessionID: input.sessionID })
        if (metadataOf(info).orchestration !== true) return
        orchestrated.add(input.sessionID)
      }
      input.system = [...(input.system ?? []), { type: "text", text: BUILD_ORCHESTRATION }]
    })
  },
}
