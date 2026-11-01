import assert from "node:assert/strict"
import test from "node:test"
import plugin, { routedModel } from "../src/server.js"

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
  let callback
  const updates = []
  await plugin.setup({
    session: {
      async hook(_name, cb) {
        callback = cb
      },
      async get() {
        return { metadata: { keep: "yes" } }
      },
      async update(input) {
        updates.push(input)
      },
    },
  })
  const payload = 'data: {"model":"openrouter/auto"}\n\ndata: {"model":"anthropic/claude-opus-5.5","choices":[{"delta":{"content":"Hallo"}}]}\n\n'
  const input = {
    kind: "primary",
    sessionID: "ses_1",
    model: { id: "openrouter/auto" },
    response: new Response(payload, { status: 200, headers: { "content-type": "text/event-stream" } }),
  }
  callback(input)
  assert.equal(await input.response.text(), payload)
  for (let attempt = 0; attempt < 20 && updates.length === 0; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.deepEqual(updates, [{ sessionID: "ses_1", metadata: { keep: "yes", routedModel: "anthropic/claude-opus-5.5" } }])
})
