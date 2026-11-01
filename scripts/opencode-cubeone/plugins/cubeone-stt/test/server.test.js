import assert from "node:assert/strict"
import test from "node:test"
import plugin, { routedModel, searchResults } from "../src/server.js"

function fakeContext(metadata = {}) {
  const hooks = {}
  const updates = []
  let current = { ...metadata }
  const ctx = {
    options: {},
    searchProviders: [],
    searchDefault: undefined,
    websearch: {
      async transform(callback) {
        callback({
          add: (definition) => ctx.searchProviders.push(definition),
          default: { get: () => ctx.searchDefault, set: (value) => (ctx.searchDefault = value) },
        })
      },
      async providers() {
        return { data: ctx.searchProviders.map(({ id, name }) => ({ id, name })) }
      },
    },
    session: {
      async hook(name, callback) {
        hooks[name] = callback
      },
      async get() {
        return { metadata: current }
      },
      async update(input) {
        updates.push(input)
        current = input.metadata
      },
    },
  }
  return { ctx, hooks, updates }
}

test("reads the selected model from the first SSE event", () => {
  const body = `data: {"id":"gen-1","model":"openrouter/auto","object":"chat.completion.chunk"}\n\ndata: {"id":"gen-1","model":"anthropic/claude-opus-5.5","choices":[]}\n\n`
  assert.equal(routedModel(body), "anthropic/claude-opus-5.5")
})

test("reads a JSON body", () => {
  assert.equal(routedModel('{"id":"gen-2","model":"openai/gpt-5.4","choices":[]}'), "openai/gpt-5.4")
})

test("ignores the router id and values that are not model ids", () => {
  assert.equal(routedModel('{"model":"openrouter/auto"}'), undefined)
  assert.equal(routedModel('{"model":"chat"}'), undefined)
  assert.equal(routedModel(""), undefined)
})

test("stores the routed model and still returns the full response", async () => {
  const { ctx, hooks, updates } = fakeContext({ keep: "yes" })
  await plugin.setup(ctx)
  const payload = 'data: {"model":"openrouter/auto"}\n\ndata: {"model":"anthropic/claude-opus-5.5","choices":[{"delta":{"content":"Hallo"}}]}\n\n'
  const input = {
    kind: "primary",
    sessionID: "ses_1",
    model: { id: "openrouter/auto" },
    response: new Response(payload, { status: 200, headers: { "content-type": "text/event-stream" } }),
  }
  hooks["http.response"](input)
  assert.equal(await input.response.text(), payload)
  for (let attempt = 0; attempt < 20 && updates.length === 0; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.deepEqual(updates, [{ sessionID: "ses_1", metadata: { keep: "yes", routedModel: "anthropic/claude-opus-5.5" } }])
})

test("turns url citations into search results", () => {
  const content = "- **Changelog** — Release notes for 2.2. ([opencode.ai](https://opencode.ai/changelog))\n- **Releases** — Tagged builds. ([github.com](https://github.com/anomalyco/opencode/releases))"
  const results = searchResults({
    choices: [
      {
        message: {
          content,
          annotations: [
            { type: "url_citation", url_citation: { url: "https://opencode.ai/changelog", title: "Changelog", start_index: 50 } },
            { type: "url_citation", url_citation: { url: "https://opencode.ai/changelog", title: "Duplicate", start_index: 50 } },
            { type: "url_citation", url_citation: { url: "javascript:alert(1)", title: "Bad" } },
            { type: "url_citation", url_citation: { url: "https://github.com/anomalyco/opencode/releases", start_index: content.indexOf("Tagged") } },
          ],
        },
      },
    ],
  })
  assert.deepEqual(results, [
    { url: "https://opencode.ai/changelog", time: {}, title: "Changelog", content: "**Changelog** — Release notes for 2.2." },
    { url: "https://github.com/anomalyco/opencode/releases", time: {}, content: "**Releases** — Tagged builds." },
  ])
})

test("registers the ZDR web search provider and disables Plannotator sharing", async () => {
  delete process.env.PLANNOTATOR_SHARE
  const { ctx } = fakeContext()
  await plugin.setup(ctx)
  assert.equal(process.env.PLANNOTATOR_SHARE, "disabled")
  assert.deepEqual(ctx.searchProviders.map((provider) => provider.id), ["cubeone-zdr"])
  assert.equal(ctx.searchDefault, "cubeone-zdr")
})

test("restores the web search provider on the next turn after OpenCode dropped it", async () => {
  const { ctx, hooks } = fakeContext()
  await plugin.setup(ctx)
  ctx.searchProviders = []
  ctx.searchDefault = undefined
  await hooks.context({ sessionID: "ses_1", agent: "researcher", system: [] })
  assert.deepEqual(ctx.searchProviders.map((provider) => provider.id), ["cubeone-zdr"])
  assert.equal(ctx.searchDefault, "cubeone-zdr")
  await hooks.context({ sessionID: "ses_1", agent: "researcher", system: [] })
  assert.equal(ctx.searchProviders.length, 1)
})

test("leaves web search alone when the managed config disables it", async () => {
  const { ctx } = fakeContext()
  ctx.options = { search: false }
  await plugin.setup(ctx)
  assert.deepEqual(ctx.searchProviders, [])
})

test("gives build the orchestration brief only in orchestrated sessions", async () => {
  const { ctx, hooks, updates } = fakeContext()
  await plugin.setup(ctx)

  const plain = { sessionID: "ses_plain", agent: "build", system: [] }
  await hooks.context(plain)
  assert.equal(plain.system.length, 0)

  await hooks.context({ sessionID: "ses_orch", agent: "orchestrator", system: [] })
  assert.deepEqual(updates.at(-1), { sessionID: "ses_orch", metadata: { orchestration: true } })

  const after = { sessionID: "ses_orch", agent: "build", system: [{ type: "text", text: "base" }] }
  await hooks.context(after)
  assert.equal(after.system.length, 2)
  assert.match(after.system[1].text, /approved/)
})
