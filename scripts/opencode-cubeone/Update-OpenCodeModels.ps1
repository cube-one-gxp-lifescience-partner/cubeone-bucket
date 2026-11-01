#Requires -Version 7
<#
.SYNOPSIS
    Regenerates managed\opencode.jsonc from the curated model list and the live OpenRouter catalog.

.DESCRIPTION
    A model is only written when OpenRouter lists at least one Zero Data Retention endpoint for it that
    supports tool calls and does not rely on Safety Retention. Models that lost such an endpoint are
    dropped with a warning, so the managed config never offers a model that the ZDR routing would reject.
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path $PSScriptRoot 'managed\opencode.jsonc')
)

$ErrorActionPreference = 'Stop'

$ProviderId = 'openrouter-zdr'
$DefaultModel = 'anthropic/claude-sonnet-5.5'
# OpenRouter's own router model. Not a real model, so it never appears on the ZDR endpoints list;
# it inherits the provider's zdr=true/data_collection=deny and is additionally pinned with an
# allowed_models allowlist (set below, after $CuratedModels is resolved) so it can only ever land
# on one of our vetted ZDR models, never on an unreviewed sibling model from the same provider.
$AutoRouterModel = 'openrouter/auto'
$CuratedModels = @(
    'anthropic/claude-opus-5.5'
    'anthropic/claude-sonnet-5.5'
    'anthropic/claude-haiku-5.5'
    'openai/gpt-6.1-sol'
    'openai/gpt-6.1-terra'
    'openai/gpt-6-luna'
    'x-ai/grok-4.7'
    'mistralai/mistral-large-4-0'
    'mistralai/mistral-medium-3-5'
    'mistralai/mistral-small-2603'
    'deepseek/deepseek-v4-pro-0813'
    'deepseek/deepseek-v4.1-flash'
    'moonshotai/kimi-k3.1-pro'
    'z-ai/glm-5.3'
    'qwen/qwen3.8-2.4t-a95b'
    'qwen/qwen3.8-27b'
    'minimax/minimax-m3'
)

# Web search runs as the provider's native search on one pinned ZDR endpoint. OpenRouter's own
# search engines (Exa, Parallel, Perplexity) are outside ZDR and unavailable on eu.openrouter.ai.
$SearchModel = 'openai/gpt-6-luna'
$SearchEndpoint = 'azure/eu'
$WebSearchProvider = 'cubeone-zdr'
# Pinned: OpenCode installs plugin packages from npm at startup.
$PlannotatorPackage = '@plannotator/opencode@0.28.43'

$AgentRoot = Join-Path $PSScriptRoot 'agents'
$ReadOnly = @(
    [ordered]@{ action = '*'; resource = '*'; effect = 'allow' }
    [ordered]@{ action = 'edit'; resource = '*'; effect = 'deny' }
    [ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' }
)
$Agents = [ordered]@{
    orchestrator = [ordered]@{
        model       = 'anthropic/claude-opus-5.5'
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
        model       = 'anthropic/claude-opus-5.5'
        mode        = 'subagent'
        description = 'Design, interfaces, data models and trade-offs for one question. Read-only.'
        permissions = $ReadOnly
    }
    researcher   = [ordered]@{
        model       = $SearchModel
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
        model       = 'anthropic/claude-sonnet-5.5'
        mode        = 'subagent'
        description = 'Implements one work package of an approved plan, including its tests.'
        permissions = @(
            [ordered]@{ action = '*'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' }
        )
    }
    quick        = [ordered]@{
        model       = 'anthropic/claude-haiku-5.5'
        mode        = 'subagent'
        description = 'Small mechanical changes: renames, boilerplate, formatting, simple tests.'
        permissions = @(
            [ordered]@{ action = '*'; resource = '*'; effect = 'allow' }
            [ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' }
        )
    }
    reviewer     = [ordered]@{
        model       = 'openai/gpt-6.1-sol'
        mode        = 'subagent'
        description = 'Independent review of a finished work package against the plan; runs tests and the build. Read-only.'
        permissions = $ReadOnly
    }
}

$headers = @{ 'User-Agent' = 'cubeone-bucket/opencode-models' }
$catalog = (Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/models' -Headers $headers).data
$zdrEndpoints = (Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/endpoints/zdr' -Headers $headers).data

$models = [ordered]@{}
foreach ($id in $CuratedModels) {
    $model = $catalog | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $model) {
        Write-Warning "$id is no longer in the OpenRouter catalog and was skipped."
        continue
    }
    $endpoints = @($zdrEndpoints | Where-Object {
            $_.model_id -eq $id -and -not $_.safety_retention -and ($_.supported_parameters -contains 'tools')
        })
    if ($endpoints.Count -eq 0) {
        Write-Warning "$id has no strict ZDR endpoint with tool support and was skipped."
        continue
    }

    $modalities = @($model.architecture.input_modalities | Where-Object { $_ -in @('text', 'image') })
    $capabilities = [ordered]@{
        tools  = $true
        input  = $modalities
        output = @('text')
    }
    if ($model.supported_parameters -contains 'reasoning') {
        $capabilities.reasoning = [ordered]@{ supported = $true; effort = @('low', 'medium', 'high') }
    }
    $output = [int]($model.top_provider.max_completion_tokens)
    if ($output -le 0) {
        $output = 32000
    }

    $models[$id] = [ordered]@{
        name         = ($model.name -replace '^[^:]+:\s*', '')
        capabilities = $capabilities
        limit        = [ordered]@{ context = [int]$model.context_length; output = $output }
        cost         = [ordered]@{
            input  = [math]::Round([double]$model.pricing.prompt * 1e6, 4)
            output = [math]::Round([double]$model.pricing.completion * 1e6, 4)
        }
    }
}

if (-not $models.Contains($DefaultModel)) {
    throw "The default model $DefaultModel did not pass the ZDR check. Pick another default."
}

$autoRouter = $catalog | Where-Object { $_.id -eq $AutoRouterModel } | Select-Object -First 1
if (-not $autoRouter) {
    Write-Warning "$AutoRouterModel is no longer in the OpenRouter catalog and was skipped."
}
else {
    # Minimum context/output across the vetted models so a prompt that fits never overflows
    # whichever of them the router actually picks.
    $allowedModels = @($models.Keys)
    $minContext = ($models.Values | ForEach-Object { $_.limit.context } | Measure-Object -Minimum).Minimum
    $minOutput = ($models.Values | ForEach-Object { $_.limit.output } | Measure-Object -Minimum).Minimum

    # OpenRouter cost_tier is a band: low is the cheap end, max the most capable.
    # Each variant repeats the allow-list because OpenCode replaces arrays instead of merging them.
    $autoBody = {
        param([string]$Tier)
        [ordered]@{
            plugins = @(
                [ordered]@{
                    id             = 'auto-router'
                    allowed_models = @($allowedModels)
                    cost_tier      = $Tier
                }
            )
        }
    }
    $models[$AutoRouterModel] = [ordered]@{
        name         = 'Auto (ZDR)'
        capabilities = [ordered]@{
            tools  = $true
            input  = @('text')
            output = @('text')
        }
        limit        = [ordered]@{ context = [int]$minContext; output = [int]$minOutput }
        body         = & $autoBody 'medium'
        variants     = @(
            [ordered]@{ id = 'cost'; body = (& $autoBody 'low') }
            [ordered]@{ id = 'balanced'; body = (& $autoBody 'medium') }
            [ordered]@{ id = 'intelligence'; body = (& $autoBody 'max') }
        )
    }
}

$searchReady = @($zdrEndpoints | Where-Object {
        $_.model_id -eq $SearchModel -and $_.tag -eq $SearchEndpoint -and -not $_.safety_retention -and
        $_.native_tools -and $_.native_tools.'openrouter:web_search'
    }).Count -gt 0
if (-not $searchReady) {
    Write-Warning "$SearchModel has no ZDR endpoint $SearchEndpoint with native web search. Web search is disabled."
}

$agentConfig = [ordered]@{}
foreach ($name in $Agents.Keys) {
    $agent = $Agents[$name]
    $modelId = $agent.model
    if (-not $models.Contains($modelId)) {
        Write-Warning "Agent $name uses $modelId, which did not pass the ZDR check. It falls back to $DefaultModel."
        $modelId = $DefaultModel
    }
    if ($name -eq 'researcher' -and -not $searchReady) {
        continue
    }
    $agentConfig[$name] = [ordered]@{
        model       = [ordered]@{ providerID = $ProviderId; model = $modelId }
        mode        = $agent.mode
        description = $agent.description
        system      = (Get-Content -LiteralPath (Join-Path $AgentRoot "$name.md") -Raw -Encoding utf8).Trim()
        permissions = @($agent.permissions)
    }
}
if (-not $searchReady) {
    $agentConfig.orchestrator.permissions = @($agentConfig.orchestrator.permissions | Where-Object { $_.resource -ne 'researcher' })
}

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
    }
    policies     = @(
        [ordered]@{ action = 'provider.use'; resource = '*'; effect = 'deny' }
        [ordered]@{ action = 'provider.use'; resource = $ProviderId; effect = 'allow' }
        [ordered]@{ action = 'integration.connect'; resource = '*'; effect = 'deny' }
        [ordered]@{ action = 'integration.use'; resource = '*'; effect = 'deny' }
        [ordered]@{ action = 'integration.use'; resource = $ProviderId; effect = 'allow' }
        # OpenCode registers every remote MCP server with OAuth as integration mcp_<sha1>.
        [ordered]@{ action = 'integration.use'; resource = 'mcp_*'; effect = 'allow' }
    )
    agents       = $agentConfig
    instructions = @(
        'C:/ProgramData/opencode/rules/*.md'
        '~/.config/opencode/rules/optional/*.md'
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
    )
}

$header = @(
    '// Managed by the cubeone-bucket opencode-desktop manifest. Do not edit on the machine.'
    '// Regenerate with scripts\opencode-cubeone\Update-OpenCodeModels.ps1.'
    "// Model list checked against https://openrouter.ai/api/v1/endpoints/zdr on $((Get-Date).ToString('yyyy-MM-dd'))."
)
$json = $config | ConvertTo-Json -Depth 20
$utf8WithoutBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($OutFile, (($header + $json) -join "`r`n") + "`r`n", $utf8WithoutBom)
Write-Host "Wrote $($models.Count) models to $OutFile" -ForegroundColor Green
