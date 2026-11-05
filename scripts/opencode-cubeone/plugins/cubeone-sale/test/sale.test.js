import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test, { mock } from "node:test"
import { fileURLToPath } from "node:url"
import plugin from "../server.js"
import {
  BLOCKED_MESSAGE,
  NO_SALE_MESSAGE,
  SALE_ALLOWED,
  SALE_MODEL,
  SALE_PROVIDER,
  allowedOnly,
  discountedModelIds,
  fetchDiscountedModelIds,
  rewriteRequestBody,
  rewriteSaleRequest,
} from "../sale.js"

const REFRESH_MS = 10 * 60 * 1000
const GENERATOR = fileURLToPath(new URL("../../../Update-OpenCodeModels.ps1", import.meta.url))
const MANAGED = fileURLToPath(new URL("../../../managed/opencode.jsonc", import.meta.url))

function endpoint(overrides) {
  return {
    model_id: "tencent/hy4",
    safety_retention: false,
    supported_parameters: ["tools", "temperature"],
    pricing: { discount: 0.75 },
    ...overrides,
  }
}

function body(allowed, tier = "medium") {
  return {
    model: "openrouter/auto",
    plugins: [{ id: "auto-router", allowed_models: allowed, cost_tier: tier }],
    provider: { zdr: true, data_collection: "deny", allow_fallbacks: false, sort: "price" },
  }
}

function powershellList(source, name) {
  const match = new RegExp(`\\$${name} = @\\(([^)]*)\\)`).exec(source)
  assert.ok(match, `${name} not found in the generator`)
  return [...match[1].matchAll(/'([^']+)'/g)].map((entry) => entry[1])
}

function managedAuto(provider) {
  const text = readFileSync(MANAGED, "utf8")
    .split(/\r?\n/)
    .filter((line) => !line.trimStart().startsWith("//"))
    .join("\n")
  return JSON.parse(text).providers[provider].models["openrouter/auto"]
}

test("a discounted strict ZDR tool endpoint on the static list is included", () => {
  assert.deepEqual(discountedModelIds([endpoint({})]), ["tencent/hy4"])
})

test("full price, safety retention, missing tools, the router and models off the static list are excluded", () => {
  const ids = discountedModelIds([
    endpoint({ pricing: { discount: 0 } }),
    endpoint({ model_id: "moonshotai/kimi-k3", safety_retention: true, pricing: { discount: 0.8 } }),
    endpoint({ model_id: "google/gemma-4-31b-it", supported_parameters: ["temperature"], pricing: { discount: 0.5 } }),
    endpoint({ model_id: "openrouter/auto", pricing: { discount: 1 } }),
    endpoint({ model_id: "z-ai/glm-5.3", pricing: { discount: 0.2 } }),
    endpoint({ model_id: "inception/mercury-2.5", pricing: { discount: 0.9 } }),
    endpoint({ model_id: "qwen/qwen3.8-27b", pricing: { discount: 0.2 } }),
  ])
  assert.deepEqual(ids, ["qwen/qwen3.8-27b"])
})

test("the static list has the 13 image models and allowedOnly never adds to it", () => {
  assert.equal(SALE_ALLOWED.length, 13)
  assert.equal(new Set(SALE_ALLOWED).size, 13)
  assert.deepEqual(allowedOnly(["tencent/hy4", "evil/text-only", "tencent/hy4", 7, null]), ["tencent/hy4"])
  assert.deepEqual(allowedOnly(undefined), [])
  assert.deepEqual(allowedOnly([...SALE_ALLOWED, "z-ai/glm-5.3"]), [...SALE_ALLOWED].sort())
})

test("the static list matches the generator and the managed SALE entry", () => {
  const generator = readFileSync(GENERATOR, "utf8")
  assert.deepEqual([...powershellList(generator, "AutoSaleModels")].sort(), [...SALE_ALLOWED].sort())
  const sale = managedAuto(SALE_PROVIDER)
  const bodies = [sale.body, ...sale.variants.map((variant) => variant.body)]
  assert.equal(bodies.length, 4)
  for (const entry of bodies) {
    assert.ok(entry.plugins[0].allowed_models.length > 0)
    for (const id of entry.plugins[0].allowed_models) assert.ok(SALE_ALLOWED.includes(id), `${id} is not allowed`)
  }
  assert.deepEqual(sale.variants.map((variant) => variant.id), ["balanced", "cost", "intelligence"])
  assert.deepEqual(sale.variants.map((variant) => variant.body.plugins[0].cost_tier), ["medium", "low", "max"])
  assert.ok(sale.capabilities.input.includes("image"))
})

test("SALE does not offer PDFs, neither in the managed config nor from the generator", () => {
  const sale = managedAuto(SALE_PROVIDER)
  assert.deepEqual(sale.capabilities.input, ["text", "image"])
  assert.deepEqual(sale.modalities.input, ["text", "image"])
  // Mistral OCR, which OpenRouter uses for PDFs on models without file input, has no guaranteed ZDR.
  const generator = readFileSync(GENERATOR, "utf8")
  const start = generator.indexOf("$saleInput = ")
  const end = generator.indexOf("$saleModalities = ")
  assert.ok(start > 0 && end > start, "SALE input block not found in the generator")
  assert.ok(!/pdf|file/.test(generator.slice(start, end).replace(/#.*$/gm, "")), "the generator must not add pdf for SALE")
  assert.ok(!/saleInput\.Add\('pdf'\)/.test(generator))
})

test("the managed EU entry is limited to the image and PDF list", () => {
  const generator = readFileSync(GENERATOR, "utf8")
  const expected = powershellList(generator, "AutoEuModels")
  assert.equal(expected.length, 7)
  const eu = managedAuto("openrouter-zdr")
  const bodies = [eu.body, ...eu.variants.map((variant) => variant.body)]
  assert.equal(bodies.length, 4)
  for (const entry of bodies) assert.deepEqual(entry.plugins[0].allowed_models, [...expected].sort())
  assert.deepEqual(eu.variants.map((variant) => variant.body.plugins[0].cost_tier), ["medium", "low", "max"])
  assert.ok(eu.capabilities.input.includes("image"))
  assert.ok(eu.capabilities.input.includes("pdf"))
})

const SORTED_STATIC = [...SALE_ALLOWED].sort()

function blocked(message) {
  return (error) => error.message === message
}

test("a refreshed list narrows the configured list and keeps the price tier", () => {
  const request = body(["tencent/hy4", "qwen/qwen3.8-27b", "moonshotai/kimi-k3"], "low")
  assert.equal(rewriteRequestBody(request, ["qwen/qwen3.8-27b", "tencent/hy4", "z-ai/glm-5.3-flash"]), true)
  assert.deepEqual(request.plugins[0].allowed_models, ["qwen/qwen3.8-27b", "tencent/hy4"])
  assert.equal(request.plugins[0].cost_tier, "low")
  assert.equal(request.provider.sort, "price")
  assert.equal(request.provider.only, undefined)
})

test("the refresh never widens a narrower configured list", () => {
  const request = body(["tencent/hy4"])
  rewriteRequestBody(request, [...SALE_ALLOWED])
  assert.deepEqual(request.plugins[0].allowed_models, ["tencent/hy4"])
  const unchanged = body(["tencent/hy4"])
  assert.equal(rewriteRequestBody(unchanged, [...SALE_ALLOWED]), false)
})

test("the refresh cannot bring in anything off the static list", () => {
  const request = body([...SALE_ALLOWED])
  rewriteRequestBody(request, ["evil/text-only", "z-ai/glm-5.3", "moonshotai/kimi-k3"])
  assert.deepEqual(request.plugins[0].allowed_models, ["moonshotai/kimi-k3"])
})

test("before the first successful refresh the configured list is used, minus anything off the static list", () => {
  for (const unknown of [null, undefined, "not a list", 7, {}]) {
    const request = body(["evil/text-only", "tencent/hy4", "qwen/qwen3.8-27b"])
    assert.equal(rewriteRequestBody(request, unknown), true)
    assert.deepEqual(request.plugins[0].allowed_models, ["qwen/qwen3.8-27b", "tencent/hy4"])
    const clean = body(["qwen/qwen3.8-27b", "tencent/hy4"])
    assert.equal(rewriteRequestBody(clean, unknown), false)
    assert.deepEqual(clean.plugins[0].allowed_models, ["qwen/qwen3.8-27b", "tencent/hy4"])
  }
})

test("with a successful refresh and no overlap the request is refused, the stale configured list is not used", () => {
  const request = body(["tencent/hy4"])
  assert.throws(() => rewriteRequestBody(request, ["qwen/qwen3.8-27b", "moonshotai/kimi-k3"]), blocked(NO_SALE_MESSAGE))
  const offList = body(["tencent/hy4"])
  assert.throws(() => rewriteRequestBody(offList, ["evil/text-only", "z-ai/glm-5.3"]), blocked(NO_SALE_MESSAGE))
})

test("a successful but empty refresh refuses the request", () => {
  assert.throws(() => rewriteRequestBody(body([...SALE_ALLOWED]), []), blocked(NO_SALE_MESSAGE))
  assert.throws(() => rewriteRequestBody(body(["tencent/hy4"]), []), blocked(NO_SALE_MESSAGE))
  assert.throws(() => rewriteRequestBody(body(undefined), []), blocked(NO_SALE_MESSAGE))
  assert.throws(() => rewriteRequestBody({ model: SALE_MODEL }, []), blocked(NO_SALE_MESSAGE))
})

test("a configured list with nothing from the static list is replaced, never kept", () => {
  const foreign = body(["evil/text-only", "z-ai/glm-5.3"])
  assert.equal(rewriteRequestBody(foreign, null), true)
  assert.deepEqual(foreign.plugins[0].allowed_models, SORTED_STATIC)
  const withRefresh = body(["evil/text-only"])
  rewriteRequestBody(withRefresh, ["tencent/hy4", "evil/text-only"])
  assert.deepEqual(withRefresh.plugins[0].allowed_models, ["tencent/hy4"])
  assert.throws(() => rewriteRequestBody(body(["evil/text-only"]), []), blocked(NO_SALE_MESSAGE))
})

test("a missing, empty or malformed allowed_models field never leaves the router unrestricted", () => {
  for (const bad of [undefined, null, [], "tencent/hy4", {}, 7, [null, 7, {}]]) {
    const request = body(bad)
    assert.equal(rewriteRequestBody(request, null), true, JSON.stringify(bad))
    assert.deepEqual(request.plugins[0].allowed_models, SORTED_STATIC, JSON.stringify(bad))
    const refreshed = body(bad)
    rewriteRequestBody(refreshed, ["tencent/hy4"])
    assert.deepEqual(refreshed.plugins[0].allowed_models, ["tencent/hy4"], JSON.stringify(bad))
    assert.throws(() => rewriteRequestBody(body(bad), []), blocked(NO_SALE_MESSAGE), JSON.stringify(bad))
  }
  const missing = { model: SALE_MODEL, plugins: [{ id: "auto-router", cost_tier: "low" }] }
  rewriteRequestBody(missing, null)
  assert.deepEqual(missing.plugins[0].allowed_models, SORTED_STATIC)
  assert.equal(missing.plugins[0].cost_tier, "low")
})

test("every auto-router entry is limited, also when there are several", () => {
  const make = () => ({
    model: SALE_MODEL,
    plugins: [
      { id: "auto-router", allowed_models: ["evil/text-only"] },
      { id: "auto-router", allowed_models: ["tencent/hy4", "evil/text-only"] },
    ],
  })
  const request = make()
  assert.equal(rewriteRequestBody(request, null), true)
  assert.deepEqual(request.plugins[0].allowed_models, SORTED_STATIC)
  assert.deepEqual(request.plugins[1].allowed_models, ["tencent/hy4"])
  // One entry with nothing on sale is enough to refuse the whole request.
  assert.throws(() => rewriteRequestBody(make(), ["qwen/qwen3.8-27b"]), blocked(NO_SALE_MESSAGE))
})

test("a SALE model request without any router entry gets one", () => {
  for (const plugins of [undefined, [], "x", null, [{ id: "file-parser" }]]) {
    const request = { model: SALE_MODEL, messages: [], plugins }
    assert.equal(rewriteRequestBody(request, null), true, JSON.stringify(plugins))
    const router = request.plugins.find((plugin) => plugin.id === "auto-router")
    assert.deepEqual(router.allowed_models, SORTED_STATIC, JSON.stringify(plugins))
    const refreshed = { model: SALE_MODEL, plugins }
    rewriteRequestBody(refreshed, ["tencent/hy4"])
    assert.deepEqual(refreshed.plugins.find((plugin) => plugin.id === "auto-router").allowed_models, ["tencent/hy4"])
    assert.throws(() => rewriteRequestBody({ model: SALE_MODEL, plugins }, []), blocked(NO_SALE_MESSAGE))
  }
  const kept = { model: SALE_MODEL, plugins: [{ id: "file-parser", pdf: { engine: "native" } }] }
  rewriteRequestBody(kept, ["tencent/hy4"])
  assert.deepEqual(kept.plugins[0], { id: "file-parser", pdf: { engine: "native" } })
  assert.deepEqual(kept.plugins[1], { id: "auto-router", allowed_models: ["tencent/hy4"] })
})

test("only the auto-router is touched, unrelated bodies stay exactly as they are", () => {
  const request = {
    model: SALE_MODEL,
    plugins: [{ id: "file-parser", pdf: { engine: "native" } }, { id: "auto-router", allowed_models: ["x/y"] }],
  }
  assert.equal(rewriteRequestBody(request, ["tencent/hy4"]), true)
  assert.deepEqual(request.plugins[0], { id: "file-parser", pdf: { engine: "native" } })
  assert.deepEqual(request.plugins[1].allowed_models, ["tencent/hy4"])
  for (const ids of [null, [], ["tencent/hy4"]]) {
    for (const other of [
      { model: "anthropic/claude-sonnet-5.5", messages: [] },
      { model: "anthropic/claude-sonnet-5.5", plugins: [{ id: "web" }] },
      { messages: [] },
      { model: "other/model", plugins: "x" },
    ]) {
      const copy = structuredClone(other)
      assert.equal(rewriteRequestBody(other, ids), false)
      assert.deepEqual(other, copy)
    }
    for (const notABody of [null, undefined, "text", 7, [], [{ id: "auto-router" }]]) {
      assert.equal(rewriteRequestBody(notABody, ids), false)
    }
  }
})

test("a chat request is rewritten with a consistent body and the original headers", async () => {
  const original = new Request("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { authorization: "Bearer x", "content-type": "application/json", "content-length": "1" },
    body: JSON.stringify(body(["evil/text-only"], "max")),
  })
  const rewritten = await rewriteSaleRequest(original, ["tencent/hy4"])
  assert.notEqual(rewritten, original)
  const sent = await rewritten.json()
  assert.deepEqual(sent.plugins[0].allowed_models, ["tencent/hy4"])
  assert.equal(sent.plugins[0].cost_tier, "max")
  assert.equal(rewritten.headers.get("authorization"), "Bearer x")
  assert.equal(rewritten.headers.get("content-length"), null)
  assert.equal(rewritten.url, original.url)
})

test("a request that is already inside the list passes through untouched", async () => {
  const request = new Request("https://openrouter.ai/x", { method: "POST", body: JSON.stringify(body(["tencent/hy4"])) })
  assert.equal(await rewriteSaleRequest(request, ["tencent/hy4"]), request)
  const get = new Request("https://openrouter.ai/api/v1/models")
  assert.equal(await rewriteSaleRequest(get, ["tencent/hy4"]), get)
})

test("a POST that cannot be checked is refused with a fixed message", async () => {
  for (const content of ["not json", "[1,2]", "7", "null", '"text"']) {
    const request = new Request("https://openrouter.ai/x", { method: "POST", body: content })
    await assert.rejects(rewriteSaleRequest(request, ["tencent/hy4"]), (error) => error.message === BLOCKED_MESSAGE)
  }
})


test("a request with nothing on sale is refused by rewriteSaleRequest, other requests are not", async () => {
  const sale = new Request("https://openrouter.ai/x", { method: "POST", body: JSON.stringify(body(["tencent/hy4"])) })
  await assert.rejects(rewriteSaleRequest(sale, []), blocked(NO_SALE_MESSAGE))
  const get = new Request("https://openrouter.ai/api/v1/models")
  assert.equal(await rewriteSaleRequest(get, []), get)
  const other = new Request("https://openrouter.ai/x", { method: "POST", body: JSON.stringify({ model: "other/model" }) })
  assert.equal(await rewriteSaleRequest(other, []), other)
})

test("the endpoint fetch reads the data list and drops models off the static list", async () => {
  const ids = await fetchDiscountedModelIds(async () => ({
    ok: true,
    json: async () => ({ data: [endpoint({ model_id: "xiaomi/mimo-v2.6-pro" }), endpoint({ model_id: "upstage/solar-pro4" })] }),
  }))
  assert.deepEqual(ids, ["xiaomi/mimo-v2.6-pro"])
  assert.deepEqual(await fetchDiscountedModelIds(async () => ({ ok: true, json: async () => ({ data: [] }) })), [])
})

test("an HTTP error or an answer without a data list is a failed refresh, not an empty one", async () => {
  await assert.rejects(fetchDiscountedModelIds(async () => ({ ok: false, status: 503 })), /503/)
  for (const payload of [{}, null, { data: null }, { data: "x" }, { data: {} }, []]) {
    await assert.rejects(fetchDiscountedModelIds(async () => ({ ok: true, json: async () => payload })), /no data/)
  }
})

function saleSetup() {
  const hooks = []
  const ctx = { session: { hook: async (name, callback, scope) => hooks.push({ name, callback, scope }) } }
  return { hooks, ctx }
}

function saleEvent(content, id = SALE_MODEL) {
  return {
    model: { providerID: SALE_PROVIDER, id },
    request: new Request("https://openrouter.ai/api/v1/chat/completions", { method: "POST", body: content }),
  }
}

function discountPayload(...ids) {
  return { ok: true, json: async () => ({ data: ids.map((id) => endpoint({ model_id: id })) }) }
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 20))

/** Runs `fn` with a scripted fetch and a captured console.warn, then restores both. */
async function withPlugin(fetchImpl, fn) {
  const realFetch = globalThis.fetch
  const realWarn = console.warn
  const logged = []
  globalThis.fetch = fetchImpl
  console.warn = (...args) => logged.push(args.join(" "))
  mock.timers.enable({ apis: ["setInterval"] })
  const { hooks, ctx } = saleSetup()
  let cleanup
  try {
    cleanup = await plugin.setup(ctx)
    await settle()
    await fn({ hook: hooks[0], hooks, tick: async () => { mock.timers.tick(REFRESH_MS); await settle() } })
  } finally {
    cleanup?.()
    mock.timers.reset()
    globalThis.fetch = realFetch
    console.warn = realWarn
  }
  return logged
}

test("the V2 plugin registers an http.request hook scoped to the SALE provider", async () => {
  assert.equal(plugin.id, "cubeone-sale")
  assert.equal(typeof plugin.setup, "function")
  await withPlugin(async () => discountPayload("qwen/qwen3.8-27b", "evil/text-only"), async ({ hook, hooks }) => {
    assert.equal(hooks.length, 1)
    assert.equal(hook.name, "http.request")
    assert.deepEqual(hook.scope, { providerID: SALE_PROVIDER })

    const event = saleEvent(JSON.stringify(body([...SALE_ALLOWED])))
    await hook.callback(event)
    assert.deepEqual((await event.request.json()).plugins[0].allowed_models, ["qwen/qwen3.8-27b"])

    const other = saleEvent(JSON.stringify(body(["evil/text-only"])), "other/model")
    const before = other.request
    await hook.callback(other)
    assert.equal(other.request, before)
  })
})

test("start: before the first refresh has finished the configured, then the static list is used", async () => {
  let release
  const gate = new Promise((resolve) => {
    release = resolve
  })
  const realFetch = globalThis.fetch
  const realWarn = console.warn
  globalThis.fetch = async () => {
    await gate
    return discountPayload("qwen/qwen3.8-27b")
  }
  console.warn = () => {}
  const { hooks, ctx } = saleSetup()
  let cleanup
  try {
    cleanup = await plugin.setup(ctx)
    const configured = saleEvent(JSON.stringify(body(["evil/text-only", "tencent/hy4"])))
    await hooks[0].callback(configured)
    assert.deepEqual((await configured.request.json()).plugins[0].allowed_models, ["tencent/hy4"])
    const foreign = saleEvent(JSON.stringify(body(["evil/text-only"])))
    await hooks[0].callback(foreign)
    assert.deepEqual((await foreign.request.json()).plugins[0].allowed_models, SORTED_STATIC)
    release()
    await settle()
    const after = saleEvent(JSON.stringify(body([...SALE_ALLOWED])))
    await hooks[0].callback(after)
    assert.deepEqual((await after.request.json()).plugins[0].allowed_models, ["qwen/qwen3.8-27b"])
  } finally {
    release()
    cleanup?.()
    globalThis.fetch = realFetch
    console.warn = realWarn
  }
})

test("offline since start: the configured list is used and nothing sensitive is logged", async () => {
  const logged = await withPlugin(
    async () => {
      throw new Error("secret-token-123 offline")
    },
    async ({ hook }) => {
      const configured = saleEvent(JSON.stringify(body(["evil/text-only", "tencent/hy4"])))
      await hook.callback(configured)
      assert.deepEqual((await configured.request.json()).plugins[0].allowed_models, ["tencent/hy4"])
      const bare = saleEvent(JSON.stringify({ model: SALE_MODEL, messages: [] }))
      await hook.callback(bare)
      assert.deepEqual((await bare.request.json()).plugins[0].allowed_models, SORTED_STATIC)
    },
  )
  assert.ok(logged.length > 0)
  assert.ok(logged.every((line) => !line.includes("secret-token-123")), logged.join("\n"))
  assert.ok(logged.every((line) => line.startsWith("cubeone-sale: ")))
})

test("a failed refresh keeps the last successful list, an empty one included", async () => {
  const answers = [discountPayload("tencent/hy4", "qwen/qwen3.8-27b"), new Error("net"), { ok: true, json: async () => ({ data: [] }) }, new Error("net")]
  let calls = 0
  const logged = await withPlugin(
    async () => {
      const answer = answers[Math.min(calls, answers.length - 1)]
      calls += 1
      if (answer instanceof Error) throw answer
      return answer
    },
    async ({ hook, tick }) => {
      const run = async (allowed) => {
        const event = saleEvent(JSON.stringify(body(allowed)))
        await hook.callback(event)
        return (await event.request.json()).plugins[0].allowed_models
      }
      assert.deepEqual(await run([...SALE_ALLOWED]), ["qwen/qwen3.8-27b", "tencent/hy4"])
      // The next refresh fails: the last successful list stays.
      await tick()
      assert.deepEqual(await run([...SALE_ALLOWED]), ["qwen/qwen3.8-27b", "tencent/hy4"])
      // The one after that succeeds with an empty list: nothing is on sale any more.
      await tick()
      await assert.rejects(run([...SALE_ALLOWED]), blocked(NO_SALE_MESSAGE))
      // And a later failure does not bring the old discounts back.
      await tick()
      await assert.rejects(run(["tencent/hy4"]), blocked(NO_SALE_MESSAGE))
    },
  )
  assert.ok(logged.includes(NO_SALE_MESSAGE))
  assert.ok(logged.every((line) => /^cubeone-sale: /.test(line)))
})

test("a non-empty discount list that later becomes empty blocks, then recovers when discounts return", async () => {
  const answers = [discountPayload("tencent/hy4"), discountPayload(), discountPayload("qwen/qwen3.8-27b")]
  let calls = 0
  await withPlugin(
    async () => answers[Math.min(calls++, answers.length - 1)],
    async ({ hook, tick }) => {
      const run = async (allowed) => {
        const event = saleEvent(JSON.stringify(body(allowed)))
        await hook.callback(event)
        return (await event.request.json()).plugins[0].allowed_models
      }
      assert.deepEqual(await run([...SALE_ALLOWED]), ["tencent/hy4"])
      await tick()
      await assert.rejects(run([...SALE_ALLOWED]), blocked(NO_SALE_MESSAGE))
      await tick()
      assert.deepEqual(await run([...SALE_ALLOWED]), ["qwen/qwen3.8-27b"])
    },
  )
})

test("no overlap between the configured list and the current discounts blocks with the fixed text", async () => {
  const logged = await withPlugin(async () => discountPayload("qwen/qwen3.8-27b"), async ({ hook }) => {
    const event = saleEvent(JSON.stringify(body(["tencent/hy4"])))
    await assert.rejects(hook.callback(event), blocked(NO_SALE_MESSAGE))
  })
  assert.deepEqual(logged, [NO_SALE_MESSAGE])
})

test("with a live refresh a narrower configured list stays narrower", async () => {
  await withPlugin(async () => discountPayload("qwen/qwen3.8-27b", "tencent/hy4"), async ({ hook }) => {
    const narrow = saleEvent(JSON.stringify(body(["tencent/hy4", "moonshotai/kimi-k3"])))
    await hook.callback(narrow)
    assert.deepEqual((await narrow.request.json()).plugins[0].allowed_models, ["tencent/hy4"])
  })
})

test("the V2 plugin refuses a SALE request it cannot check and logs only a fixed text", async () => {
  const logged = await withPlugin(async () => discountPayload("tencent/hy4"), async ({ hook }) => {
    const event = saleEvent("prompt with secret-prompt-text, not json")
    await assert.rejects(hook.callback(event), blocked(BLOCKED_MESSAGE))
  })
  assert.deepEqual(logged, [BLOCKED_MESSAGE])
})
