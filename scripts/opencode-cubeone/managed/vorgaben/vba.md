---
titel: VBA Coding Standards
pfade:
  - "**/*.frm"
  - "**/*.cls"
  - "**/*.bas"
---
# VBA Coding Standards – cube one GmbH

## Normative Basis

- **Microsoft MSDN VBA Guidelines** (https://learn.microsoft.com/en-us/office/vba/api/overview/excel)
- **Microsoft Visual Basic Coding Conventions** (https://learn.microsoft.com/en-us/dotnet/visual-basic/programming-guide/program-structure/coding-conventions)
- **cube one SWE Guideline V2, Chapter 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- **Tooling:** Rubberduck VBA

---

## Author from Git (required)

- The `author` field in procedure header comments **must** use the locally effective Git user name.
- Resolve with: `git config user.name` (local → global).
- **Never** use a placeholder (`<Author Name>`), a hardcoded guess, or a guessed name.
- If `user.name` is missing, ask to set it via `git config user.name` – do not invent a name.

```bash
git config user.name
```

---

## Language (SWE 4.4.1)

- Use **English exclusively** in code, comments, and documentation.
- No German strings in VBA files – UI text via resource constants or config sheets only.

---

## Procedure Header Comment (SWE 4.4.5)

Every Sub and Function (except simple getters/setters) must have a header comment:

```vba
' -----------------------------------------------------------------------------
' name:        GetUserById
' description: Retrieves a user record from the data sheet by its unique ID.
' param:       userId (Long) – Primary key of the target user.
' returns:     String – Full name of the user, or empty string if not found.
' author:      Marvin Fenßel
' created:     DD.MM.YYYY
' change log:  DD.MM.YYYY – Initial implementation.
' -----------------------------------------------------------------------------
Public Function GetUserById(ByVal userId As Long) As String
    ...
End Function
```

- `author:` = output of `git config user.name` (example above is illustrative only – always read fresh from Git).
- When modifying an existing procedure, add a line to the `change log:` section (include author from `user.name`).

---

## Option Explicit

- **Every module must start with `Option Explicit`** – no exceptions.
- This enforces explicit variable declaration and prevents silent typo bugs.

---

## Naming Conventions (SWE 4.4.2 + MSDN)

### General Rules

- Meaningful, self-descriptive names – no single-letter names outside of loop counters (`i`, `j`, `k`).
- No abbreviations unless widely accepted (`id`, `url`, `db`, `ws`, `wb`).
- No special characters, no spaces.
- Max ~50 characters per name for readability.

### Naming Table

| Element | Style | Example |
|---|---|---|
| Modules | `PascalCase` | `UserService`, `ReportBuilder` |
| Classes | `PascalCase` | `InvoiceProcessor` |
| Public Subs / Functions | `PascalCase` | `ExportToExcel`, `CalculateTax` |
| Private Subs / Functions | `PascalCase` | `ValidateInput` |
| Local variables | `camelCase` + type prefix | `strUserName`, `lngRowCount` |
| Module-level variables | `PascalCase` (no type prefix) | `UserName`, `RowCount` |
| Constants (all scopes) | `UPPER_SNAKE_CASE` | `MAX_RETRY_COUNT`, `DEFAULT_SHEET_NAME` |
| Parameters | `camelCase` (no type prefix) | `userId`, `targetRange` |

### Hungarian Notation – Type Prefixes for Local Variables

| Prefix | Data Type | Example |
|---|---|---|
| `str` | String | `strFileName` |
| `lng` | Long | `lngRowCount` |
| `int` | Integer | `intIndex` (prefer `Long`) |
| `dbl` | Double | `dblTaxRate` |
| `bln` | Boolean | `blnIsValid` |
| `dat` | Date | `datCreatedOn` |
| `obj` | Object (generic) | `objElement` |
| `ws` | Worksheet | `wsData` |
| `wb` | Workbook | `wbSource` |
| `rng` | Range | `rngSelection` |
| `col` | Collection | `colUsers` |
| `arr` | Array | `arrValues` |
| `dic` | Dictionary | `dicLookup` |

> **Exception:** Function/Sub parameters do **not** use type prefixes. Name them for readability and let IntelliSense show the type.

### Verb Conventions for Function Names

| Verb | Return Type |
|---|---|
| `Get` | Object / Workbook / Worksheet |
| `Create` | String |
| `Calculate` | Long / Double |
| `Pluck` | Range |
| `Collect` | Collection |
| `Build` / `Assemble` | Dictionary / complex object |
| `Is` / `Has` | Boolean |

---

## Formatting (SWE 4.4.3 + MSDN)

- **4 spaces** indentation – no tabs.
- One statement per line; one declaration per line.
- No use of `:` line separator to combine multiple statements on one line.
- At least one blank line between Sub/Function definitions.
- Use explicit line continuation `_` only where implicit continuation is not supported; prefer implicit where possible.
- Left-align continuation lines' list items:

```vba
' ✅ GOOD
Dim result As String
result = SomeFunction( _
    firstParam, _
    secondParam, _
    thirdParam)
```

- Comment on a **separate line**, not at the end of a code line.
- Start comment text with an uppercase letter.
- Insert one space after the comment delimiter `'`:

```vba
' ✅ GOOD
' Validate before writing to the sheet.
blnIsValid = ValidateInput(strValue)

' ❌ BAD
blnIsValid = ValidateInput(strValue) 'validate
```

---

## Structure (SWE 4.4.4 + MSDN)

- Declare all variables at the **beginning of their scope** with initial values.
- No magic numbers – define named constants in a dedicated constants module (`modConstants`):

```vba
' ✅ GOOD
Public Const MAX_ROWS As Long = 10000
Public Const DEFAULT_SHEET_NAME As String = "Data"

' ❌ BAD
If lngRow > 10000 Then ...
```

- No hardcoded configuration – use named constants, config sheets, or `IConfiguration`-equivalent named ranges.
- Keep Subs and Functions focused and reasonably sized (Single Responsibility).
- Avoid `GoTo` statements – use structured control flow (`If/ElseIf/Else`, `Select Case`, `Do/Loop`, `For/Next`).
- Use `With` blocks when making multiple calls to the same object:

```vba
' ✅ GOOD
With wsReport
    .Cells(1, 1).Value = "Report"
    .Cells(1, 1).Font.Bold = True
    .Cells(1, 1).Interior.Color = RGB(0, 112, 192)
End With

' ❌ BAD
wsReport.Cells(1, 1).Value = "Report"
wsReport.Cells(1, 1).Font.Bold = True
wsReport.Cells(1, 1).Interior.Color = RGB(0, 112, 192)
```

- Use short array initialization syntax:

```vba
' ✅ GOOD
Dim arrMonths As Variant
arrMonths = Array("Jan", "Feb", "Mar")

' ❌ BAD
Dim arrMonths(2) As String
arrMonths(0) = "Jan"
arrMonths(1) = "Feb"
arrMonths(2) = "Mar"
```

- Close `For...Next` loops with the iterative variable after `Next`:

```vba
For i = 1 To lngLastRow
    ...
Next i
```

- Use `Integer` only when interoperating with legacy APIs; **prefer `Long`** for all whole-number variables to avoid overflow.
- Use `StringBuilder` pattern (`Join` on array) for string concatenation in loops instead of `&` chaining.

---

## Variables (SWE 4.4.6)

- Declare all variables explicitly with `Dim` and a type – never rely on `Variant` unless genuinely needed.
- Initialize variables at declaration or at the top of the procedure.
- Use two-statement object creation (never `Dim X As New Y` in one line):

```vba
' ✅ GOOD
Dim dicLookup As Scripting.Dictionary
Set dicLookup = New Scripting.Dictionary

' ❌ BAD
Dim dicLookup As New Scripting.Dictionary
```

- Use `IsNot Nothing` / `Is Nothing` pattern; avoid `Not X Is Nothing`:

```vba
' ✅ GOOD
If Not rngTarget Is Nothing Then ...

' ❌ BAD (confusing double negation)
If Not rngTarget Is Nothing = True Then ...
```

---

## Error Handling (SWE 4.4.8)

- **Never use `On Error Resume Next`** in production code without an immediate error check and reset.
- Use structured error handling with `On Error GoTo` label pattern:

```vba
' ✅ GOOD
Public Sub ExportReport()
    On Error GoTo ErrorHandler

    ' ... procedure logic ...

    Exit Sub

ErrorHandler:
    MsgBox "ExportReport failed." & vbCrLf & _
           "Error " & Err.Number & ": " & Err.Description, _
           vbCritical, "cube one GmbH"
    ' Log error, clean up resources if needed
End Sub
```

- Error messages must include (SWE 4.4.8):
  - Error source (procedure name)
  - Error code (`Err.Number`)
  - Description (`Err.Description`)
  - Criticality (via `MsgBox` icon or log level)
- Always clean up objects (`Set obj = Nothing`) in error paths.
- Do **not** use `On Error GoTo 0` to silently suppress errors – only use it to deliberately disable a handler after a guarded block.

---

## Logging (SWE 4.4.10)

- No `Debug.Print` in production code – use a dedicated logging Sub that writes to a log sheet or file.
- Log start, end, significant state changes, and all errors.
- Recommended log entry pattern:

```vba
Private Sub LogEvent(ByVal source As String, ByVal message As String)
    Dim wsLog As Worksheet
    Set wsLog = ThisWorkbook.Sheets("Log")

    Dim lngNext As Long
    lngNext = wsLog.Cells(wsLog.Rows.Count, 1).End(xlUp).Row + 1

    wsLog.Cells(lngNext, 1).Value = Now
    wsLog.Cells(lngNext, 2).Value = source
    wsLog.Cells(lngNext, 3).Value = message
End Sub
```

---

## Module Organization

- All global constants in a dedicated module named `modConstants`.
- All public, reusable utility functions in a module named `modUtils` or `modHelpers`.
- Separate modules by domain: `modReportExport`, `modDataImport`, `modValidation`.
- Class modules use `PascalCase` names matching their responsibility: `InvoiceProcessor`, `UserRepository`.
- Event handler names follow the `Object_Event` pattern generated by the IDE: `btnExport_Click`, `Worksheet_Change`.

---

## Security

- No hardcoded credentials, passwords, or connection strings in VBA code – use named ranges, environment variables, or encrypted config sheets.
- Avoid `Shell` and `CreateObject("WScript.Shell")` unless strictly necessary; document the reason with a comment.

---

## Testing (SWE 4.4.11)

- Use **Rubberduck VBA** unit test framework for automated tests.
- Simulate real business use cases with realistic data.
- Test boundary values (empty ranges, max row counts, invalid inputs).
- Include tests for error paths (missing sheets, locked files, invalid formats).

---

## Library Licenses (SWE 4.5)

Allowed: MIT, Apache 2.0, BSD, ISC, MPL 2.0, LGPL (dynamic linking).
Forbidden: GPL v2/v3, AGPL (without explicit GEF approval).
Every new third-party reference/library requires a documented license review.

---

## Pre-commit checklist

- [ ] Procedure header `author` / change log = current `git config user.name`
- [ ] `Option Explicit` present in every module
- [ ] No secrets; Rubberduck tests for critical logic
