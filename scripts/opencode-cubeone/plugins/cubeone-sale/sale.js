// OpenRouter publishes the current sale as pricing.discount on each endpoint.
// 0 means no discount. The public ZDR list is the same source the generator uses,
// so a model is on sale for this router only when a strict ZDR tool endpoint is discounted.
// OpenCode sends the model key to OpenRouter, so SALE has its own provider with the same key as the EU entry.
export const SALE_PROVIDER = "openrouter-zdr-sale"
export const SALE_MODEL = "openrouter/auto"
export const ZDR_ENDPOINTS = "https://openrouter.ai/api/v1/endpoints/zdr"

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
  return [...ids].sort()
}

function rewriteBody(body, ids) {
  if (!body || !Array.isArray(body.plugins)) return false
  let rewritten = false
  for (const plugin of body.plugins) {
    if (!plugin || plugin.id !== "auto-router") continue
    plugin.allowed_models = ids.slice()
    rewritten = true
  }
  return rewritten
}

function variantBodies(variants) {
  if (Array.isArray(variants)) return variants
  if (variants && typeof variants === "object") return Object.values(variants)
  return []
}

/** Replaces the allow-list on Auto (ZDR, SALE) only. An empty list leaves the baked fallback in place. */
export function applyDiscountedModels(config, ids) {
  if (!Array.isArray(ids) || ids.length === 0) return false
  const maps = [config?.providers, config?.provider].filter((map) => map && typeof map === "object")
  let applied = false
  for (const map of maps) {
    const model = map[SALE_PROVIDER]?.models?.[SALE_MODEL]
    if (!model) continue
    if (rewriteBody(model.body, ids)) applied = true
    if (rewriteBody(model.options, ids)) applied = true
    for (const variant of variantBodies(model.variants)) {
      if (rewriteBody(variant?.body, ids)) applied = true
      if (rewriteBody(variant?.options, ids)) applied = true
    }
  }
  return applied
}

export async function fetchDiscountedModelIds(fetchImpl = globalThis.fetch, signal) {
  const response = await fetchImpl(ZDR_ENDPOINTS, {
    headers: { "user-agent": "cubeone-opencode/sale", accept: "application/json" },
    signal,
  })
  if (!response.ok) throw new Error(`OpenRouter ZDR list returned ${response.status}`)
  const payload = await response.json()
  return discountedModelIds(payload?.data)
}
