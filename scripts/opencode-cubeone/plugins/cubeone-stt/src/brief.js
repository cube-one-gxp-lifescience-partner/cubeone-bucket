const MAX_CHARS = 80_000

function extension(name) {
  const base = String(name ?? "").split(/[/\\]/).pop() ?? ""
  const dot = base.lastIndexOf(".")
  return dot < 0 ? "" : base.slice(dot + 1).toLowerCase()
}

function decodeUtf8(bytes) {
  return new TextDecoder("utf-8", { fatal: false }).decode(bytes).replace(/^\uFEFF/, "")
}

function latin1(bytes) {
  return new TextDecoder("latin1").decode(bytes)
}

function pdfLiteral(source, start) {
  let value = ""
  for (let index = start; index < source.length; index++) {
    const char = source[index]
    if (char === "\\") {
      const next = source[index + 1]
      if (next === undefined) break
      const named = { n: "\n", r: "\r", t: "\t", b: "\b", f: "\f", "\\": "\\", "(": "(", ")": ")" }
      if (named[next] !== undefined) {
        value += named[next]
        index += 1
        continue
      }
      if (next >= "0" && next <= "7") {
        let octal = next
        let consumed = 1
        while (consumed < 3 && source[index + 1 + consumed] >= "0" && source[index + 1 + consumed] <= "7") {
          octal += source[index + 1 + consumed]
          consumed += 1
        }
        value += String.fromCharCode(Number.parseInt(octal, 8))
        index += consumed
        continue
      }
      value += next
      index += 1
      continue
    }
    if (char === ")") return { value, next: index + 1 }
    value += char
  }
  return { value, next: source.length }
}

function pdfHex(source, start) {
  let hex = ""
  for (let index = start; index < source.length; index++) {
    const char = source[index]
    if (char === ">") {
      if (hex.length % 2 === 1) hex += "0"
      const bytes = new Uint8Array(hex.length / 2)
      for (let pair = 0; pair < bytes.length; pair++) bytes[pair] = Number.parseInt(hex.slice(pair * 2, pair * 2 + 2), 16)
      const value = bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff
        ? new TextDecoder("utf-16be").decode(bytes.subarray(2))
        : latin1(bytes)
      return { value, next: index + 1 }
    }
    if (/[0-9a-fA-F]/.test(char)) hex += char
    else if (!/\s/.test(char)) break
  }
  return { value: "", next: source.length }
}

function stringsFromContent(source) {
  const parts = []
  for (let index = 0; index < source.length; index++) {
    const char = source[index]
    if (char === "(") {
      const parsed = pdfLiteral(source, index + 1)
      if (parsed.value.trim()) parts.push(parsed.value)
      index = parsed.next - 1
      continue
    }
    if (char === "<" && source[index + 1] !== "<") {
      const parsed = pdfHex(source, index + 1)
      if (parsed.value.trim()) parts.push(parsed.value)
      index = parsed.next - 1
    }
  }
  return parts
}

async function inflate(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate"))
  return new Uint8Array(await new Response(stream).arrayBuffer())
}

async function pdfText(bytes) {
  const source = latin1(bytes)
  const parts = []
  const marker = /stream\r?\n/g
  let match
  while ((match = marker.exec(source))) {
    const start = match.index + match[0].length
    const end = source.indexOf("endstream", start)
    if (end < 0) break
    const dict = source.slice(Math.max(0, match.index - 500), match.index)
    let raw = bytes.subarray(start, end)
    const length = Number(/\/Length\s+(\d+)/.exec(dict)?.[1])
    if (length > 0 && length <= raw.length) raw = raw.subarray(0, length)
    else if (raw[raw.length - 1] === 0x0d) raw = raw.subarray(0, raw.length - 1)
    let content = raw
    if (/FlateDecode/.test(dict)) {
      try {
        content = await inflate(raw)
      } catch {
        continue
      }
    }
    parts.push(...stringsFromContent(latin1(content)))
  }
  return parts.join("\n")
}

function limit(text) {
  const trimmed = text.replace(/\n{3,}/g, "\n\n").trim()
  if (!trimmed) throw new Error("Die Datei enthält keinen Text.")
  if (trimmed.length <= MAX_CHARS) return trimmed
  return `${trimmed.slice(0, MAX_CHARS).trimEnd()}\n\n[… gekürzt …]`
}

export async function documentText(name, bytes) {
  const kind = extension(name)
  if (kind !== "pdf" && kind !== "md" && kind !== "markdown") {
    throw new Error("Nur PDF oder Markdown.")
  }
  const text = kind === "pdf" ? await pdfText(bytes) : decodeUtf8(bytes)
  return limit(text)
}
