import assert from "node:assert/strict"
import test from "node:test"
import { deflateSync } from "node:zlib"
import { documentText } from "../src/brief.js"

const textEncoder = new TextEncoder()

test("reads a markdown brief", async () => {
  const text = await documentText("Ziele.md", textEncoder.encode("\uFEFF# Ziel\n\nDie App speichert lokal.\n"))
  assert.equal(text, "# Ziel\n\nDie App speichert lokal.")
})

test("rejects other file types", async () => {
  await assert.rejects(documentText("brief.docx", textEncoder.encode("Hallo")), /PDF oder Markdown/)
})

test("reads text from an uncompressed PDF", async () => {
  const stream = "BT (Anforderungen und Ziele) Tj ET\n"
  const pdf = `%PDF-1.4
1 0 obj
<< /Length ${stream.length} >>
stream
${stream}endstream
endobj
%%EOF`
  const text = await documentText("anforderungen.pdf", textEncoder.encode(pdf))
  assert.match(text, /Anforderungen und Ziele/)
})

test("reads text from a FlateDecode PDF", async () => {
  const plain = "BT (Lokale Speicherung) Tj ET\n"
  const compressed = deflateSync(textEncoder.encode(plain))
  const header = `%PDF-1.4
1 0 obj
<< /Filter /FlateDecode /Length ${compressed.length} >>
stream
`
  const footer = "\nendstream\nendobj\n%%EOF"
  const bytes = new Uint8Array(textEncoder.encode(header).length + compressed.length + textEncoder.encode(footer).length)
  bytes.set(textEncoder.encode(header), 0)
  bytes.set(compressed, textEncoder.encode(header).length)
  bytes.set(textEncoder.encode(footer), textEncoder.encode(header).length + compressed.length)
  const text = await documentText("anforderungen.pdf", bytes)
  assert.match(text, /Lokale Speicherung/)
})
