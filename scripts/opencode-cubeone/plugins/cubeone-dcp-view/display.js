// DCP V2 writes compact ids (@b1@, @4@) and a "Compressed block context" reminder into the
// text the model sees. The model copies that reminder into its answer, and the chat then
// shows the raw placeholders. This removes only that housekeeping from assistant text.

const COMPACT_TAG = /@(?:[1-9]\d*|b[1-9]\d*|blocked)@(?:[ \t]+\[(?:low|medium|high)\])?/gi
const UNPAIRED_DCP_TAG = /<\/?dcp(?:-[a-z0-9-]+)?\b[^>\n]*>/gi
const DCP_ID = /@dcp-id-[0-9a-f]{8,128}@?/gi

const MARKERS = [
  "<dcp-system-reminder",
  "<dcp-message-id",
  "</dcp",
  "Compressed block context:",
  "Message priority context:",
  "@dcp-id-",
]

function stripTokens(text) {
  return text.replace(COMPACT_TAG, "").replace(UNPAIRED_DCP_TAG, "").replace(DCP_ID, "")
}

function stripIncomplete(text) {
  return text.replace(/@(?:b[1-9]\d*|[1-9]\d*|blocked)$/i, "").replace(/@dcp-id-[0-9a-f]*$/i, "")
}

function earliestMarker(text) {
  let at = -1
  const lower = text.toLowerCase()
  for (const marker of MARKERS) {
    const found = lower.indexOf(marker.toLowerCase())
    if (found !== -1 && (at === -1 || found < at)) at = found
  }
  return at
}

function holdLength(text) {
  let keep = 0
  const max = Math.min(text.length, 96)
  for (let len = max; len > 0; len--) {
    const suffix = text.slice(text.length - len).toLowerCase()
    if (MARKERS.some((marker) => marker.toLowerCase().startsWith(suffix) && suffix.length < marker.length)) {
      keep = len
      break
    }
  }
  // A trailing @ can close a complete tag. Holding it separately would leak the
  // preceding @1 or @b1 into the stream before the token can be removed.
  const endsWithCompleteTag = /@(?:[1-9]\d*|b[1-9]\d*|blocked)@$/i.test(text)
  if (endsWithCompleteTag && keep === 1) keep = 0
  const compact = text.match(/@(?:b[1-9]\d*|[1-9]\d*)?$/i)
  if (!endsWithCompleteTag && compact && compact[0].length > keep) keep = compact[0].length
  if (!endsWithCompleteTag) {
    const lower = text.toLowerCase()
    for (let len = 1; len < '@blocked@'.length; len++) {
      if (lower.endsWith('@blocked@'.slice(0, len))) keep = Math.max(keep, len)
    }
  }
  const dcpId = text.match(/@dcp-id-(?:[0-9a-f]{0,128})?$/i)
  if (dcpId && dcpId[0].length > keep) keep = dcpId[0].length
  return keep
}

function consumeTag(text, flush) {
  const end = text.indexOf(">")
  if (end === -1) return flush && text.length < 240 ? text.length : null
  const tag = text.slice(0, end + 1)
  const name = /^<([A-Za-z0-9-]+)/.exec(tag)?.[1]
  if (name && /^dcp-(?:system-reminder|message-id)$/i.test(name)) {
    const close = `</${name}>`
    const at = text.toLowerCase().indexOf(close.toLowerCase())
    if (at === -1) return flush ? text.length : null
    return at + close.length
  }
  if (/^<\/?dcp/i.test(tag)) return end + 1
  return 0
}

function isGuidanceLine(line) {
  return (
    /^[ \t]*$/.test(line) ||
    /^[ \t]*[-*•]/.test(line) ||
    /^[ \t]*@dcp-id-[0-9a-f]+@?[ \t]*$/i.test(line) ||
    /^[ \t]*<\/?dcp/i.test(line)
  )
}

function consumeGuidance(text, flush) {
  const nl = text.indexOf("\n")
  if (nl === -1) return flush ? text.length : null
  let i = nl + 1
  while (i <= text.length) {
    const next = text.indexOf("\n", i)
    const line = next === -1 ? text.slice(i) : text.slice(i, next)
    if (next === -1 && !flush) return null
    if (!isGuidanceLine(line)) return i
    if (next === -1) return text.length
    i = next + 1
  }
  return i
}

function consumeDcpId(text, flush) {
  const match = /^@dcp-id-([0-9a-f]*)@?/i.exec(text)
  if (!match) return 0
  const hex = match[1]
  const complete = hex.length >= 8 && match[0].length <= text.length && (text.length === match[0].length || !/^[0-9a-f]/i.test(text.charAt(match[0].length)))
  if (complete || (flush && hex.length >= 8)) return match[0].length
  if (!flush && hex.length < 128) return null
  return flush ? match[0].length : 0
}

// Returns how many leading characters are a leak, null when more input is required, 0 when it is not a leak.
function consumeLeak(text, flush) {
  const lower = text.toLowerCase()
  if (lower.startsWith("<dcp") || lower.startsWith("</dcp")) return consumeTag(text, flush)
  if (lower.startsWith("compressed block context:") || lower.startsWith("message priority context:")) {
    return consumeGuidance(text, flush)
  }
  if (lower.startsWith("@dcp-id-")) return consumeDcpId(text, flush)
  return 0
}

export function createDisplayFilter() {
  let buf = ""
  function drain(flush) {
    let out = ""
    while (buf.length) {
      const at = earliestMarker(buf)
      if (at === -1) {
        if (flush) {
          out += stripTokens(stripIncomplete(buf))
          buf = ""
          break
        }
        const keep = holdLength(buf)
        out += stripTokens(buf.slice(0, buf.length - keep))
        buf = buf.slice(buf.length - keep)
        break
      }
      if (at > 0) {
        out += stripTokens(buf.slice(0, at))
        buf = buf.slice(at)
      }
      const consumed = consumeLeak(buf, flush)
      if (consumed == null) break
      if (consumed === 0) {
        out += stripTokens(buf.slice(0, 1))
        buf = buf.slice(1)
        continue
      }
      buf = buf.slice(consumed)
    }
    return out
  }
  return {
    push(text) {
      buf += text ?? ""
      return drain(false)
    },
    flush() {
      const out = drain(true)
      buf = ""
      return out
    },
  }
}

export function stripDcpDisplay(text) {
  const filter = createDisplayFilter()
  return (filter.push(text) + filter.flush()).trim()
}

function finishReason(json) {
  if (json?.type === "message_stop" || json?.type === "response.completed") return true
  return Array.isArray(json?.choices) && json.choices.some((choice) => choice?.finish_reason)
}

function writeText(target, key, filter, flush) {
  if (typeof target?.[key] !== "string" || target[key].length === 0) return false
  const next = filter.push(target[key]) + (flush ? filter.flush() : "")
  if (next === target[key]) return false
  target[key] = next
  return true
}

function rewriteMessage(json, filter, flush) {
  let changed = false
  if (Array.isArray(json?.choices)) {
    for (const choice of json.choices) {
      const delta = choice?.delta
      const message = choice?.message
      if (writeText(delta, "content", filter, false)) changed = true
      if (writeText(message, "content", filter, false)) changed = true
      if (Array.isArray(message?.content)) {
        for (const part of message.content) {
          if (part?.type === "text" && writeText(part, "text", filter, false)) changed = true
        }
      }
    }
  }
  if (json?.delta && typeof json.delta === "object") {
    if (writeText(json.delta, "text", filter, false)) changed = true
  } else if (typeof json?.delta === "string" && /output_text|text/i.test(String(json.type ?? ""))) {
    if (writeText(json, "delta", filter, false)) changed = true
  }
  if (flush) {
    const rest = filter.flush()
    if (rest) {
      const choice = json.choices?.[0]
      if (choice?.delta && typeof choice.delta === "object") {
        choice.delta.content = `${choice.delta.content ?? ""}${rest}`
      } else if (choice?.message) {
        if (typeof choice.message.content === "string") choice.message.content += rest
        else choice.message.content = rest
      } else if (json?.delta && typeof json.delta === "object") {
        json.delta.text = `${json.delta.text ?? ""}${rest}`
      } else if (typeof json?.delta === "string") {
        json.delta += rest
      }
      changed = true
    }
  }
  return changed
}

export function rewriteJsonResponse(text) {
  let json
  try {
    json = JSON.parse(text)
  } catch {
    return text
  }
  let changed = false
  const rewriteText = (target, key) => {
    if (writeText(target, key, createDisplayFilter(), true)) changed = true
  }
  const rewriteParts = (parts) => {
    if (!Array.isArray(parts)) return
    for (const part of parts) {
      if (part?.type === "text" || part?.type === "output_text") rewriteText(part, "text")
    }
  }
  for (const choice of Array.isArray(json?.choices) ? json.choices : []) {
    rewriteText(choice?.message, "content")
    rewriteParts(choice?.message?.content)
    rewriteText(choice?.delta, "content")
  }
  rewriteParts(json?.content)
  for (const item of Array.isArray(json?.output) ? json.output : []) {
    if (item?.type === "message") rewriteParts(item.content)
  }
  if (!changed) return text
  return JSON.stringify(json)
}

function rewriteDataLine(line, filter) {
  const matched = /^(data:\s*)([\s\S]*)$/.exec(line)
  if (!matched) return line
  const raw = matched[2].trim()
  if (raw === "[DONE]") {
    const rest = filter.flush()
    if (!rest) return line
    const extra = JSON.stringify({ choices: [{ index: 0, delta: { content: rest } }] })
    return `data: ${extra}\n${line}`
  }
  let json
  try {
    json = JSON.parse(raw)
  } catch {
    return line
  }
  const flush = finishReason(json)
  if (!rewriteMessage(json, filter, flush)) return line
  return `${matched[1]}${JSON.stringify(json)}`
}

export function createSseRewriter() {
  const filter = createDisplayFilter()
  let carry = ""
  function consume(text, flush) {
    carry += text
    const lines = carry.split("\n")
    if (!flush) carry = lines.pop() ?? ""
    else carry = ""
    if (!lines.length) return ""
    return lines.map((line) => rewriteDataLine(line.replace(/\r$/, ""), filter)).join("\n") + "\n"
  }
  return {
    push(text) {
      return consume(text, false)
    },
    flush() {
      return consume("", true)
    },
  }
}
