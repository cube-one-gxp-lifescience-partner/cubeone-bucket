import test from "node:test"
import assert from "node:assert/strict"
import { createDisplayFilter, createSseRewriter, rewriteJsonResponse, stripDcpDisplay } from "../display.js"
import plugin from "../server.js"

const GUIDANCE = [
  "Compressed block context:",
  "- Active compressed blocks in this session: 10 (@b1@, @b2@, @b3@, @b6@, @b7@, @b8@, @b9@, @b10@)",
  "- If your selected compression range includes any listed block or needs to reference one, include each required placeholder exactly once in the summary using `@b1@`.",
  "@dcp-id-85a9d947dce478ac85f8b9e6373dbb0d1d6894a53e1a30ad6a",
].join("\n")

test("removes the compressed-block reminder and its placeholders", () => {
  const answer = "Die Änderung liegt in server.js."
  assert.equal(stripDcpDisplay(`${GUIDANCE}\n\n${answer}`), answer)
})

test("removes a system reminder wrapped around the same guidance", () => {
  const wrapped = `<dcp-system-reminder>\n${GUIDANCE}\n</dcp-system-reminder>\n\nFertig.`
  assert.equal(stripDcpDisplay(wrapped), "Fertig.")
})

test("keeps ordinary text, including an email address", () => {
  const text = "Schreib an marvin@cubeone.de und lass @b1@ aus der Antwort."
  assert.equal(stripDcpDisplay(text), "Schreib an marvin@cubeone.de und lass  aus der Antwort.")
})

test("rejoins a reminder that arrives in several server-sent chunks", () => {
  const rewriter = createSseRewriter()
  const chunks = [
    'data: {"choices":[{"delta":{"content":"Compressed blo"}}]}\n',
    'data: {"choices":[{"delta":{"content":"ck context:\\n- Active compressed blocks in this session: 10 (@b1@, @b2@)\\n"}}]}\n',
    'data: {"choices":[{"delta":{"content":"Die Änderung liegt in server.js."}}]}\n',
    "data: [DONE]\n",
  ]
  const raw = chunks.map((chunk) => rewriter.push(chunk)).join("") + rewriter.flush()
  const content = []
  for (const line of raw.split("\n")) {
    if (!line.startsWith("data: ") || line.includes("[DONE]")) continue
    const json = JSON.parse(line.slice(6))
    const text = json.choices?.[0]?.delta?.content
    if (text) content.push(text)
  }
  assert.equal(content.join(""), "Die Änderung liegt in server.js.")
})

test("removes compact tags at every possible streaming boundary", () => {
  for (const tag of ["@1@", "@123@", "@b1@", "@b123@", "@blocked@"]) {
    const text = `Vor ${tag} danach`
    for (let split = 0; split <= text.length; split++) {
      const filter = createDisplayFilter()
      const result = filter.push(text.slice(0, split)) + filter.push(text.slice(split)) + filter.flush()
      assert.equal(result, "Vor  danach", `${tag} split at ${split}`)
    }
    const filter = createDisplayFilter()
    assert.equal([...text].map((character) => filter.push(character)).join("") + filter.flush(), "Vor  danach", `${tag} character stream`)
  }
})

test("preserves ordinary @ text across chunk boundaries", () => {
  const text = "Mail an a@example.de, @bob und @version."
  const filter = createDisplayFilter()
  assert.equal([...text].map((character) => filter.push(character)).join("") + filter.flush(), text)
})

test("filters plain JSON HTTP completions before they are stored", async () => {
  const hooks = new Map()
  await plugin.setup({ session: { hook: async (name, fn) => hooks.set(name, fn) }, event: { subscribe: async function* () {} } })
  const payload = { choices: [{ message: { role: "assistant", content: "Erledigt @12@ und @b4@." }, finish_reason: "stop" }] }
  const event = { response: new Response(JSON.stringify(payload), { headers: { "content-type": "application/json" } }) }
  await hooks.get("http.response")(event)
  const result = await event.response.json()
  assert.equal(result.choices[0].message.content, "Erledigt  und .")
})

test("JSON completions keep independent choices, structured parts and tool arguments", () => {
  const payload = { choices: [
    { message: { content: "one @", tool_calls: [{ function: { arguments: "keep @1@" } }] } },
    { message: { content: [{ type: "text", text: "two @b2@ @" }, { type: "image_url", image_url: { url: "https://example.test/@1@" } }] } },
  ] }
  const result = JSON.parse(rewriteJsonResponse(JSON.stringify(payload)))
  assert.equal(result.choices[0].message.content, "one @")
  assert.equal(result.choices[1].message.content[0].text, "two  @")
  assert.deepEqual(result.choices[0].message.tool_calls, payload.choices[0].message.tool_calls)
  assert.deepEqual(result.choices[1].message.content[1], payload.choices[1].message.content[1])
})

test("JSON Anthropic and Responses text is filtered without changing non-text parts", () => {
  const anthropic = { content: [{ type: "text", text: "answer @123@" }, { type: "tool_use", input: { value: "@123@" } }] }
  const result = JSON.parse(rewriteJsonResponse(JSON.stringify(anthropic)))
  assert.equal(result.content[0].text, "answer ")
  assert.deepEqual(result.content[1], anthropic.content[1])
  const responses = { output: [{ type: "message", content: [{ type: "output_text", text: "answer @b12@" }] }, { type: "function_call", arguments: "@b12@" }] }
  const output = JSON.parse(rewriteJsonResponse(JSON.stringify(responses)))
  assert.equal(output.output[0].content[0].text, "answer ")
  assert.deepEqual(output.output[1], responses.output[1])
})

test("filters compact tags split across WebSocket JSON frames", async () => {
  const hooks = new Map()
  await plugin.setup({ session: { hook: async (name, fn) => hooks.set(name, fn) }, event: { subscribe: async function* () {} } })
  const chunks = ["Vor @b", "12", "@ danach @42@", "."]
  let output = ""
  for (const chunk of chunks) {
    const event = { sessionID: "test-stream", frame: JSON.stringify({ choices: [{ delta: { content: chunk } }] }) }
    hooks.get("experimental.ws.receive")(event)
    output += JSON.parse(event.frame).choices[0].delta.content
  }
  const finish = { sessionID: "test-stream", frame: JSON.stringify({ choices: [{ delta: {}, finish_reason: "stop" }] }) }
  hooks.get("experimental.ws.receive")(finish)
  output += JSON.parse(finish.frame).choices[0].delta.content ?? ""
  assert.equal(output, "Vor  danach .")
})

test("HTTP SSE filters byte-split events without changing tools or normal text", async () => {
  const hooks = new Map()
  await plugin.setup({ session: { hook: async (name, fn) => hooks.set(name, fn) }, event: { subscribe: async function* () {} } })
  const payload = ['Grüße @', 'b12@ und @123@', ' an a@b.de.']
    .map((content) => `data: ${JSON.stringify({ choices: [{ delta: { content, tool_calls: [{ function: { arguments: 'keep @1@' } }] } }] })}\n\n`).join('')
    + 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'
  const bytes = new TextEncoder().encode(payload)
  const stream = new ReadableStream({ start(controller) { for (const byte of bytes) controller.enqueue(new Uint8Array([byte])); controller.close() } })
  const event = { response: new Response(stream, { headers: { 'content-type': 'text/event-stream' } }) }
  await hooks.get('http.response')(event)
  const output = await event.response.text()
  const messages = output.split('\n').filter((line) => line.startsWith('data: {')).map((line) => JSON.parse(line.slice(6)))
  assert.equal(messages.map((message) => message.choices[0].delta.content ?? '').join(''), 'Grüße  und  an a@b.de.')
  assert.equal(messages[0].choices[0].delta.tool_calls[0].function.arguments, 'keep @1@')
  assert.ok(output.includes('data: [DONE]'))
})

test("flushes a held placeholder when the model stops", () => {
  const rewriter = createSseRewriter()
  const raw = rewriter.push('data: {"choices":[{"index":0,"delta":{"content":"Hallo @b1"},"finish_reason":"stop"}]}\n') + rewriter.flush()
  const json = JSON.parse(raw.split("\n").find((line) => line.startsWith("data: {")).slice(6))
  assert.equal(json.choices[0].delta.content, "Hallo ")
})
