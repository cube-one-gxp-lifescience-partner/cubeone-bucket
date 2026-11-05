import assert from "node:assert/strict"
import test from "node:test"
import { SALE_MODEL, SALE_PROVIDER, applyDiscountedModels, discountedModelIds, fetchDiscountedModelIds } from "../sale.js"

function endpoint(overrides) {
  return {
    model_id: "inclusionai/ling-3.1-flash",
    safety_retention: false,
    supported_parameters: ["tools", "temperature"],
    pricing: { discount: 0.75 },
    ...overrides,
  }
}

test("a discounted strict ZDR tool endpoint is included", () => {
  assert.deepEqual(discountedModelIds([endpoint({})]), ["inclusionai/ling-3.1-flash"])
})

test("full price, safety retention, missing tools and the router itself are excluded", () => {
  const ids = discountedModelIds([
    endpoint({ pricing: { discount: 0 } }),
    endpoint({ model_id: "inception/mercury-2.5", safety_retention: true, pricing: { discount: 0.8 } }),
    endpoint({ model_id: "google/gemma-4-31b-it", supported_parameters: ["temperature"], pricing: { discount: 0.5 } }),
    endpoint({ model_id: "openrouter/auto", pricing: { discount: 1 } }),
    endpoint({ model_id: "z-ai/glm-5.3", pricing: { discount: 0.2 } }),
  ])
  assert.deepEqual(ids, ["z-ai/glm-5.3"])
})

test("the sale allow-list is replaced on the default body and every price tier", () => {
  const config = {
    providers: {
      "openrouter-zdr": {
        models: {
          "openrouter/auto": {
            body: { plugins: [{ id: "auto-router", allowed_models: ["keep"], cost_tier: "medium" }] },
          },
        },
      },
      [SALE_PROVIDER]: {
        models: {
          [SALE_MODEL]: {
            body: {
              plugins: [{ id: "auto-router", allowed_models: ["old"], cost_tier: "medium" }],
              provider: { zdr: true, data_collection: "deny", allow_fallbacks: false, sort: "price" },
            },
            variants: [
              { id: "balanced", body: { plugins: [{ id: "auto-router", allowed_models: ["old"], cost_tier: "medium" }] } },
              { id: "cost", body: { plugins: [{ id: "auto-router", allowed_models: ["old"], cost_tier: "low" }] } },
              { id: "intelligence", body: { plugins: [{ id: "auto-router", allowed_models: ["old"], cost_tier: "max" }] } },
            ],
          },
        },
      },
    },
  }
  assert.equal(applyDiscountedModels(config, ["inception/mercury-2.5", "inclusionai/ling-3.1-flash"]), true)
  const sale = config.providers[SALE_PROVIDER].models[SALE_MODEL]
  assert.deepEqual(sale.body.plugins[0].allowed_models, ["inception/mercury-2.5", "inclusionai/ling-3.1-flash"])
  assert.equal(sale.body.plugins[0].cost_tier, "medium")
  assert.equal(sale.body.provider.only, undefined)
  assert.deepEqual(
    sale.variants.map((variant) => variant.body.plugins[0].cost_tier),
    ["medium", "low", "max"],
  )
  assert.deepEqual(sale.variants[1].body.plugins[0].allowed_models, ["inception/mercury-2.5", "inclusionai/ling-3.1-flash"])
  assert.deepEqual(
    config.providers["openrouter-zdr"].models["openrouter/auto"].body.plugins[0].allowed_models,
    ["keep"],
  )
})

test("an empty refresh keeps the baked allow-list", () => {
  const config = {
    provider: {
      [SALE_PROVIDER]: {
        models: {
          [SALE_MODEL]: {
            body: { plugins: [{ id: "auto-router", allowed_models: ["baked"], cost_tier: "low" }] },
          },
        },
      },
    },
  }
  assert.equal(applyDiscountedModels(config, []), false)
  assert.deepEqual(config.provider[SALE_PROVIDER].models[SALE_MODEL].body.plugins[0].allowed_models, ["baked"])
})

test("the endpoint fetch reads the data list", async () => {
  const ids = await fetchDiscountedModelIds(async () => ({
    ok: true,
    json: async () => ({ data: [endpoint({ model_id: "upstage/solar-pro4" })] }),
  }))
  assert.deepEqual(ids, ["upstage/solar-pro4"])
})
