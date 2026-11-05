import {
  BLOCKED_MESSAGE,
  NO_SALE_MESSAGE,
  SALE_MODEL,
  SALE_PROVIDER,
  fetchDiscountedModelIds,
  rewriteSaleRequest,
} from "./sale.js"

const REFRESH_MS = 10 * 60 * 1000
const FETCH_TIMEOUT_MS = 8000

export default {
  id: "cubeone-sale",
  async setup(ctx) {
    // null until the first successful refresh: the configured list, cut down to the static list, is used.
    // After that it always holds the last successful answer, an empty one included. A failed refresh keeps it.
    let ids = null

    await ctx.session.hook(
      "http.request",
      async (event) => {
        if (event.model?.id !== SALE_MODEL) return
        try {
          event.request = await rewriteSaleRequest(event.request, ids)
        } catch (error) {
          // Fail closed: a request that cannot be checked, or has no discounted model to go to, is not sent.
          // Only one of two fixed texts is logged or thrown, nothing from the request or the error.
          const text = error?.message === NO_SALE_MESSAGE ? NO_SALE_MESSAGE : BLOCKED_MESSAGE
          console.warn(text)
          throw new Error(text)
        }
      },
      { providerID: SALE_PROVIDER },
    )

    const refresh = async () => {
      try {
        ids = await fetchDiscountedModelIds(globalThis.fetch, AbortSignal.timeout(FETCH_TIMEOUT_MS))
      } catch {
        console.warn("cubeone-sale: discount list unavailable, keeping the last known state")
      }
    }

    void refresh()
    const timer = setInterval(() => void refresh(), REFRESH_MS)
    timer.unref?.()
    return () => clearInterval(timer)
  },
}
