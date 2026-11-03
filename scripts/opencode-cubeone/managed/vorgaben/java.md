---
titel: Java Coding Standards
pfade:
  - "**/*.java"
---
# Java Coding Standards – cube one GmbH

## Normative Basis

- **Google Java Style Guide** (https://google.github.io/styleguide/javaguide.html)
- **cube one SWE Guideline V2, Chapter 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- **Tooling:** Checkstyle, PMD, SpotBugs, google-java-format

---

## Author from Git (required)

- The `author` field in file headers and Javadoc **must** use the locally effective Git user name.
- Resolve with: `git config user.name` (local → global).
- **Never** use a placeholder (`<Author Name>`), a hardcoded guess, or a guessed name.
- If `user.name` is missing, ask to set it via `git config user.name` – do not invent a name.

```bash
git config user.name
```

---

## Language (SWE 4.4.1)

- Use **English exclusively** in code, comments, and Javadoc.
- Source files are encoded in **UTF-8**.

---

## Source File Structure

Every `.java` file is structured in this exact order, each section separated by one blank line:

1. License / copyright comment (if required)
2. `package` declaration
3. `import` statements
4. Exactly **one** top-level class declaration

```java
// company: cube one GmbH
// name:    UserService.java
// author:  Marvin Fenßel
// created: DD.MM.YYYY
// change log: DD.MM.YYYY – Initial implementation.

package com.cubeone.services;

import java.util.List;
import java.util.Optional;

import org.springframework.stereotype.Service;

/**
 * Manages user lifecycle operations.
 */
@Service
public class UserService {
  ...
}
```

- `author:` = output of `git config user.name` (example above is illustrative only – always read fresh from Git).

### Imports

- **No wildcard imports** (`import java.util.*` is forbidden).
- **No module imports**.
- Imports are not line-wrapped.
- Order: static imports (single group) → blank line → non-static imports (single group), each group sorted in ASCII order.
- No static import for static nested classes.

### Class Member Ordering

Use a logical order (e.g. constants → fields → constructors → methods). Overloaded methods must appear in a single contiguous group with no other members between them.

---

## Javadoc (SWE 4.4.5 + Google §7)

All `public` and `protected` members require Javadoc. Exceptions: simple, self-explanatory getters/setters, and `@Override` methods.

```java
/**
 * Retrieves a user by their unique identifier.
 *
 * <p>Returns an empty Optional if no user with the given ID exists.
 *
 * @param userId the primary key of the target user
 * @return the user wrapped in an Optional, or empty if not found
 * @throws IllegalArgumentException if {@code userId} is negative
 * @author Marvin Fenßel
 * @since DD.MM.YYYY
 * @implNote Change log: DD.MM.YYYY – Initial implementation.
 */
public Optional<User> findById(long userId) {
  ...
}
```

- `@author` = `git config user.name` (example illustrative only).

### Javadoc Rules

- Block tags order: `@param` → `@return` → `@throws` → `@deprecated`.
- Never leave block tags with empty descriptions.
- The first sentence is a **summary fragment** (noun or verb phrase, capitalized, ends with `.`).
- Do **not** start with "This method returns…" – write "Returns the user." instead.
- Continuation lines of block tags indented **4 spaces** from the `@`.

---

## Naming Conventions (SWE 4.4.2 + Google §5)

| Element | Style | Example |
|---|---|---|
| Packages / Modules | `lowercase`, no underscores | `com.cubeone.services` |
| Classes, interfaces, enums, records | `UpperCamelCase` | `UserService`, `InvoiceProcessor` |
| Methods | `lowerCamelCase`, verb/verb phrase | `sendMessage()`, `findById()` |
| Constants (`static final` deeply immutable) | `UPPER_SNAKE_CASE` | `MAX_RETRY_COUNT` |
| Non-constant fields | `lowerCamelCase` | `computedValues`, `userId` |
| Parameters | `lowerCamelCase` | `userId`, `targetList` |
| Local variables | `lowerCamelCase` | `index`, `filteredUsers` |
| Type variables | Single capital letter or `ClassName + T` | `T`, `E`, `RequestT` |
| Test classes | `ClassNameTest` | `UserServiceTest` |
| Test methods | `lowerCamelCase` or `method_condition` | `findById_returnsEmpty` |

### General Rules

- **No special prefixes or suffixes** – `mName`, `s_name`, `name_`, `kName` are all forbidden.
- Meaningful, self-descriptive names – no single-character names except type variables (`T`, `E`) and loop counters (`i`, `j`).
- No abbreviations unless widely accepted (`id`, `url`, `db`, `dto`).
- Camel case for acronyms: `XmlHttpRequest`, not `XMLHTTPRequest`; `newCustomerId`, not `newCustomerID`.

---

## Formatting (SWE 4.4.3 + Google §4)

### Braces – K&R Style

- Opening `{` on the **same line** as the statement – never on a new line.
- Closing `}` on its own line.
- Braces are **always** used with `if`, `else`, `for`, `do`, `while` – even for a single-statement body.
- `else`, `catch`, `finally` on the same line as the preceding `}`.

```java
// ✅ GOOD
if (condition) {
  doSomething();
} else {
  doOther();
}

// ❌ BAD
if (condition)
  doSomething();
```

### Indentation

- **2 spaces** per level – no tabs.
- Continuation lines: at least **+4 spaces** from the original line.

### Column Limit

- Maximum **100 characters** per line.
- Exceptions: package/import declarations, long URLs in Javadoc, text block content.

### Line-Wrapping

- Break **before** non-assignment operators (`.`, `::`, `|`, `&`).
- Break **after** assignment operators (`=`, `+=`, etc.).
- Never break adjacent to the `->` in a lambda or switch rule.

```java
// ✅ GOOD
userRepository
    .findAll()
    .stream()
    .filter(User::isActive)
    .collect(toList());
```

### Whitespace

- Single space: before `{`, around binary/ternary operators, after `,` and `;`, around `->`.
- No space: inside `()` or `[]`, before `(` in method calls, around `::` or `.`.
- One blank line between consecutive class members (fields, methods, constructors).

### One Statement Per Line

- Never place multiple statements on one line.
- One variable declaration per declaration statement (`int a, b;` is forbidden; exception: `for` loop header).

### Modifiers Order

```java
public protected private abstract default static final sealed non-sealed
    transient volatile synchronized native strictfp
```

### Numeric Literals

- `long` literals use uppercase `L`: `3_000_000L`, not `3000000l`.
- Use `_` separators in long numeric literals for readability: `1_000_000`.

### Switch

- Prefer **new-style switch** with `->` (no fall-through, no `break` needed).
- Every switch must be **exhaustive** – always include a `default` case.
- Old-style fall-through must be marked with `// fall through`.

```java
// ✅ GOOD – new-style
return switch (status) {
  case ACTIVE   -> processActive(user);
  case INACTIVE -> processInactive(user);
  default       -> throw new IllegalStateException("Unknown status: " + status);
};
```

---

## Variables (SWE 4.4.6)

- Declare local variables **close to their first use**, not at the top of the block.
- Every declaration has an initializer, or is initialized immediately after.
- No magic numbers – define named constants:

```java
// ✅ GOOD
private static final int MAX_RETRY_COUNT = 5;
private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(30);

// ❌ BAD
if (retries > 5) { ... }
```

- No hardcoded configuration – use `@Value`, `@ConfigurationProperties`, or environment variables.

---

## Structure (SWE 4.4.4 + Google §6)

- `@Override` annotation **always** used when legally applicable.
- Static members accessed via class name, never via instance: `Foo.staticMethod()` not `instance.staticMethod()`.
- Do **not** override `Object.finalize()`.
- Follow **SOLID** principles; avoid God classes and God methods.
- Keep methods focused and reasonably sized (Single Responsibility).
- Prefer LINQ-style stream operations for collection manipulation when it improves readability.
- Use `async`/`CompletableFuture` for I/O-bound operations; avoid `.get()` / `.join()` on the main thread.

---

## Comments (SWE 4.4.5 + Google §4.8.6)

- Block comments indented at the same level as surrounding code.
- Multi-line `/* */` comments: subsequent lines start with `*` aligned with the opening `*`.
- Comments explain **why**, not what.
- `TODO` comments include a bug/ticket reference and description:

```java
// TODO: JIRA-1234 – Remove this workaround after upgrading to Spring 6.
```

- Never enclose comments in boxes of asterisks or other decorative characters.

---

## Error Handling (SWE 4.4.8)

- Caught exceptions are **never silently ignored**. Minimum: log the exception.
- If an empty `catch` is truly justified, add a comment explaining why.
- Error messages must include (SWE 4.4.8): source, criticality, description, context:

```java
// ✅ GOOD
try {
  userRepository.save(user);
} catch (DataAccessException ex) {
  logger.error(
      "Failed to save user [id={}]. Error: {}", user.getId(), ex.getMessage(), ex);
  throw new DataPersistenceException(
      String.format("Could not persist user %d.", user.getId()), ex);
}

// ❌ BAD
try {
  userRepository.save(user);
} catch (Exception ex) {
  // ignore
}
```

- Use specific exception types, not raw `Exception` or `Throwable`.
- Provide meaningful exception messages that support troubleshooting.

---

## Logging (SWE 4.4.10)

- Use `SLF4J` with Logback or `java.util.logging` – no `System.out.println` in production.
- Logger declared `private static final`:

```java
private static final Logger logger = LoggerFactory.getLogger(UserService.class);
```

- Use structured parameterized messages – never string concatenation in log calls:

```java
// ✅ GOOD
logger.debug("Fetching user [id={}]", userId);
logger.error("Export failed for campaign [id={}]: {}", campaignId, ex.getMessage(), ex);

// ❌ BAD
logger.error("Export failed for campaign " + campaignId + ": " + ex.getMessage());
```

- Log levels: `DEBUG` (internal details), `INFO` (start/stop, key events), `WARN` (recoverable anomalies), `ERROR` (failures with impact).

---

## Testing (SWE 4.4.11)

- Use **JUnit 5** as the test framework; **Mockito** or **AssertJ** for mocking and assertions.
- Test class name: `ClassNameTest` (unit) or `ClassNameIntegrationTest` (integration).
- Simulate real business use cases with realistic data.
- Include unit, integration, and boundary tests.
- Run Checkstyle, PMD, SpotBugs in CI on every build.

---

## Library Licenses (SWE 4.5)

Allowed: MIT, Apache 2.0, BSD, ISC, MPL 2.0, LGPL (dynamic linking).
Forbidden: GPL v2/v3, AGPL (without explicit GEF approval).
Every new dependency requires a documented license review.

---

## Pre-commit checklist

- [ ] File header / change log updated
- [ ] `author` / `@author` = current `git config user.name`
- [ ] Checkstyle, PMD, SpotBugs, google-java-format clean
- [ ] No secrets; tests for critical logic
