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

$config = [ordered]@{
    '$schema'    = 'https://opencode.ai/config.json'
    update       = 'disable'
    share        = 'disabled'
    websearch    = $false
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
    instructions = @(
        'C:/ProgramData/opencode/rules/*.md'
        '~/.config/opencode/rules/optional/*.md'
    )
    plugins      = @(
        [ordered]@{
            package = 'C:/ProgramData/opencode/cubeone/plugins/cubeone-stt'
            options = [ordered]@{
                endpoint = 'https://eu.openrouter.ai/api/v1'
                model    = 'mistralai/voxtral-mini-transcribe-3-0'
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
