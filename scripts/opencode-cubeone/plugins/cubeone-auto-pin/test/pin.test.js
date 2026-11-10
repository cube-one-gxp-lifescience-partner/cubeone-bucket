import assert from "node:assert/strict"
import test from "node:test"
import plugin from "../server.js"
import { pinRequest, pinRequestBody, readRoutedModel, routedModel } from "../pin.js"

const ALLOWED = ["anthropic/claude-sonnet-5.5", "openai/gpt-6.1-sol", "mistralai/mistral-medium-3-5"]
const PROVIDER = { zdr: true, data_collection: "deny", only: ["google-vertex/europe"], allow_fallbacks: false }

function autoBody() {
  return {
    model: "openrouter/auto",
    messages: [{ role: "user", content: "hi" }],
    provider: structuredClone(PROVIDER),
    plugins: [{ id: "auto-router", allowed_models: [...ALLOWED] }, { id: "web" }],
  }
}

function post(body) {
  return new Request("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer x" },
    body: JSON.stringify(body),
  })
}

function sse(chunks) {
  const encoder = new TextEncoder()
  return new Response(
    new ReadableStream({
      start(controller) {
        for (const chunk of chunks) controller.enqueue(encoder.encode(chunk))
        controller.close()
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  )
}

test("routedModel reads the routed slug and ignores the router id", () => {
  assert.equal(routedModel('data: {"id":"x","model":"anthropic/claude-sonnet-5.5","choices":[]}'), "anthropic/claude-sonnet-5.5")
  assert.equal(routedModel('{"model":"openrouter/auto"}'), undefined)
  assert.equal(routedModel(': OPENROUTER PROCESSING\n\n'), undefined)
  assert.equal(routedModel('{"model":"not a slug"}'), undefined)
  assert.equal(routedModel(undefined), undefined)
})

test("pinRequestBody swaps the router for the slug and keeps provider and other plugins", () => {
  const body = autoBody()
  assert.equal(pinRequestBody(body, "anthropic/claude-sonnet-5.5"), true)
  assert.equal(body.model, "anthropic/claude-sonnet-5.5")
  assert.deepEqual(body.plugins, [{ id: "web" }])
  assert.deepEqual(body.provider, PROVIDER)
  assert.equal(body.messages.length, 1)
})

test("pinRequestBody drops an empty plugin list", () => {
  const body = autoBody()
  body.plugins = [body.plugins[0]]
  assert.equal(pinRequestBody(body, "openai/gpt-6.1-sol"), true)
  assert.equal("plugins" in body, false)
})

test("pinRequestBody accepts a dated variant of an allowed model", () => {
  const body = autoBody()
  assert.equal(pinRequestBody(body, "anthropic/claude-sonnet-5.5-20261001"), true)
  assert.equal(body.model, "anthropic/claude-sonnet-5.5-20261001")
})

test("pinRequestBody refuses a model the router may not choose and non-router bodies", () => {
  const body = autoBody()
  assert.equal(pinRequestBody(body, "anthropic/claude-opus-5.5"), false)
  assert.equal(body.model, "openrouter/auto")
  assert.equal(pinRequestBody({ model: "other/model", plugins: [] }, "openai/gpt-6.1-sol"), false)
  assert.equal(pinRequestBody({ model: "openrouter/auto" }, "openai/gpt-6.1-sol"), false)
  assert.equal(pinRequestBody(null, "openai/gpt-6.1-sol"), false)
})

test("pinRequest returns a pinned copy with a correct length and keeps headers", async () => {
  const request = post(autoBody())
  const pinned = await pinRequest(request, "openai/gpt-6.1-sol")
  assert.notEqual(pinned, request)
  const body = await pinned.json()
  assert.equal(body.model, "openai/gpt-6.1-sol")
  assert.equal(pinned.headers.get("authorization"), "Bearer x")
  assert.equal(pinned.headers.has("content-length"), false)
})

test("pinRequest leaves unrelated and unreadable requests alone", async () => {
  const get = new Request("https://openrouter.ai/api/v1/models")
  assert.equal(await pinRequest(get, "openai/gpt-6.1-sol"), get)
  const broken = new Request("https://openrouter.ai/x", { method: "POST", body: "{nope" })
  assert.equal(await pinRequest(broken, "openai/gpt-6.1-sol"), broken)
  const other = post({ model: "mistralai/mistral-large-4-0", messages: [] })
  assert.equal(await pinRequest(other, "openai/gpt-6.1-sol"), other)
})

test("readRoutedModel reads a streamed answer and leaves the body readable", async () => {
  const response = sse([': OPENROUTER PROCESSING\n\n', 'data: {"model":"anthropic/claude-sonnet-5.5","choices":[{"delta":{"content":"a"}}]}\n\n', "data: [DONE]\n\n"])
  assert.equal(await readRoutedModel(response), "anthropic/claude-sonnet-5.5")
  assert.match(await response.text(), /DONE/)
})

test("readRoutedModel reads a JSON answer and returns undefined without a model", async () => {
  const json = new Response(JSON.stringify({ model: "openai/gpt-6.1-sol", choices: [] }), { headers: { "content-type": "application/json" } })
  assert.equal(await readRoutedModel(json), "openai/gpt-6.1-sol")
  assert.equal(await readRoutedModel(new Response("{}")), undefined)
  assert.equal(await readRoutedModel(new Response(null)), undefined)
})

async function load() {
  const hooks = {}
  const storage = new Map()
  await plugin.setup({
    storage: {
      get: async (key) => storage.get(key),
      set: async (key, value) => void storage.set(key, value),
    },
    session: { hook: async (name, handler, options) => void (hooks[name] = { handler, options }) },
  })
  return { hooks, storage }
}

const auto = { providerID: "openrouter-zdr", id: "openrouter/auto" }

async function answer(hooks, sessionID, slug, extra = {}) {
  const event = { sessionID, kind: "primary", model: auto, response: sse([`data: {"model":"${slug}"}\n\n`]), ...extra }
  await hooks["http.response"].handler(event)
  await new Promise((resolve) => setTimeout(resolve, 20))
  return event
}

async function ask(hooks, sessionID, extra = {}) {
  const event = { sessionID, kind: "primary", model: auto, request: post(autoBody()), ...extra }
  await hooks["http.request"].handler(event)
  return (await event.request.clone().json()).model
}

test("hooks are scoped to the auto provider", async () => {
  const { hooks } = await load()
  assert.deepEqual(hooks["http.request"].options, { providerID: "openrouter-zdr" })
  assert.deepEqual(hooks["http.response"].options, { providerID: "openrouter-zdr" })
})

test("the first routed model is remembered and used for later requests of the same session", async () => {
  const { hooks, storage } = await load()
  assert.equal(await ask(hooks, "ses_1"), "openrouter/auto")
  await answer(hooks, "ses_1", "anthropic/claude-sonnet-5.5")
  assert.equal(storage.get("pin/ses_1"), "anthropic/claude-sonnet-5.5")
  await answer(hooks, "ses_1", "openai/gpt-6.1-sol")
  assert.equal(storage.get("pin/ses_1"), "anthropic/claude-sonnet-5.5")
  assert.equal(await ask(hooks, "ses_1"), "anthropic/claude-sonnet-5.5")
  assert.equal(await ask(hooks, "ses_1", { kind: "compaction" }), "anthropic/claude-sonnet-5.5")
  assert.equal(await ask(hooks, "ses_2"), "openrouter/auto")
})

test("titles, other models and failed answers do not pin or get pinned", async () => {
  const { hooks, storage } = await load()
  await answer(hooks, "ses_t", "openai/gpt-6.1-sol", { kind: "title" })
  await answer(hooks, "ses_t", "openai/gpt-6.1-sol", { model: { providerID: "openrouter-zdr", id: "mistralai/mistral-large-4-0" } })
  await answer(hooks, "ses_t", "openrouter/auto")
  assert.equal(storage.size, 0)
  storage.set("pin/ses_t", "openai/gpt-6.1-sol")
  assert.equal(await ask(hooks, "ses_t", { kind: "title" }), "openrouter/auto")
  assert.equal(await ask(hooks, "ses_t", { model: { providerID: "openrouter-zdr", id: "other" } }), "openrouter/auto")
})

test("a stored pin survives a restart and a pin outside the allow-list is ignored", async () => {
  const { hooks, storage } = await load()
  storage.set("pin/ses_r", "openai/gpt-6.1-sol")
  assert.equal(await ask(hooks, "ses_r"), "openai/gpt-6.1-sol")
  storage.set("pin/ses_x", "anthropic/claude-opus-5.5")
  assert.equal(await ask(hooks, "ses_x"), "openrouter/auto")
})
