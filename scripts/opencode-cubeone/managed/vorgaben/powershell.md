---
titel: PowerShell Coding Standards
pfade:
  - "**/*.psd1"
  - "**/*.psm1"
  - "**/*.ps1"
---
# PowerShell Coding Standards – cube one GmbH

## Normative Basis

- **Microsoft PowerShell Style Guide (PSSA)** – PSScriptAnalyzer
- **PowerShell Practice and Style Guide** (https://poshcode.gitbook.io/powershell-practice-and-style)
- **cube one SWE Guideline V2, Chapter 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- **Tooling:** PSScriptAnalyzer, VS Code PowerShell Extension

---

## Author from Git (required)

- The `Author` field in comment-based help (`.NOTES`) **must** use the locally effective Git user name.
- Resolve with: `git config user.name` (local → global).
- **Never** use a placeholder (`<Author Name>`), a hardcoded guess, or a guessed name.
- If `user.name` is missing, ask to set it via `git config user.name` – do not invent a name.

```bash
git config user.name
```

---

## Language (SWE 4.4.1)

- Use **English exclusively** in code, comments, and documentation.

---

## Function Comment-Based Help (SWE 4.4.5)

Every function must have comment-based help placed **inside** the function, at the top:

```powershell
function Get-UserById {
    <#
    .SYNOPSIS
        Retrieves a user record by its unique ID.

    .DESCRIPTION
        Queries the data source for a user matching the provided ID.
        Returns $null if no matching user is found.

    .PARAMETER UserId
        The unique integer identifier of the target user.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .EXAMPLE
        Get-UserById -UserId 42

    .NOTES
        Author:     Marvin Fenßel
        Created:    DD.MM.YYYY
        Changelog:  DD.MM.YYYY – Initial implementation.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        # Unique integer ID of the user to retrieve.
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$UserId
    )
    process {
        ...
    }
}
```

- `Author:` = output of `git config user.name` (example above is illustrative only – always read fresh from Git).

---

## CmdletBinding – Always Required

- Every function and script must start with `[CmdletBinding()]`.
- Always declare at least a `process {}` block when parameters accept pipeline input.
- Always specify `[OutputType(...)]` when the function returns objects.
- Provide `DefaultParameterSetName` in `[CmdletBinding()]` whenever multiple parameter sets are used.

```powershell
# ✅ GOOD – minimal scaffold
[CmdletBinding()]
param ()
process {
}
end {
}
```

---

## Naming Conventions (SWE 4.4.2 + PSSA)

| Element | Style | Example |
|---|---|---|
| Functions / Cmdlets | `Verb-PascalNoun` | `Get-UserReport`, `Export-InvoicePdf` |
| Parameters | `PascalCase` | `$UserId`, `$OutputPath` |
| Local variables | `camelCase` | `$userList`, `$retryCount` |
| Script/module-scope variables | `PascalCase` | `$Script:ConnectionString` |
| Global constants / env vars | `PascalCase` with scope | `$Global:MaxRetryCount` |
| Module names | `PascalCase` | `CubeOneReporting` |
| Script filenames | `Verb-Noun.ps1` or `PascalCase.ps1` | `Export-Report.ps1` |

### Verbs

- Use only **approved verbs** from `Get-Verb`.
- Common: `Get`, `Set`, `New`, `Remove`, `Export`, `Import`, `Invoke`, `Test`, `Send`, `Write`.

### General Rules

- Full, explicit names – no aliases (`gci` → `Get-ChildItem`, `%` → `ForEach-Object`).
- Full parameter names – no positional shortcuts (`Get-Process -Name Explorer` not `Get-Process Explorer`).
- No abbreviations unless widely accepted (`Id`, `Url`, `Db`).
- Two-letter acronyms fully capitalized: `$PSBoundParameters`, `Get-PSDrive`.
- Always use `$PSScriptRoot`-based paths – never relative paths `.\` or `~`.

```powershell
# ✅ GOOD
Get-Content -Path "$PSScriptRoot\config.json"

# ❌ BAD
Get-Content .\config.json
```

---

## Formatting (SWE 4.4.3 + PSSA)

### Indentation

- **4 spaces** per level – no tabs.

### Brace Style (One True Brace Style)

- Opening brace `{` on the **same line** as the statement.
- Closing brace `}` on its own line, aligned with the opener.

```powershell
# ✅ GOOD
if ($condition) {
    Do-Something
} else {
    Do-Other
}

# ❌ BAD
if ($condition)
{
    Do-Something
}
```

### Line Length

- Maximum **115 characters** per line.
- Use splatting for long parameter lists instead of backtick `` ` `` continuation:

```powershell
# ✅ GOOD – splatting
$params = @{
    Path        = "$PSScriptRoot\output.csv"
    Delimiter   = ';'
    Encoding    = 'UTF8'
    NoTypeInformation = $true
}
Export-Csv @params

# ❌ BAD – backtick continuation
Export-Csv -Path "$PSScriptRoot\output.csv" `
           -Delimiter ';' `
           -Encoding 'UTF8'
```

### Spaces

- Single space around all operators (`=`, `-eq`, `-gt`, `+`, etc.).
- Single space after commas and semicolons.
- Single space inside `{ }` scriptblock braces.
- No trailing whitespace.
- No semicolons as line terminators.

### Blank Lines

- Two blank lines between function definitions.
- One blank line between logical sections inside a function.
- One blank line at the end of each file.

### Hashtables

Each key-value pair on its own line; values aligned:

```powershell
# ✅ GOOD
$options = @{
    Margin   = 2
    Padding  = 2
    FontSize = 24
}
```

---

## Variables (SWE 4.4.6)

- Declare all variables at the beginning of their scope with initial values.
- No magic numbers – define named constants:

```powershell
# ✅ GOOD
[int]$script:MaxRetryCount = 5
[string]$script:DefaultEncoding = 'UTF8'
```

- No hardcoded connection strings or credentials – use `$env:` variables or secure vaults.
- Use `[int]`, `[string]`, `[bool]`, `[datetime]` type constraints on variable declarations and parameters.
- Prefer `$null` checks over empty-string tests.

---

## Structure (SWE 4.4.4 + PSSA)

### Parameter Validation over Body Validation

Validate inputs with parameter attributes, not `if` blocks in the function body:

```powershell
# ✅ GOOD
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$UserName,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 100)]
    [int]$PageSize,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Active', 'Inactive', 'Pending')]
    [string]$Status
)
```

### Function Blocks: Explicit Order

Always write blocks in execution order:

```powershell
function Verb-Noun {
    [CmdletBinding()]
    param ( ... )
    begin   { ... }  # one-time setup
    process { ... }  # pipeline item handling – emit output here
    end     { ... }  # one-time teardown
}
```

- Do **not** use `return` in advanced functions – place output objects directly in `process {}`.
- Never emit output in `begin {}` or `end {}`.

### Readability over Cleverness (SWE 4.4.7)

- Avoid complex one-liners. Split into readable steps.
- Use intermediate variables with meaningful names to clarify intent.
- Prefer builtin cmdlets over .NET method calls where readability is equivalent.

---

## Error Handling (SWE 4.4.8)

- Use `-ErrorAction Stop` on cmdlets inside `try/catch` to convert non-terminating errors to terminating ones.
- Never swallow errors silently – minimum: `Write-Warning` + log.
- Immediately copy `$_` to a named variable inside `catch` blocks before executing further commands.

```powershell
# ✅ GOOD
try {
    Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop
    Set-Content -Path $outputPath -Value $result -ErrorAction Stop
} catch {
    $err = $_
    Write-Error -Message "Export failed for URI '$apiUrl': $($err.Exception.Message)" `
                -Category ConnectionError
    throw
}
```

- Error messages must include (SWE 4.4.8): error source, criticality (`Write-Error`/`Write-Warning`), description, and context.
- Do **not** use `$?` to test for errors – use `try/catch` with `-ErrorAction Stop`.
- Do **not** set flags (`$continue = $false`) to handle errors – put the full transaction in the `try` block.
- Avoid `$ErrorActionPreference = 'SilentlyContinue'` in production code.

---

## Logging (SWE 4.4.10)

- Use the appropriate stream cmdlets – never `Write-Host` in reusable functions:

| Scenario | Cmdlet |
|---|---|
| Normal output (data) | `Write-Output` |
| Diagnostic / debug | `Write-Verbose`, `Write-Debug` |
| Non-critical warnings | `Write-Warning` |
| Errors | `Write-Error` |
| Progress indicator | `Write-Progress` |

- Log start, end, significant state changes, and all errors.
- Use structured logging libraries where applicable: `PSFramework`, `Serilog`, `Log4Shell`.

```powershell
# ✅ GOOD
Write-Verbose -Message "[$( Get-Date -Format 'yyyy-MM-ddTHH:mm:ss' )] Starting export for user $UserId"
```

---

## Security

- No hardcoded credentials, passwords, API keys, or connection strings.
- Use `Get-Secret` (SecretManagement module) or `$env:` variables for secrets.
- Avoid `Invoke-Expression` – it evaluates arbitrary strings and is a code injection risk.
- Avoid `ConvertTo-SecureString -AsPlainText -Force` with literals; use vaults instead.

---

## Testing (SWE 4.4.11)

- Use **Pester** as the test framework.
- One test file per module/script: `Get-UserById.Tests.ps1`.
- Test realistic business use cases with valid and invalid inputs.
- Include boundary tests (empty input, max values, null) and error-path tests.
- Run PSScriptAnalyzer as part of CI: `Invoke-ScriptAnalyzer -Path . -Recurse -ReportSummary`.

---

## Library Licenses (SWE 4.5)

Allowed: MIT, Apache 2.0, BSD, ISC, MPL 2.0, LGPL (dynamic linking).
Forbidden: GPL v2/v3, AGPL (without explicit GEF approval).
Every new module dependency requires a documented license review.

---

## Pre-commit checklist

- [ ] `.NOTES` Author / Changelog = current `git config user.name`
- [ ] `Invoke-ScriptAnalyzer` clean
- [ ] No secrets; Pester tests for critical logic
