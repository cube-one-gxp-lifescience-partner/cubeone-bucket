import { createSseRewriter, rewriteJsonResponse } from "./display.js"

function textResponse(response) {
  const type = response.headers?.get?.("content-type") ?? ""
  return /json|event-stream|text\/plain/i.test(type) || type === ""
}

async function filterHttp(response) {
  if (!response?.body || !textResponse(response)) return response
  const type = response.headers?.get?.("content-type") ?? ""
  if (/\bapplication\/(?:[\w.+-]*\+)?json\b/i.test(type)) {
    const original = await response.clone().text()
    const rewritten = rewriteJsonResponse(original)
    if (rewritten === original) return response
    const headers = new Headers(response.headers)
    headers.delete("content-length")
    headers.delete("content-encoding")
    return new Response(rewritten, { status: response.status, statusText: response.statusText, headers })
  }
  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  const encoder = new TextEncoder()
  const rewriter = createSseRewriter()
  const stream = new ReadableStream({
    async pull(controller) {
      try {
        // Keep reading while an incomplete SSE line produces no output, otherwise a pending consumer stalls.
        while (true) {
          const { done, value } = await reader.read()
          if (done) {
            const tail = rewriter.push(decoder.decode()) + rewriter.flush()
            if (tail) controller.enqueue(encoder.encode(tail))
            controller.close()
            return
          }
          const next = rewriter.push(decoder.decode(value, { stream: true }))
          if (next) {
            controller.enqueue(encoder.encode(next))
            return
          }
        }
      } catch (error) {
        controller.error(error)
      }
    },
    cancel(reason) {
      return reader.cancel(reason)
    },
  })
  const headers = new Headers(response.headers)
  headers.delete("content-length")
  headers.delete("content-encoding")
  return new Response(stream, { status: response.status, statusText: response.statusText, headers })
}

const frames = new Map()

function filterFrame(sessionID, frame) {
  if (typeof frame !== "string" || frame.length === 0) return frame
  if (!frame.includes("data:") && !frame.trimStart().startsWith("{") && !/Compressed block context:|@dcp-id-|@b\d+@|<dcp-/i.test(frame)) {
    return frame
  }
  let rewriter = frames.get(sessionID)
  if (!rewriter) {
    rewriter = createSseRewriter()
    frames.set(sessionID, rewriter)
  }
  const body = frame.includes("data:") || frame.includes("\n") ? frame : `data: ${frame}`
  const rewritten = rewriter.push(body.endsWith("\n") ? body : `${body}\n`)
  if (frame.includes("data:") || frame.includes("\n")) return rewritten.endsWith("\n") ? rewritten.slice(0, -1) : rewritten
  const line = rewritten.replace(/^data:\s*/, "").replace(/\n$/, "")
  return line
}

export default {
  id: "cubeone-dcp-view",
  async setup(ctx) {
    await ctx.session.hook("http.response", async (event) => {
      event.response = await filterHttp(event.response)
    })
    await ctx.session.hook("experimental.ws.receive", (event) => {
      event.frame = filterFrame(event.sessionID, event.frame)
    })
    void (async () => {
      for await (const event of ctx.event.subscribe({ types: ["session.execution.started"] })) {
        if (event.data?.sessionID) frames.delete(event.data.sessionID)
      }
    })().catch(() => {})
  },
}
