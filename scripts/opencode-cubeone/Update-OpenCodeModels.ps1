#Requires -Version 7
<#
.SYNOPSIS
    Regenerates managed\opencode.jsonc from the curated model list and the live OpenRouter catalog.

.DESCRIPTION
    A model is only written when OpenRouter lists at least one Zero Data Retention endpoint for it that
    supports tool calls and does not rely on Safety Retention. Models that lost such an endpoint are
    dropped with a warning, so the managed config never offers a model that the ZDR routing would reject.
    Where such an endpoint is in Europe, the model is pinned to those endpoints and its price is the
    price of the cheapest one among them. A model without a European endpoint keeps OpenRouter's
    published price and is not region-pinned.
    A curated id that starts with ~ is an OpenRouter latest alias. The request keeps that alias, so a
    new release is picked up without editing this list. Zero Data Retention, the EU pin and the price
    are taken from the concrete model the alias points at today. Auto's allow-list stays on those
    concrete ids, because the router matches concrete slugs, not aliases.
    The default model and the model of every role is Auto (ZDR, EU). A role only picks the variant (cost tier):
    orchestrator and architect intelligence, developer and reviewer balanced, quick and researcher cost. Ask has
    no model and inherits the current one. If Auto (ZDR, EU) cannot be built, the script stops without
    writing a file.
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path $PSScriptRoot 'managed\opencode.jsonc'),

    # Read the catalog and the ZDR endpoint list from JSON files (the {"data": [...]} body of the OpenRouter
    # responses) instead of the network. Meant for tests with synthetic data.
    [string]$CatalogFile,
    [string]$ZdrEndpointsFile
)

$ErrorActionPreference = 'Stop'

$ProviderId = 'openrouter-zdr'
# OpenRouter's own router model. Not a real model, so it never appears on the ZDR endpoints list;
# it inherits the provider's zdr=true/data_collection=deny and is additionally pinned with an
# allowed_models allowlist (set below, after $CuratedModels is resolved) so it can only ever land
# on one of our vetted ZDR models, never on an unreviewed sibling model from the same provider.
$AutoRouterModel = 'openrouter/auto'
# Auto (ZDR, EU) is the default model and the model of every role. A role picks only the variant, which is the
# cost tier: cost = low, balanced = medium, intelligence = max. Auto is created further down; the run fails
# there when it could not be built, so no role silently ends up on another model, on SALE or on a non-EU endpoint.
# The root model has no variant: it is the untouched default body, which matches balanced (medium).
$DefaultModel = $AutoRouterModel
# OpenCode sends the model key to OpenRouter as the model id. A second key on the EU provider would also be
# openrouter/auto, so SALE gets its own provider with the same key and the same ZDR settings.
$SaleProviderId = 'openrouter-zdr-sale'
$SaleModelKey = 'openrouter/auto'
$saleModels = [ordered]@{}
# Auto may only route to models that can read screenshots. These are concrete OpenRouter slugs, because the
# router matches slugs and not aliases. The lists only ever narrow what OpenRouter reports: a model that is not
# listed here is never offered, and an empty result skips the Auto entry instead of falling back to every model.
# Auto (ZDR, EU): EU endpoint plus image and PDF input.
$AutoEuModels = @(
    'anthropic/claude-haiku-5.5'
    'anthropic/claude-opus-5.5'
    'anthropic/claude-sonnet-5.5'
    'mistralai/mistral-medium-3-5'
    'openai/gpt-6-luna'
    'openai/gpt-6.1-sol'
    'openai/gpt-6.1-terra'
)
# Auto (ZDR, SALE): image input. All of them are baked in; cubeone-sale narrows them to the discounted ones.
# Mirrored in plugins\cubeone-sale\sale.js, which a test compares against this list.
$AutoSaleModels = @(
    'deepseek/deepseek-v4-flash-vision-exp'
    'deepseek/deepseek-v4.1-flash'
    'deepseek/deepseek-v4.1-flash-1017'
    'google/gemma-4-31b-it'
    'minimax/minimax-m3.1-flash'
    'moonshotai/kimi-k2.5'
    'moonshotai/kimi-k2.7-code'
    'moonshotai/kimi-k3'
    'moonshotai/kimi-k3.1-pro'
    'qwen/qwen3.8-27b'
    'tencent/hy4'
    'xiaomi/mimo-v2.6-pro'
    'z-ai/glm-5.3-flash'
)
# ~author/family-latest follows the newest model of that family. Families without such an alias, and
# Kimi, stay on a concrete id: ~moonshotai/kimi-latest currently points at kimi-k3, which is older
# than kimi-k3.1-pro. ~deepseek/deepseek-v4-flash-latest points at the older July snapshot, so the
# flash line uses ~deepseek/deepseek-flash-latest.
$CuratedModels = @(
    '~anthropic/claude-opus-latest'
    '~anthropic/claude-sonnet-latest'
    '~anthropic/claude-haiku-latest'
    '~openai/gpt-sol-latest'
    '~openai/gpt-terra-latest'
    '~openai/gpt-luna-latest'
    '~x-ai/grok-latest'
    'mistralai/mistral-large-4-0'
    'mistralai/mistral-medium-3-5'
    'mistralai/mistral-small-2603'
    '~deepseek/deepseek-pro-latest'
    '~deepseek/deepseek-flash-latest'
    'moonshotai/kimi-k3.1-pro'
    '~z-ai/glm-latest'
    'qwen/qwen3.8-2.4t-a95b'
    'qwen/qwen3.8-27b'
    'minimax/minimax-m3.1-flash'
)

# Web search runs as the provider's native search on one pinned ZDR endpoint. OpenRouter's own
# search engines (Exa, Parallel, Perplexity) are outside ZDR and unavailable on eu.openrouter.ai.
$SearchModel = '~openai/gpt-luna-latest'
$SearchEndpoint = 'azure/eu'
$WebSearchProvider = 'cubeone-zdr'
# Pinned: OpenCode installs plugin packages from npm at startup.
$PlannotatorPackage = '@plannotator/opencode@0.28.43'
$ContextPruningPackage = '@tarquinen/opencode-dcp@3.2.0'
$MemoryPackage = 'opencode-mem@2.39.0'

$AgentRoot = Join-Path $PSScriptRoot 'agents'
$ReadOnly = @(
    [ordered]@{ action = '*'; resource = '*'; effect = 'allow' }
    [ordered]@{ action = 'edit'; resource = '*'; effect = 'deny' }
    [ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' }
)
$Agents = [ordered]@{
    ask          = [ordered]@{
        mode        = 'primary'
        description = 'Answers questions and explains code without changing files or running commands.'
        permissions = @(
            [ordered]@{ action = '*'; resource = '*'; effect = 'deny' }
            [ordered]@{ action = 'read'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'read'; resource = '*.env'; effect = 'deny' }
            [ordered]@{ action = 'read'; resource = '*.env.*'; effect = 'deny' }
            [ordered]@{ action = 'glob'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'grep'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'external_directory'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'websearch'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'webfetch'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'question'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'skill'; resource = '*'; effect = 'allow' }
        )
    }
    orchestrator = [ordered]@{
        model       = $AutoRouterModel
        variant     = 'intelligence'
        mode        = 'primary'
        description = 'Plans large software projects from requirements and coordinates subagents on other models. Edits nothing before the plan is approved.'
        permissions = @(
            [ordered]@{ action = '*'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'edit'; resource = '*'; effect = 'deny' }
            [ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' }
            [ordered]@{ action = 'subagent'; resource = 'explore'; effect = 'allow' }
            [ordered]@{ action = 'subagent'; resource = 'architect'; effect = 'allow' }
            [ordered]@{ action = 'subagent'; resource = 'researcher'; effect = 'allow' }
        )
    }
    architect    = [ordered]@{
        model       = $AutoRouterModel
        variant     = 'intelligence'
        mode        = 'subagent'
        description = 'Design, interfaces, data models and trade-offs for one question. Read-only.'
        permissions = $ReadOnly
    }
    researcher   = [ordered]@{
        # The chat model is independent of $SearchModel, which only serves the native web search backend.
        model       = $AutoRouterModel
        variant     = 'cost'
        mode        = 'subagent'
        description = 'Current external facts with sources via zero-data-retention web search. Read-only.'
        permissions = @(
            [ordered]@{ action = '*'; resource = '*'; effect = 'deny' }
            [ordered]@{ action = 'read'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'grep'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'glob'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'websearch'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'webfetch'; resource = '*'; effect = 'allow' }
        )
    }
    developer    = [ordered]@{
        model       = $AutoRouterModel
        variant     = 'balanced'
        mode        = 'subagent'
        description = 'Implements one work package of an approved plan, including its tests.'
        permissions = @(
            [ordered]@{ action = '*'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' }
        )
    }
    quick        = [ordered]@{
        model       = $AutoRouterModel
        variant     = 'cost'
        mode        = 'subagent'
        description = 'Small mechanical changes: renames, boilerplate, formatting, simple tests.'
        permissions = @(
            [ordered]@{ action = '*'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' }
        )
    }
    reviewer     = [ordered]@{
        model       = $AutoRouterModel
        variant     = 'balanced'
        mode        = 'subagent'
        description = 'Independent review of a finished work package against the plan; runs tests and the build. Read-only.'
        permissions = $ReadOnly
    }
}

function Test-EuTag([string]$Tag) {
    return $Tag -match '(^|[/-])eu($|[/-])|eu-west|eu-central|eu-north|(^|[/-])europe($|[/-])'
}

function Test-QuantizedEndpoint($Endpoint) {
    return [string]$Endpoint.tag -match '(^|[/-])(fp4|fp8|fp16|bf16|nvfp4|mxfp4|int4|int8)($|[/-])'
}

function Select-CheapestEndpoint($Endpoints) {
    return $Endpoints | Sort-Object { [double]$_.pricing.prompt }, { [double]$_.pricing.completion }, tag | Select-Object -First 1
}

function Get-MillionTokenPrice($Endpoint) {
    return [ordered]@{
        input  = [math]::Round([double]$Endpoint.pricing.prompt * 1e6, 4)
        output = [math]::Round([double]$Endpoint.pricing.completion * 1e6, 4)
    }
}

$headers = @{ 'User-Agent' = 'cubeone-bucket/opencode-models' }
if ($CatalogFile) {
    $catalog = (Get-Content -LiteralPath $CatalogFile -Raw -Encoding utf8 | ConvertFrom-Json).data
}
else {
    $catalog = (Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/models' -Headers $headers).data
}
if ($ZdrEndpointsFile) {
    $zdrEndpoints = (Get-Content -LiteralPath $ZdrEndpointsFile -Raw -Encoding utf8 | ConvertFrom-Json).data
}
else {
    $zdrEndpoints = (Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/endpoints/zdr' -Headers $headers).data
}

$models = [ordered]@{}
$concreteOf = @{}
foreach ($id in $CuratedModels) {
    $model = $catalog | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $model) {
        Write-Warning "$id is no longer in the OpenRouter catalog and was skipped."
        continue
    }
    # An alias has no own endpoints. ZDR and the EU pin come from the model it points at today.
    $concrete = if ($model.alias_target.slug) { [string]$model.alias_target.slug } else { $id }
    $concreteOf[$id] = $concrete
    $served = if ($concrete -eq $id) { $model } else { $catalog | Where-Object { $_.id -eq $concrete } | Select-Object -First 1 }
    if (-not $served) { $served = $model }
    $endpoints = @($zdrEndpoints | Where-Object {
            $_.model_id -eq $concrete -and -not $_.safety_retention -and ($_.supported_parameters -contains 'tools')
        })
    if ($endpoints.Count -eq 0) {
        Write-Warning "$id ($concrete) has no strict ZDR endpoint with tool support and was skipped."
        continue
    }

    # OpenCode V2 reads capabilities.input and ignores the legacy modalities block (checked against
    # opencode 2.2.5: a pdf only in modalities is rejected with "this model does not support pdf input", a pdf in
    # capabilities.input reaches the provider as a file part). Without image here, a pasted screenshot is
    # replaced by that message before the model sees the file. modalities is still written for older readers.
    # OpenRouter calls a PDF "file"; OpenCode's modality name is "pdf".
    $openCodeInput = [System.Collections.Generic.List[string]]::new()
    [void]$openCodeInput.Add('text')
    foreach ($name in @($served.architecture.input_modalities)) {
        if ($name -eq 'image' -and -not $openCodeInput.Contains('image')) { [void]$openCodeInput.Add('image') }
        if (($name -eq 'file' -or $name -eq 'pdf') -and -not $openCodeInput.Contains('pdf')) { [void]$openCodeInput.Add('pdf') }
    }
    $modalities = @($openCodeInput)
    $capabilities = [ordered]@{
        tools  = $true
        input  = $modalities
        output = @('text')
    }
    if ($served.supported_parameters -contains 'reasoning') {
        $capabilities.reasoning = [ordered]@{ supported = $true; effort = @('low', 'medium', 'high') }
    }
    $output = [int]($served.top_provider.max_completion_tokens)
    if ($output -le 0) {
        $output = 32000
    }

    # A full-precision EU endpoint wins over a quantized one. The shown price is the cheapest
    # endpoint the pin still allows, because the request sorts by price inside that set.
    $eu = @($endpoints | Where-Object { Test-EuTag $_.tag })
    $pricedFrom = $endpoints
    $entry = [ordered]@{
        name         = ($model.name -replace '^[^:]+:\s*', '')
        modalities   = [ordered]@{ input = @($modalities); output = @('text') }
        capabilities = $capabilities
        limit        = [ordered]@{ context = [int]$served.context_length; output = $output }
    }
    if ($eu.Count -gt 0) {
        $full = @($eu | Where-Object { -not (Test-QuantizedEndpoint $_) })
        $pinned = if ($full.Count -gt 0) { $full } else { $eu }
        $pricedFrom = $pinned
        $entry.body = [ordered]@{
            provider = [ordered]@{
                zdr              = $true
                data_collection  = 'deny'
                only             = @($pinned | ForEach-Object tag | Sort-Object -Unique)
                allow_fallbacks  = $false
                sort             = 'price'
            }
        }
    }
    if ($eu.Count -gt 0) {
        $entry.cost = Get-MillionTokenPrice (Select-CheapestEndpoint $pricedFrom)
    }
    else {
        $entry.cost = [ordered]@{
            input  = [math]::Round([double]$served.pricing.prompt * 1e6, 4)
            output = [math]::Round([double]$served.pricing.completion * 1e6, 4)
        }
    }
    $models[$id] = $entry
    $where = if ($eu.Count -gt 0) { ($entry.body.provider.only -join ',') } else { 'zdr' }
    Write-Host ("{0}  ->  {1}  {2}/{3}  {4}" -f $id, $concrete, $entry.cost.input, $entry.cost.output, $where)
}

$autoRouter = $catalog | Where-Object { $_.id -eq $AutoRouterModel } | Select-Object -First 1
# Auto is one request, so it cannot carry a different EU pin per child model.
# It therefore only offers models that have an EU endpoint, and the request itself
# is pinned to the union of those endpoints. The router matches concrete slugs, so the
# allow-list is the model each alias points at today, not the alias itself.
# On top of that only $AutoEuModels qualify, and each must take image and PDF input. An alias that now
# points at another slug drops out here instead of widening the list.
$euKeys = @($models.Keys | Where-Object {
        $null -ne $models[$_].body.provider.only -and
        $AutoEuModels -contains $concreteOf[$_] -and
        $models[$_].modalities.input -contains 'image' -and
        $models[$_].modalities.input -contains 'pdf'
    })
$euSlugs = @($euKeys | ForEach-Object { $concreteOf[$_] })
foreach ($slug in $AutoEuModels) {
    if ($euSlugs -notcontains $slug) {
        Write-Warning "$slug is on the Auto (ZDR, EU) list but has no EU endpoint with image and PDF input. It was left out."
    }
}
if (-not $autoRouter) {
    Write-Warning "$AutoRouterModel is no longer in the OpenRouter catalog and was skipped."
}
elseif ($euKeys.Count -eq 0) {
    Write-Warning 'No model on the Auto (ZDR, EU) list passed the check. Auto (ZDR, EU) was skipped.'
}
else {
    $allowedModels = @($euSlugs | Sort-Object -Unique)
    # The region pin stays the union over every curated model with an EU endpoint, as before the image/PDF
    # list existed. The allow-list above is what narrows the models; the pin only limits the regions.
    $euOnly = @($models.Keys | ForEach-Object { $models[$_].body.provider.only } | Sort-Object -Unique)
    $autoModels = @($euKeys | ForEach-Object { $models[$_] })
    $minContext = ($autoModels | ForEach-Object { $_.limit.context } | Measure-Object -Minimum).Minimum
    $minOutput = ($autoModels | ForEach-Object { $_.limit.output } | Measure-Object -Minimum).Minimum

    # OpenRouter cost_tier is a band: low is the cheap end, max the most capable.
    # Each variant repeats the allow-list because OpenCode replaces arrays instead of merging them.
    $autoBody = {
        param([string]$Tier)
        $body = [ordered]@{
            plugins = @(
                [ordered]@{
                    id             = 'auto-router'
                    allowed_models = @($allowedModels)
                    cost_tier      = $Tier
                }
            )
        }
        if ($euOnly.Count -gt 0) {
            $body.provider = [ordered]@{
                zdr             = $true
                data_collection = 'deny'
                only            = @($euOnly)
                allow_fallbacks = $false
                sort            = 'price'
            }
        }
        $body
    }
    # Auto may be routed to a model that can see a screenshot or a PDF. Declaring only text
    # makes OpenCode drop the attachment and the answer says the screenshot cannot be read.
    $autoInput = [System.Collections.Generic.List[string]]::new()
    [void]$autoInput.Add('text')
    foreach ($model in $autoModels) {
        foreach ($name in @($model.modalities.input)) {
            if (-not $autoInput.Contains([string]$name)) { [void]$autoInput.Add([string]$name) }
        }
    }
    $autoModalities = @($autoInput)
    $models[$AutoRouterModel] = [ordered]@{
        name         = 'Auto (ZDR, EU)'
        modalities   = [ordered]@{ input = $autoModalities; output = @('text') }
        capabilities = [ordered]@{
            tools  = $true
            input  = $autoModalities
            output = @('text')
        }
        limit        = [ordered]@{ context = [int]$minContext; output = [int]$minOutput }
        body         = & $autoBody 'medium'
        # Balanced listed first: it is also the untouched default body above, so it matches what a session
        # gets when no variant is picked at all.
        variants     = @(
            [ordered]@{ id = 'balanced'; body = (& $autoBody 'medium') }
            [ordered]@{ id = 'cost'; body = (& $autoBody 'low') }
            [ordered]@{ id = 'intelligence'; body = (& $autoBody 'max') }
        )
    }
}

# The default model and every role run on Auto (ZDR, EU). Without it there is nothing safe to fall back to:
# not the old Sonnet alias, not another provider and not SALE. The run stops instead of writing such a config.
if (-not $models.Contains($DefaultModel)) {
    throw "The default model $DefaultModel (Auto, ZDR, EU) could not be built: it needs the router in the catalog and an EU model with image and PDF input. No config was written."
}
foreach ($roleName in $Agents.Keys) {
    $role = $Agents[$roleName]
    if (-not $role.model) { continue }
    $roleVariants = @($models[$role.model].variants | ForEach-Object { $_.id })
    if (-not $models.Contains($role.model) -or $roleVariants -notcontains $role.variant) {
        throw "Agent $roleName uses $($role.model) variant '$($role.variant)', which is not generated. No config was written."
    }
}

# Sale offers every model of $AutoSaleModels that has a strict ZDR endpoint with tool support and takes image
# input, whether or not it is discounted right now: that list is the fixed upper bound and a run of this script
# must not shrink it. cubeone-sale narrows it to the currently discounted models on every request. The baked
# list is also what OpenCode uses before the first successful refresh and while the discount list is offline.
# No EU pin: provider.only stays absent.
$saleIds = @(
    $AutoSaleModels |
        Where-Object {
            $slug = $_
            $served = $catalog | Where-Object { $_.id -eq $slug } | Select-Object -First 1
            $endpoint = $zdrEndpoints | Where-Object {
                $_.model_id -eq $slug -and
                -not $_.safety_retention -and
                ($_.supported_parameters -contains 'tools')
            } | Select-Object -First 1
            $ready = $null -ne $served -and $null -ne $endpoint -and
                (@($served.architecture.input_modalities) -contains 'image')
            if (-not $ready) {
                Write-Warning "$slug is on the Auto (ZDR, SALE) list but has no strict ZDR endpoint with tools and image input. It was left out."
            }
            $ready
        } |
        Sort-Object -Unique
)
if ($saleIds.Count -eq 0) {
    Write-Warning 'No model on the SALE list has a strict ZDR endpoint with tools and image input. Auto (ZDR, SALE) was skipped.'
}
else {
    $saleCatalog = @($catalog | Where-Object { $saleIds -contains $_.id })
    $saleInput = [System.Collections.Generic.List[string]]::new()
    [void]$saleInput.Add('text')
    # SALE offers text and images only, even when the catalog reports file input. A PDF sent to a model without
    # native file input is parsed by OpenRouter with Mistral OCR, which has no guaranteed Zero Data Retention.
    # Without pdf here OpenCode refuses the attachment before anything leaves the machine.
    foreach ($served in $saleCatalog) {
        foreach ($name in @($served.architecture.input_modalities)) {
            if ($name -eq 'image' -and -not $saleInput.Contains('image')) { [void]$saleInput.Add('image') }
        }
    }
    $saleModalities = @($saleInput)
    $saleContexts = @($saleCatalog | ForEach-Object { [int]$_.context_length } | Where-Object { $_ -gt 0 })
    $saleOutputs = @($saleCatalog | ForEach-Object { [int]$_.top_provider.max_completion_tokens } | Where-Object { $_ -gt 0 })
    $saleContext = if ($saleContexts.Count -gt 0) { ($saleContexts | Measure-Object -Minimum).Minimum } else { 131072 }
    $saleOutput = if ($saleOutputs.Count -gt 0) { ($saleOutputs | Measure-Object -Minimum).Minimum } else { 16384 }
    $saleBody = {
        param([string]$Tier)
        [ordered]@{
            plugins  = @(
                [ordered]@{
                    id             = 'auto-router'
                    allowed_models = @($saleIds)
                    cost_tier      = $Tier
                }
            )
            provider = [ordered]@{
                zdr             = $true
                data_collection = 'deny'
                allow_fallbacks = $false
                sort            = 'price'
            }
        }
    }
    $saleModels[$SaleModelKey] = [ordered]@{
        name         = 'Auto (ZDR, SALE)'
        modalities   = [ordered]@{ input = $saleModalities; output = @('text') }
        capabilities = [ordered]@{
            tools  = $true
            input  = $saleModalities
            output = @('text')
        }
        limit        = [ordered]@{ context = [int]$saleContext; output = [int]$saleOutput }
        body         = & $saleBody 'medium'
        variants     = @(
            [ordered]@{ id = 'balanced'; body = (& $saleBody 'medium') }
            [ordered]@{ id = 'cost'; body = (& $saleBody 'low') }
            [ordered]@{ id = 'intelligence'; body = (& $saleBody 'max') }
        )
    }
    Write-Host ("Auto (ZDR, SALE)  ->  {0} models" -f $saleIds.Count)
}

$searchConcrete = if ($concreteOf.ContainsKey($SearchModel)) { $concreteOf[$SearchModel] } else { $SearchModel }
$searchReady = @($zdrEndpoints | Where-Object {
        $_.model_id -eq $searchConcrete -and $_.tag -eq $SearchEndpoint -and -not $_.safety_retention -and
        $_.native_tools -and $_.native_tools.'openrouter:web_search'
    }).Count -gt 0
if (-not $searchReady) {
    Write-Warning "$SearchModel has no ZDR endpoint $SearchEndpoint with native web search. Web search is disabled."
}

$agentConfig = [ordered]@{}
foreach ($name in $Agents.Keys) {
    $agent = $Agents[$name]
    if ($name -eq 'researcher' -and -not $searchReady) {
        continue
    }
    $agentConfig[$name] = [ordered]@{}
    # Agents without a model keep the model selected in the current session.
    if ($agent.model) {
        # No fallback: the role model was checked above and a missing one has already stopped the run.
        $agentConfig[$name].model = [ordered]@{
            providerID = $ProviderId
            model      = $agent.model
            variant    = $agent.variant
        }
    }
    $agentConfig[$name].mode = $agent.mode
    $agentConfig[$name].description = $agent.description
    $agentConfig[$name].system = (Get-Content -LiteralPath (Join-Path $AgentRoot "$name.md") -Raw -Encoding utf8).Trim()
    $agentConfig[$name].permissions = @($agent.permissions)
}
if (-not $searchReady) {
    $agentConfig.orchestrator.permissions = @($agentConfig.orchestrator.permissions | Where-Object { $_.resource -ne 'researcher' })
}

$PipelineCommand = @'
Prüfe die Pipelines für das Repository im aktuellen Arbeitsverzeichnis über den MCP-Server cube-git.

1. Ermittle das Projekt aus `git remote get-url origin` (Pfad auf git.cubeone.de) und den aktuellen Branch.
2. Zeige die letzten Pipelines dieses Branches mit list_pipelines: Nummer, Status, Commit, Zeit.
3. Ist die neueste fehlgeschlagen, hole mit get_pipeline (include jobs, job_status failed) die fehlgeschlagenen Jobs und mit get_job (include log, from end) das Ende ihrer Logs.
4. Nenne die Ursache und die Stelle im Code. Behebe den Fehler im lokalen Repository und prüfe die Änderung lokal, soweit möglich.
5. Committe und pushe erst nach meiner Bestätigung. Danach kannst du die Pipeline mit save_pipeline neu starten.

Zusatz vom Benutzer: $ARGUMENTS
'@ -replace "`r`n", "`n"
$TicketCommand = 'Lade das Ticket $ARGUMENTS aus cube project mit redmine_ticket. Fasse Ziel, Akzeptanzkriterien und offene Fragen kurz zusammen und schlage einen Umsetzungsplan für dieses Repository vor. Beginne mit der Umsetzung erst nach meiner Bestätigung.'
$SshSetupCommand = 'Richte OpenCode auf dem SSH-Ziel $ARGUMENTS mit dem Werkzeug ssh_einrichten ein. Melde kurz das Ergebnis.'

$config = [ordered]@{
    '$schema'    = 'https://opencode.ai/config.json'
    update       = 'disable'
    share        = 'disabled'
    websearch    = $(if ($searchReady) { [ordered]@{ provider = $WebSearchProvider } } else { $false })
    model        = "$ProviderId/$DefaultModel"
    providers    = [ordered]@{
        $ProviderId = [ordered]@{
            name     = 'OpenRouter (ZDR)'
            package  = '@opencode/ai/providers/openrouter'
            env      = @('OPENROUTER_API_KEY')
            settings = [ordered]@{ baseURL = 'https://openrouter.ai/api/v1' }
            headers  = [ordered]@{ 'HTTP-Referer' = 'https://cubeone.de'; 'X-Title' = 'OpenCode cube one' }
            body     = [ordered]@{ provider = [ordered]@{ zdr = $true; data_collection = 'deny' } }
            models   = $models
        }
        $SaleProviderId = [ordered]@{
            name     = 'OpenRouter (ZDR, SALE)'
            package  = '@opencode/ai/providers/openrouter'
            env      = @('OPENROUTER_API_KEY')
            settings = [ordered]@{ baseURL = 'https://openrouter.ai/api/v1' }
            headers  = [ordered]@{ 'HTTP-Referer' = 'https://cubeone.de'; 'X-Title' = 'OpenCode cube one' }
            body     = [ordered]@{ provider = [ordered]@{ zdr = $true; data_collection = 'deny' } }
            models   = $saleModels
        }
    }
    policies     = @(
        [ordered]@{ action = 'provider.use'; resource = '*'; effect = 'deny' }
        [ordered]@{ action = 'provider.use'; resource = $ProviderId; effect = 'allow' }
        [ordered]@{ action = 'provider.use'; resource = $SaleProviderId; effect = 'allow' }
        [ordered]@{ action = 'integration.connect'; resource = '*'; effect = 'deny' }
        [ordered]@{ action = 'integration.use'; resource = '*'; effect = 'deny' }
        [ordered]@{ action = 'integration.use'; resource = $ProviderId; effect = 'allow' }
        [ordered]@{ action = 'integration.use'; resource = $SaleProviderId; effect = 'allow' }
        # OpenCode registers every remote MCP server with OAuth as integration mcp_<sha1>.
        [ordered]@{ action = 'integration.use'; resource = 'mcp_*'; effect = 'allow' }
        # Registered by the cubeone-redmine plugin; plugin integrations need both actions, MCP ones only use.
        [ordered]@{ action = 'integration.connect'; resource = 'redmine'; effect = 'allow' }
        [ordered]@{ action = 'integration.use'; resource = 'redmine'; effect = 'allow' }
        # The last matching statement wins and this document is read after the user's config, so a user
        # "plugin.use deny" cannot switch off a managed plugin. The resource is the package as configured.
        [ordered]@{ action = 'plugin.use'; resource = 'C:/ProgramData/opencode/cubeone/plugins/*'; effect = 'allow' }
        [ordered]@{ action = 'plugin.use'; resource = $PlannotatorPackage; effect = 'allow' }
        [ordered]@{ action = 'plugin.use'; resource = $ContextPruningPackage; effect = 'allow' }
        [ordered]@{ action = 'plugin.use'; resource = $MemoryPackage; effect = 'allow' }
    )
    # GitLab's own MCP server (branded "cube git"): OAuth with dynamic client registration, pipelines, jobs and logs.
    mcp          = [ordered]@{
        servers = [ordered]@{
            'cube-git' = [ordered]@{ type = 'remote'; url = 'https://git.cubeone.de/api/v4/mcp' }
        }
    }
    commands     = [ordered]@{
        ask      = [ordered]@{
            description = 'Ask questions and explain code without making changes'
            agent       = 'ask'
            subagent    = $false
            template    = 'Answer the following question without making changes. If no question is supplied, ask what the user wants to know. Stay in Ask mode for follow-up questions. Question: $ARGUMENTS'
        }
        pipeline = [ordered]@{
            description = 'Pipelines dieses Repositorys in cube git prüfen und Fehler beheben'
            template    = $PipelineCommand
        }
        ticket   = [ordered]@{
            description = 'Ticket aus cube project laden und bearbeiten, z. B. /ticket 1234'
            template    = $TicketCommand
        }
        'ssh-einrichten' = [ordered]@{
            description = 'OpenCode auf einem SSH-Ziel aus ~/.ssh/config jetzt einrichten, z. B. /ssh-einrichten coding-vm-2'
            template    = $SshSetupCommand
        }
    }
    agents       = $agentConfig
    # Mandatory rules that hold in every session. The optional counterpart (rules/optional) and rules tied to
    # file types (vorgaben\) are loaded and injected by cubeone-vorgaben instead, so they can be listed and the
    # optional ones toggled from the Richtlinien GUI without a restart.
    instructions = @(
        'C:/ProgramData/opencode/rules/*.md'
    )
    plugins      = @(
        [ordered]@{
            package = 'C:/ProgramData/opencode/cubeone/plugins/cubeone-stt'
            options = [ordered]@{
                endpoint        = 'https://eu.openrouter.ai/api/v1'
                model           = 'mistralai/voxtral-mini-transcribe-3-0'
                search          = $searchReady
                search_model    = $SearchModel
                search_endpoint = $SearchEndpoint
            }
        }
        [ordered]@{
            package = $PlannotatorPackage
            options = [ordered]@{
                workflow       = 'plan-agent'
                planningAgents = @('plan', 'orchestrator')
            }
        }
        # opencode-pty's "server" export is the V1 plugin. cubeone-pty loads the V2 entry.
        [ordered]@{
            package = 'C:/ProgramData/opencode/cubeone/plugins/cubeone-pty'
            options = [ordered]@{
                hostname  = '127.0.0.1'
                port      = 0
                autostart = $false
            }
        }
        # Managed folder first: a user file cannot replace a managed rule of the same name.
        [ordered]@{
            package = 'C:/ProgramData/opencode/cubeone/plugins/cubeone-vorgaben'
            options = [ordered]@{
                dirs           = @('C:/ProgramData/opencode/vorgaben', '~/.config/opencode/vorgaben')
                gate           = $true
                rulesMandatory = 'C:/ProgramData/opencode/rules'
                rulesOptional  = '~/.config/opencode/rules/optional'
                disabledFile   = '~/.config/opencode/vorgaben-deaktiviert.json'
                # Models a user config adds to this provider are disabled.
                models         = [ordered]@{ $ProviderId = @($models.Keys); $SaleProviderId = @($saleModels.Keys) }
            }
        }
        [ordered]@{
            package = 'C:/ProgramData/opencode/cubeone/plugins/cubeone-mcp'
        }
        # GUI only, no server part. Fills an empty SSH server list of the Desktop app from the user's ~/.ssh/config.
        [ordered]@{
            package = 'C:/ProgramData/opencode/cubeone/plugins/cubeone-ssh-hosts'
        }
        # Translates a project's own .cursor/rules/*.mdc into OpenCode Skills, scoped to that project only.
        [ordered]@{
            package = 'C:/ProgramData/opencode/cubeone/plugins/cubeone-cursor-skills'
        }
        # Public OAuth client (PKCE, read-only scopes) registered under Administration > Applications.
        [ordered]@{
            package = 'C:/ProgramData/opencode/cubeone/plugins/cubeone-redmine'
            options = [ordered]@{
                url      = 'https://project.cubeone.de'
                clientId = 'TIq0UQ2DABBw02Chl2_oe-Z743kLlb4zrKLrB65G0GA'
            }
        }
        $ContextPruningPackage
        $MemoryPackage
        # Narrows the SALE allow-list to the models that are discounted right now, never beyond $AutoSaleModels.
        # A V2 http.request hook on the SALE provider does that on the outgoing request.
        [ordered]@{
            package = 'C:/ProgramData/opencode/cubeone/plugins/cubeone-sale'
        }
        # Runs after DCP. Removes compact ids and the compression reminder from the text the chat shows.
        [ordered]@{
            package = 'C:/ProgramData/opencode/cubeone/plugins/cubeone-dcp-view'
        }
    )
}

$header = @(
    '// Managed by the cubeone-bucket opencode-desktop manifest. Do not edit on the machine.'
    '// Regenerate with scripts\opencode-cubeone\Update-OpenCodeModels.ps1.'
    "// Model list checked against https://openrouter.ai/api/v1/endpoints/zdr on $((Get-Date).ToString('yyyy-MM-dd')). EU endpoints are pinned where one exists."
)
$json = $config | ConvertTo-Json -Depth 20
$utf8WithoutBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($OutFile, (($header + $json) -join "`r`n") + "`r`n", $utf8WithoutBom)
Write-Host "Wrote $($models.Count) models to $OutFile" -ForegroundColor Green
