import { SALE_PROVIDER, applyDiscountedModels, fetchDiscountedModelIds } from "./sale.js"

const TTL_MS = 10 * 60 * 1000
let cache = { at: 0, ids: [] }

async function currentIds() {
  if (cache.ids.length > 0 && Date.now() - cache.at < TTL_MS) return cache.ids
  try {
    const ids = await fetchDiscountedModelIds(globalThis.fetch, AbortSignal.timeout(8000))
    if (ids.length > 0) {
      cache = { at: Date.now(), ids }
      return ids
    }
  } catch {
    // The model keeps the allow-list written at generation time.
  }
  return cache.ids
}

function rewriteLive(target, ids) {
  if (!target || !Array.isArray(target.plugins)) return
  for (const plugin of target.plugins) {
    if (plugin && plugin.id === "auto-router") plugin.allowed_models = ids.slice()
  }
}

function refreshModel(model, ids) {
  if (!ids.length || !model) return
  rewriteLive(model.options, ids)
  rewriteLive(model.body, ids)
  const variants = Array.isArray(model.variants)
    ? model.variants
    : model.variants && typeof model.variants === "object"
      ? Object.values(model.variants)
      : []
  for (const variant of variants) {
    rewriteLive(variant?.options, ids)
    rewriteLive(variant?.body, ids)
  }
}

export default async function cubeoneSale() {
  return {
    config: async (config) => {
      applyDiscountedModels(config, await currentIds())
    },
    "chat.params": async (input) => {
      const model = input.model
      if (!model || model.providerID !== SALE_PROVIDER) return
      refreshModel(model, await currentIds())
    },
  }
}
