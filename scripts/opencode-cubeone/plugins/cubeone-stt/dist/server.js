const AUTO_MODEL = "openrouter/auto"

export function routedModel(text) {
  const pattern = /"model"\s*:\s*"([^"\\]{1,160})"/g
  let match
  while ((match = pattern.exec(text))) {
    const value = match[1]
    if (!value || value === AUTO_MODEL || value.startsWith("openrouter/")) continue
    if (!/^[A-Za-z0-9._:/-]+$/.test(value) || !value.includes("/")) continue
    return value
  }
  return undefined
}

function metadataOf(info) {
  const metadata = info?.metadata
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) return {}
  return metadata
}

async function remember(session, sessionID, model) {
  const info = await session.get({ sessionID })
  const previous = metadataOf(info)
  if (previous.routedModel === model) return
  await session.update({ sessionID, metadata: { ...previous, routedModel: model } })
}

async function watch(session, sessionID, body) {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  let buffered = ""
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      buffered += decoder.decode(value, { stream: true })
      if (buffered.length > 65536) buffered = buffered.slice(-8192)
      const model = routedModel(buffered)
      if (!model) continue
      try {
        await reader.cancel()
      } catch {
        // The other half of the stream stays with the app.
      }
      await remember(session, sessionID, model)
      return
    }
    const model = routedModel(buffered)
    if (model) await remember(session, sessionID, model)
  } catch {
    // The app still owns the other half of the stream. A failed read only skips the label.
  }
}

export default {
  id: "cubeone-stt",
  async setup(ctx) {
    await ctx.session.hook(
      "http.response",
      (input) => {
        if (input.kind !== "primary" || input.model?.id !== AUTO_MODEL) return
        const body = input.response?.body
        if (!body || !input.response.ok) return
        let appBody
        let watchBody
        try {
          ;[appBody, watchBody] = body.tee()
        } catch {
          return
        }
        input.response = new Response(appBody, {
          status: input.response.status,
          statusText: input.response.statusText,
          headers: new Headers(input.response.headers),
        })
        void watch(ctx.session, input.sessionID, watchBody)
      },
      { providerID: "openrouter-zdr" },
    )
  },
}
