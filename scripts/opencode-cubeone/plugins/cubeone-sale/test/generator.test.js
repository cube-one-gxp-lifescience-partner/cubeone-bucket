import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"
import { SALE_ALLOWED } from "../sale.js"

// Runs Update-OpenCodeModels.ps1 on synthetic catalog and endpoint files. Nothing here touches the network,
// the registry or an API key, and the generated file goes to a temporary directory.
const GENERATOR = fileURLToPath(new URL("../../../Update-OpenCodeModels.ps1", import.meta.url))
const SONNET = "anthropic/claude-sonnet-5.5"
const ALIAS = "~anthropic/claude-sonnet-latest"
const SORTED_STATIC = [...SALE_ALLOWED].sort()

const pwsh = spawnSync("pwsh", ["-NoProfile", "-Command", "$PSVersionTable.PSVersion.Major"], { encoding: "utf8" })
const skip = pwsh.status === 0 ? false : "pwsh is not available"

function catalogEntry(id, inputs = ["text", "image"], extra = {}) {
  return {
    id,
    name: `Vendor: ${id}`,
    context_length: 262144,
    architecture: { input_modalities: inputs },
    supported_parameters: ["tools", "reasoning"],
    top_provider: { max_completion_tokens: 16384 },
    pricing: { prompt: "0.000001", completion: "0.000002" },
    ...extra,
  }
}

function zdrEndpoint(model, overrides = {}) {
  return {
    model_id: model,
    tag: "vendor/us",
    safety_retention: false,
    supported_parameters: ["tools", "temperature"],
    pricing: { prompt: "0.000001", completion: "0.000002", discount: 0 },
    ...overrides,
  }
}

/** The always-needed part: the default alias with an EU endpoint, the router, and optional extras. */
function baseData({ saleCatalog, saleEndpoints, catalogExtra = [], endpointExtra = [] }) {
  return {
    catalog: [
      catalogEntry(ALIAS, ["text", "image", "file"], { alias_target: { slug: SONNET }, name: "Anthropic: Claude Sonnet Latest" }),
      catalogEntry(SONNET, ["text", "image", "file"], { name: "Anthropic: Claude Sonnet 5.5" }),
      catalogEntry("openrouter/auto", ["text"], { name: "Auto Router" }),
      ...saleCatalog,
      ...catalogExtra,
    ],
    endpoints: [zdrEndpoint(SONNET, { tag: "amazon-bedrock/eu-west-1" }), ...saleEndpoints, ...endpointExtra],
  }
}

function generate(data) {
  const dir = mkdtempSync(join(tmpdir(), "cubeone-gen-"))
  try {
    writeFileSync(join(dir, "catalog.json"), JSON.stringify({ data: data.catalog }))
    writeFileSync(join(dir, "zdr.json"), JSON.stringify({ data: data.endpoints }))
    const out = join(dir, "managed.jsonc")
    const result = spawnSync(
      "pwsh",
      ["-NoProfile", "-File", GENERATOR, "-OutFile", out, "-CatalogFile", join(dir, "catalog.json"), "-ZdrEndpointsFile", join(dir, "zdr.json")],
      { encoding: "utf8" },
    )
    assert.equal(result.status, 0, `generator failed: ${result.stderr}`)
    const text = readFileSync(out, "utf8")
      .split(/\r?\n/)
      .filter((line) => !line.trimStart().startsWith("//"))
      .join("\n")
    return { config: JSON.parse(text), output: `${result.stdout}\n${result.stderr}` }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function saleEntry(config) {
  return config.providers["openrouter-zdr-sale"].models["openrouter/auto"]
}

// The generator sorts with the PowerShell culture rules; the order is not part of the contract, the members are.
function everyList(entry) {
  return [entry.body, ...entry.variants.map((variant) => variant.body)].map((body) => [...body.plugins[0].allowed_models].sort())
}

const allEligible = () => ({
  saleCatalog: SALE_ALLOWED.map((id) => catalogEntry(id)),
  // Discount 0, a fractional discount and no discount field at all: none of it may matter to the generator.
  saleEndpoints: SALE_ALLOWED.map((id, index) =>
    zdrEndpoint(id, { pricing: index % 3 === 0 ? { prompt: "0.000001", completion: "0.000002" } : { prompt: "0.000001", completion: "0.000002", discount: index % 3 === 1 ? 0 : 0.5 } }),
  ),
})

test("the generator bakes all 13 SALE models whether or not they are discounted", { skip }, () => {
  const { config } = generate(baseData(allEligible()))
  const sale = saleEntry(config)
  for (const list of everyList(sale)) assert.deepEqual(list, SORTED_STATIC)
  assert.equal(sale.variants.length, 3)
})

test("no endpoint carries a discount: the SALE list is still the full static list", { skip }, () => {
  const data = allEligible()
  data.saleEndpoints = SALE_ALLOWED.map((id) => zdrEndpoint(id, { pricing: { prompt: "0.000001", completion: "0.000002", discount: 0 } }))
  const { config } = generate(baseData(data))
  for (const list of everyList(saleEntry(config))) assert.deepEqual(list, SORTED_STATIC)
})

test("price tiers, provider filter and the empty region pin of SALE stay as they were", { skip }, () => {
  const { config } = generate(baseData(allEligible()))
  const sale = saleEntry(config)
  assert.deepEqual(sale.variants.map((variant) => variant.id), ["balanced", "cost", "intelligence"])
  assert.deepEqual(
    [sale.body, ...sale.variants.map((variant) => variant.body)].map((body) => body.plugins[0].cost_tier),
    ["medium", "medium", "low", "max"],
  )
  for (const body of [sale.body, ...sale.variants.map((variant) => variant.body)]) {
    assert.equal(body.plugins[0].id, "auto-router")
    assert.deepEqual(body.provider, { zdr: true, data_collection: "deny", allow_fallbacks: false, sort: "price" })
  }
  assert.equal(config.providers["openrouter-zdr-sale"].body.provider.zdr, true)
})

test("a SALE model without a strict ZDR tool endpoint or image input is left out with a warning", { skip }, () => {
  const [noEndpoint, noTools, retained, textOnly, missingFromCatalog, ...ready] = SALE_ALLOWED
  const data = allEligible()
  data.saleEndpoints = data.saleEndpoints.filter((entry) => entry.model_id !== noEndpoint)
  for (const entry of data.saleEndpoints) {
    if (entry.model_id === noTools) entry.supported_parameters = ["temperature"]
    if (entry.model_id === retained) entry.safety_retention = true
  }
  data.saleCatalog = data.saleCatalog
    .filter((entry) => entry.id !== missingFromCatalog)
    .map((entry) => (entry.id === textOnly ? { ...entry, architecture: { input_modalities: ["text"] } } : entry))
  const { config, output } = generate(baseData(data))
  for (const list of everyList(saleEntry(config))) assert.deepEqual(list, [...ready].sort())
  for (const id of [noEndpoint, noTools, retained, textOnly, missingFromCatalog]) {
    assert.ok(output.includes(`${id} is on the Auto (ZDR, SALE) list`), `no warning for ${id}`)
  }
})

test("a strict endpoint is enough when another endpoint of the same model keeps Safety Retention", { skip }, () => {
  const data = allEligible()
  const [first] = SALE_ALLOWED
  data.saleEndpoints.push(zdrEndpoint(first, { tag: "vendor/retained", safety_retention: true }))
  const { config } = generate(baseData(data))
  assert.ok(everyList(saleEntry(config))[0].includes(first))
})

test("a heavily discounted image model that is not on the static list never gets in", { skip }, () => {
  const extra = "vendor/discounted-vision"
  const { config } = generate(
    baseData({
      ...allEligible(),
      catalogExtra: [catalogEntry(extra)],
      endpointExtra: [zdrEndpoint(extra, { pricing: { prompt: "0.000001", completion: "0.000002", discount: 0.9 } })],
    }),
  )
  for (const list of everyList(saleEntry(config))) {
    assert.ok(!list.includes(extra))
    assert.deepEqual(list, SORTED_STATIC)
  }
})

test("with no eligible SALE model the entry is skipped and the run still succeeds", { skip }, () => {
  const { config, output } = generate(baseData({ saleCatalog: SALE_ALLOWED.map((id) => catalogEntry(id)), saleEndpoints: [] }))
  assert.deepEqual(config.providers["openrouter-zdr-sale"].models, {})
  assert.ok(output.includes("Auto (ZDR, SALE) was skipped"))
  assert.ok(config.providers["openrouter-zdr"].models["openrouter/auto"], "the EU entry is not affected")
})

test("SALE does not advertise PDF input even when the catalog reports file input, EU keeps it", { skip }, () => {
  const data = allEligible()
  data.saleCatalog = SALE_ALLOWED.map((id) => catalogEntry(id, ["text", "image", "file"]))
  const { config } = generate(baseData(data))
  const sale = saleEntry(config)
  assert.deepEqual(sale.capabilities.input, ["text", "image"])
  assert.deepEqual(sale.modalities.input, ["text", "image"])
  const eu = config.providers["openrouter-zdr"].models["openrouter/auto"]
  assert.deepEqual(eu.capabilities.input, ["text", "image", "pdf"])
  assert.deepEqual(eu.body.plugins[0].allowed_models, [SONNET])
  assert.deepEqual(eu.body.provider.only, ["amazon-bedrock/eu-west-1"])
})
