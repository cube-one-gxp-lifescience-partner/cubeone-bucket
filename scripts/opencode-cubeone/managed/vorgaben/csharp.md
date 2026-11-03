---
titel: C# Coding Standards
pfade:
  - "**/*.cs"
---
# C# Coding Standards – cube one GmbH

## Normative Basis

- **Microsoft C# Coding Conventions** (https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)
- **cube one SWE Guideline V2, Chapter 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- **Tooling:** StyleCop, FxCop, or ReSharper; enforce via `.editorconfig` in CI

---

## Author from Git (required)

- The `Author:` field in XML `<remarks>` (and any file-level author metadata) **must** use the locally effective Git user name.
- Resolve with: `git config user.name` (local → global).
- **Never** use a placeholder (`<Author Name>`), a hardcoded guess, or a guessed name.
- If `user.name` is missing, ask to set it via `git config user.name` – do not invent a name.

```bash
git config user.name
```

---

## Language (SWE 4.4.1)

- Use **English exclusively** in code, comments, and XML docs.
- No German strings in C# files – UI text via resource files only.

---

## Method XML Documentation (SWE 4.4.5)

All **public** members require XML docs. Exceptions: simple getters/setters, auto-properties.

```csharp
/// <summary>
/// Retrieves an entity by its identifier.
/// </summary>
/// <param name="id">Primary key of the entity.</param>
/// <returns>The entity, or <c>null</c> if not found.</returns>
/// <exception cref="ArgumentOutOfRangeException">Thrown when <paramref name="id"/> is negative.</exception>
/// <remarks>
/// Author: Marvin Fenßel<br/>
/// Created: DD.MM.YYYY<br/>
/// Change log: DD.MM.YYYY – Initial implementation.
/// </remarks>
public async Task<Entity?> GetByIdAsync(int id) { … }
```

- `Author:` = output of `git config user.name` (example above is illustrative only – always read fresh from Git).
- When modifying an existing method, add a line to the `Change log:` section in its XML doc (include author from `user.name`).

---

## Naming Conventions (PascalCase / camelCase)

| Element | Style | Example |
|---|---|---|
| Classes, records, structs | `PascalCase` | `UserService` |
| Public methods, properties | `PascalCase` | `GetUserById` |
| Local variables, parameters | `camelCase` | `userId`, `pageSize` |
| Private fields | `_camelCase` | `_repository` |
| Constants | `PascalCase` | `MaxRetryCount` |
| Interfaces | `IPascalCase` | `IUserRepository` |
| Async methods | `…Async` suffix | `FetchDataAsync` |

- Use **meaningful, self-descriptive names** – no abbreviations (except: `id`, `url`, `db`, `ctx`).
- No special characters, no Hungarian notation.

---

## Formatting (SWE 4.4.3 + Microsoft)

- **4 spaces** indentation – no tabs.
- **Allman braces**: opening `{` on its own line, aligned with enclosing block.
- One statement per line; one declaration per line.
- At least one blank line between method and property definitions.
- Use `using` directives **outside** the namespace declaration.
- Prefer **file-scoped namespace** declarations:

```csharp
// ✅ GOOD
namespace CubeOne.Services;

// ❌ BAD
namespace CubeOne.Services
{
    …
}
```

---

## Language Features (Microsoft)

```csharp
// ✅ Language keywords over runtime types
string name = "cube one";        // not System.String
int count = 0;                   // not System.Int32

// ✅ var only when type is obvious from right-hand side
var service = new UserService();
int result = Convert.ToInt32(input);   // type not obvious → explicit

// ✅ String interpolation
string display = $"{user.LastName}, {user.FirstName}";

// ✅ Raw string literals (C# 11+)
var query = """
    SELECT id, name
    FROM users
    WHERE active = 1
    """;

// ✅ Collection expressions (C# 12+)
string[] roles = ["Admin", "User", "Guest"];

// ✅ Object initializer
var dto = new UserDto { Id = 1, Name = "Test" };

// ✅ Concise new
UserService svc = new();

// ✅ using declaration (no extra braces)
using var stream = new FileStream(path, FileMode.Open);

// ✅ && / || (not & / |)
if ((divisor != 0) && (dividend / divisor > threshold)) { … }

// ✅ Func<> / Action<> instead of custom delegates
Func<int, bool> isValid = id => id > 0;
```

---

## Structure (SWE 4.4.4)

- **No magic numbers** – define named constants.
- **No hardcoded config** – use `IConfiguration` / `IOptions<T>` / environment variables.
- Declare variables at the **beginning of their scope** with initial values.
- Keep methods focused and reasonably sized (Single Responsibility – SOLID SRP).
- Prefer LINQ for collection manipulation over manual loops when it improves readability.
- Use `async`/`await` for I/O-bound operations; avoid `.Result` or `.Wait()` to prevent deadlocks.

---

## Error Handling (SWE 4.4.8)

```csharp
// ❌ BAD – generic catch, no logging
try { DoSomething(); }
catch (Exception) { }

// ✅ GOOD – specific type, logged, rethrown or wrapped
try
{
    await repository.SaveAsync(entity);
}
catch (DbUpdateException ex)
{
    logger.LogError(ex,
        "Database update failed for entity {EntityId}. Error: {Message}",
        entity.Id, ex.Message);
    throw new DataPersistenceException(
        $"Failed to save entity {entity.Id}.", ex);
}
```

Error messages must include (SWE 4.4.8): **error code / criticality / description / possible solution / stack trace** (via `ex` in logs, not in API responses).

---

## Logging (SWE 4.4.10)

Use `Microsoft.Extensions.Logging` (standard) or Serilog / NLog / log4net (third-party).

```csharp
// ✅ GOOD
private readonly ILogger<UserService> _logger;

public async Task<User?> GetByIdAsync(int id)
{
    _logger.LogDebug("Fetching user {UserId}", id);
    var user = await _repository.FindAsync(id);
    if (user is null)
        _logger.LogWarning("User {UserId} not found.", id);
    return user;
}
```

- No `Console.WriteLine` in production code.
- Log **start**, **end**, **errors**, and **significant state changes**.
- Use structured parameters, not string concatenation: `LogError("Failed for {Id}", id)`.

---

## LINQ Queries

```csharp
// ✅ Meaningful query variable names; where before orderby
var activeUsers = from user in Users
                  where user.IsActive
                  orderby user.LastName
                  select user;

// ✅ Unambiguous anonymous type properties
var report = from u in Users
             join r in Roles on u.RoleId equals r.Id
             select new { UserName = u.Name, RoleName = r.Name };
```

---

## Code Quality (SWE 4.4.9)

- **Zero compiler warnings** in CI – treat warnings as errors (`<TreatWarningsAsErrors>true</TreatWarningsAsErrors>`).
- Enable Nullable Reference Types: `<Nullable>enable</Nullable>`.
- Run **StyleCop** or **ReSharper** on every CI build.
- Max cyclomatic complexity: **10** per method.
- Follow SOLID principles; avoid God-classes and God-methods.

---

## Library Licenses (SWE 4.5)

**Allowed:** MIT, Apache 2.0, BSD 3-Clause, ISC, MPL 2.0, LGPL (dynamic linking only).  
**Forbidden:** GPL v2/v3, AGPL (without explicit GEF approval).  
Every new dependency requires a documented license review.

---

## Testing (SWE 4.4.11)

- Use xUnit or NUnit as test framework.
- Simulate real business use cases with realistic data.
- Use `Moq` or `NSubstitute` for dependency mocking.
- Automate tests in CI; include unit, integration, and boundary tests.
- No empty test methods added just for compliance – tests must assert meaningful behavior.

---

## Pre-commit checklist

- [ ] XML `Author` / Change log = current `git config user.name`
- [ ] StyleCop / ReSharper / treat-warnings-as-errors clean
- [ ] No secrets; meaningful tests for critical logic
