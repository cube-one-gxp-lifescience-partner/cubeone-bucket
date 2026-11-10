import { AUTO_MODEL, AUTO_PROVIDER, pinRequest, readRoutedModel } from "./pin.js"

const KEY = "pin/"
const PINNED_KINDS = new Set(["primary", "compaction"])

export default {
  id: "cubeone-auto-pin",
  async setup(ctx) {
    // The first model the auto router picks for a session is remembered and used for every later request.
    // Switching between providers inside one session breaks encrypted reasoning history ("multiple providers").
    const pins = new Map()

    const pinFor = async (sessionID) => {
      if (pins.has(sessionID)) return pins.get(sessionID)
      let slug
      try {
        const stored = await ctx.storage.get(KEY + sessionID)
        if (typeof stored === "string") slug = stored
      } catch {
        slug = undefined
      }
      pins.set(sessionID, slug)
      return slug
    }

    await ctx.session.hook(
      "http.request",
      async (event) => {
        if (event.model?.id !== AUTO_MODEL || !PINNED_KINDS.has(event.kind)) return
        const slug = await pinFor(event.sessionID)
        if (!slug) return
        try {
          event.request = await pinRequest(event.request, slug)
        } catch {
          console.warn("cubeone-auto-pin: request left to the auto router")
        }
      },
      { providerID: AUTO_PROVIDER },
    )

    await ctx.session.hook(
      "http.response",
      async (event) => {
        if (event.model?.id !== AUTO_MODEL || event.kind !== "primary") return
        if (await pinFor(event.sessionID)) return
        // Never delays the chat: the body is probed on a clone in the background.
        void readRoutedModel(event.response)
          .then(async (slug) => {
            if (!slug || (await pinFor(event.sessionID))) return
            pins.set(event.sessionID, slug)
            await ctx.storage.set(KEY + event.sessionID, slug)
          })
          .catch(() => {})
      },
      { providerID: AUTO_PROVIDER },
    )
  },
}
