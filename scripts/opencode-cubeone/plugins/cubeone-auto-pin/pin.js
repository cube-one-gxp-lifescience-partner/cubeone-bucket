export const AUTO_MODEL = "openrouter/auto"
export const AUTO_PROVIDER = "openrouter-zdr"

const MAX_PROBE_BYTES = 64 * 1024
const SLUG = /^[a-z0-9][a-z0-9._~-]*\/[A-Za-z0-9][A-Za-z0-9._:-]*$/

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

/**
 * Returns the model slug the router reports in a chat response chunk or JSON body, or undefined.
 * The first `"model"` field is the routed model; the router's own id is not a routing result.
 */
export function routedModel(text) {
  if (typeof text !== "string") return undefined
  const match = /"model"\s*:\s*"([^"\\]{1,200})"/.exec(text)
  const slug = match?.[1]
  if (!slug || slug === AUTO_MODEL || !SLUG.test(slug)) return undefined
  return slug
}

/**
 * Reads the routed model from a response without consuming the body the session reads.
 * Only a clone is read, and only until a model shows up or MAX_PROBE_BYTES are seen.
 */
export async function readRoutedModel(response) {
  if (!response?.body || response.bodyUsed) return undefined
  const reader = response.clone().body.getReader()
  const decoder = new TextDecoder()
  let seen = ""
  let bytes = 0
  try {
    while (bytes < MAX_PROBE_BYTES) {
      const { done, value } = await reader.read()
      if (done) break
      bytes += value.byteLength
      seen += decoder.decode(value, { stream: true })
      const slug = routedModel(seen)
      if (slug) return slug
    }
    return routedModel(seen)
  } finally {
    // A tee'd branch only finishes cancelling once the other branch is done too, so this is not awaited.
    void reader.cancel().catch(() => {})
  }
}

function allows(allowed, slug) {
  return allowed.some((entry) => typeof entry === "string" && (entry === slug || slug.startsWith(`${entry}-`)))
}

/**
 * Replaces the auto router by `slug` in one chat request body (a parsed object, edited in place).
 * The slug must be one the router was allowed to choose in this very request, so the allow-list of the
 * managed config, SALE narrowing included, still decides. The provider block (ZDR, EU endpoints) stays.
 * Returns true when the body was changed.
 */
export function pinRequestBody(body, slug) {
  if (!isRecord(body) || body.model !== AUTO_MODEL || !Array.isArray(body.plugins)) return false
  const routers = body.plugins.filter((plugin) => isRecord(plugin) && plugin.id === "auto-router")
  if (routers.length === 0) return false
  const allowed = routers.flatMap((router) => (Array.isArray(router.allowed_models) ? router.allowed_models : []))
  if (!allows(allowed, slug)) return false
  body.model = slug
  body.plugins = body.plugins.filter((plugin) => !(isRecord(plugin) && plugin.id === "auto-router"))
  if (body.plugins.length === 0) delete body.plugins
  return true
}

/**
 * Returns a copy of `request` pinned to `slug`, or `request` itself when it is no auto-router chat request.
 * A body that cannot be read is sent unchanged: the pin only narrows routing, it never blocks a request.
 */
export async function pinRequest(request, slug) {
  if (!request || request.method !== "POST" || !request.body) return request
  let body
  try {
    body = JSON.parse(await request.clone().text())
  } catch {
    return request
  }
  if (!pinRequestBody(body, slug)) return request
  const headers = new Headers(request.headers)
  headers.delete("content-length")
  return new Request(request, { body: JSON.stringify(body), headers })
}
