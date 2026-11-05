// OpenRouter publishes the current sale as pricing.discount on each endpoint.
// 0 means no discount. The public ZDR list is the same source the generator uses,
// so a model is on sale for this router only when a strict ZDR tool endpoint is discounted.
// OpenCode sends the model key to OpenRouter, so SALE has its own provider with the same key as the EU entry.
export const SALE_PROVIDER = "openrouter-zdr-sale"
export const SALE_MODEL = "openrouter/auto"
export const ZDR_ENDPOINTS = "https://openrouter.ai/api/v1/endpoints/zdr"

// The only models Auto (ZDR, SALE) may ever route to: image models. The discount list narrows this set, it never
// extends it, so a newly discounted text-only model cannot slip in. Mirrored in Update-OpenCodeModels.ps1
// ($AutoSaleModels); test/sale.test.js fails when the two drift apart.
export const SALE_ALLOWED = Object.freeze([
  "deepseek/deepseek-v4-flash-vision-exp",
  "deepseek/deepseek-v4.1-flash",
  "deepseek/deepseek-v4.1-flash-1017",
  "google/gemma-4-31b-it",
  "minimax/minimax-m3.1-flash",
  "moonshotai/kimi-k2.5",
  "moonshotai/kimi-k2.7-code",
  "moonshotai/kimi-k3",
  "moonshotai/kimi-k3.1-pro",
  "qwen/qwen3.8-27b",
  "tencent/hy4",
  "xiaomi/mimo-v2.6-pro",
  "z-ai/glm-5.3-flash",
])

/** Keeps only ids from the static list, sorted and without duplicates. Anything else is dropped. */
export function allowedOnly(ids) {
  const allowed = new Set(SALE_ALLOWED)
  const kept = new Set()
  for (const id of Array.isArray(ids) ? ids : []) {
    if (typeof id === "string" && allowed.has(id)) kept.add(id)
  }
  return [...kept].sort()
}

export function discountedModelIds(endpoints) {
  const ids = new Set()
  for (const endpoint of endpoints ?? []) {
    if (!endpoint || endpoint.safety_retention === true) continue
    const parameters = endpoint.supported_parameters
    if (!Array.isArray(parameters) || !parameters.includes("tools")) continue
    const discount = Number(endpoint.pricing?.discount)
    if (!(discount > 0)) continue
    const id = endpoint.model_id
    if (typeof id !== "string" || id.length === 0 || id.startsWith("openrouter/")) continue
    ids.add(id)
  }
  return allowedOnly([...ids])
}

// Fixed texts for every refusal, so nothing from a request or an error can end up in a log.
export const BLOCKED_MESSAGE = "cubeone-sale: request blocked"
export const NO_SALE_MESSAGE = "cubeone-sale: no discounted model available, request blocked"

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

/**
 * The allow-list one auto-router entry may use, always a non-empty subset of SALE_ALLOWED.
 * `ids` is the outcome of the last successful discount refresh, or null when there has been none yet:
 * - null (start, or offline since start): the configured list, cut down to the static list. A missing, empty or
 *   entirely foreign configured list is replaced by the whole static list.
 * - an array, also an empty one: the configured list (same fallback) intersected with the discounted models.
 *   Nothing in common, or an empty discount list, means nothing is on sale: the request is refused with
 *   NO_SALE_MESSAGE instead of using models that are no longer discounted.
 */
function permittedModels(configuredList, ids) {
  const configured = allowedOnly(configuredList)
  const base = configured.length > 0 ? configured : [...SALE_ALLOWED].sort()
  if (!Array.isArray(ids)) return base
  const onSale = new Set(allowedOnly(ids))
  const next = base.filter((id) => onSale.has(id))
  if (next.length === 0) throw new Error(NO_SALE_MESSAGE)
  return next
}

function sameList(left, right) {
  return Array.isArray(left) && left.length === right.length && left.every((id, index) => id === right[index])
}

/**
 * Rewrites the auto-router allow-list in one chat request body (a parsed object, edited in place).
 * Only the auto-router is touched: its plugin entries, or a body for the SALE model that has none.
 * Every other body is left alone. See permittedModels for what a list may become and when this throws.
 * Returns true when the body was changed.
 */
export function rewriteRequestBody(body, ids) {
  if (!isRecord(body)) return false
  const plugins = Array.isArray(body.plugins) ? body.plugins : []
  const routers = plugins.filter((plugin) => isRecord(plugin) && plugin.id === "auto-router")
  if (routers.length === 0) {
    // The SALE model without a router entry would route anywhere, so the entry is added.
    if (body.model !== SALE_MODEL) return false
    body.plugins = [...plugins, { id: "auto-router", allowed_models: permittedModels(undefined, ids) }]
    return true
  }
  let changed = false
  for (const router of routers) {
    const next = permittedModels(router.allowed_models, ids)
    if (sameList(router.allowed_models, next)) continue
    router.allowed_models = next
    changed = true
  }
  return changed
}
/**
 * Returns a copy of `request` with the allow-list rewritten, or `request` itself when nothing changes.
 * OpenCode V2 has no transform that can override the body written in the managed config (the config layer is
 * applied last), so the allow-list is corrected on the outgoing chat request instead.
 * `ids` is the last successful discount list or null before the first one (see permittedModels).
 * A request without a body (GET and the like) passes. A POST whose body is not a JSON object cannot be checked,
 * so it is refused with BLOCKED_MESSAGE instead of being sent to an unrestricted router.
 */
export async function rewriteSaleRequest(request, ids) {
  if (!request || request.method !== "POST" || !request.body) return request
  let body
  try {
    body = JSON.parse(await request.clone().text())
  } catch {
    throw new Error(BLOCKED_MESSAGE)
  }
  if (!isRecord(body)) throw new Error(BLOCKED_MESSAGE)
  if (!rewriteRequestBody(body, ids)) return request
  const headers = new Headers(request.headers)
  headers.delete("content-length")
  return new Request(request, { body: JSON.stringify(body), headers })
}
export async function fetchDiscountedModelIds(fetchImpl = globalThis.fetch, signal) {
  const response = await fetchImpl(ZDR_ENDPOINTS, {
    headers: { "user-agent": "cubeone-opencode/sale", accept: "application/json" },
    signal,
  })
  if (!response.ok) throw new Error(`OpenRouter ZDR list returned ${response.status}`)
  const payload = await response.json()
  // Anything but a list is a failed refresh, not an empty one: an empty list blocks SALE requests.
  if (!Array.isArray(payload?.data)) throw new Error("OpenRouter ZDR list has no data")
  return discountedModelIds(payload.data)
}
