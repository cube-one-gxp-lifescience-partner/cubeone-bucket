import test from "node:test"
import assert from "node:assert/strict"
import { createSseRewriter, stripDcpDisplay } from "../display.js"

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

test("flushes a held placeholder when the model stops", () => {
  const rewriter = createSseRewriter()
  const raw = rewriter.push('data: {"choices":[{"index":0,"delta":{"content":"Hallo @b1"},"finish_reason":"stop"}]}\n') + rewriter.flush()
  const json = JSON.parse(raw.split("\n").find((line) => line.startsWith("data: {")).slice(6))
  assert.equal(json.choices[0].delta.content, "Hallo ")
})
