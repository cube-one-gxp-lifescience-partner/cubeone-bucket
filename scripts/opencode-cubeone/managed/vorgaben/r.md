---
titel: R coding standards
pfade:
  - "**/*.qmd"
  - "**/*.Rmd"
  - "**/*.r"
  - "**/*.R"
---
# R Coding Standards – cube one GmbH

## Normative Basis

- **Tidyverse Style Guide** (https://style.tidyverse.org/)
- **cube one SWE Guideline V2, Chapter 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- **Tooling:** `styler`, `lintr`

---

## Author from Git (required)

- The `@author` field in roxygen2 docs and any file-level author metadata **must** use the locally effective Git user name.
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

## File Names

- Lowercase letters, numbers, and `-` or `_` as word delimiters – no spaces, no special characters.
- Use `.R` extension (uppercase R).
- Names must be human-readable and describe the file's content.
- For ordered files prefix with zero-padded numbers; for dated files use `YYYY-MM-DD`:

```
# Good
01-load-data.R
02-exploratory-analysis.R
fit_models.R
2025-01-01-report.Rmd

# Bad
temp.r
ExploratoryDataAnalysis.r
finalreport.R
```

---

## Internal File Structure

- Load all packages at the very top of the file, never inline.
- Use commented section dividers to separate logical blocks:

```r
# Load data -------------------------------------------------------------------

# Clean data ------------------------------------------------------------------

# Model -----------------------------------------------------------------------
```

---

## Naming Conventions (SWE 4.4.2 + Tidyverse)

| Element | Style | Example |
|---|---|---|
| Variables | `snake_case` | `day_one`, `user_count` |
| Functions | `snake_case`, verb-first | `add_row()`, `fit_model()` |
| Constants | `UPPER_SNAKE_CASE` | `MAX_ITERATIONS` |
| File names | `snake_case` or `kebab-case` | `fit_models.R` |
| S3 classes | `snake_case` | `data.frame`, `my_class` |

- Variable names should be **nouns**; function names should be **verbs**.
- Use concise but meaningful names – avoid overly long names like `first_day_of_the_month`.
- Do not use dots `.` in function or variable names (reserved for S3 method dispatch).
- Never shadow built-in names:

```r
# Bad
T <- FALSE
c <- 10
mean <- function(x) sum(x)
```

---

## Formatting (SWE 4.4.3 + Tidyverse)

### Indentation

- **2 spaces** per indentation level – no tabs.

### Line Length

- Maximum **80 characters** per line.
- Break long function calls: one argument per line, closing `)` on its own line:

```r
# Good
do_something_very_complicated(
  something = "that",
  requires = many,
  arguments = "some of which may be long"
)

# Bad
do_something_very_complicated("that", requires, many, arguments,
                              "some of which may be long")
```

### Spaces

- Space **after** commas, never before.
- Space **around** all infix operators (`<-`, `==`, `+`, `-`, `|>`, etc.).
- Space **before and after** `()` in `if`, `for`, `while` – not in regular function calls.
- No space inside `()` or `[]`.
- Exceptions (no spaces): `::`, `:::`, `$`, `@`, `[`, `[[`, `^`, unary `-`/`+`, `:`.

```r
# Good
x[, 1]
mean(x, na.rm = TRUE)
if (debug) { show(x) }
height <- (feet * 12) + inches
df$z
x <- 1:10

# Bad
x[,1]
mean (x, na.rm = TRUE)
height<-feet*12+inches
```

### Assignment

- Use `<-` for assignment, **never** `=`.

```r
# Good
x <- 5

# Bad
x = 5
```

### Braces

- `{` on the **same line** as the statement; `}` on its own line.
- `else` on the same line as the closing `}`.
- Control-flow modifiers (`return()`, `stop()`, `break`, `next`) always in their own `{}` block.

```r
# Good
if (y < 0) {
  stop("y is negative")
}

if (x > 0) {
  return(x)
}
x * -1

# Bad
if (y < 0) stop("y is negative")
if (x > 0) return(x)
```

### Logical Operators in Conditions

- Always use `&&` and `||` inside `if()` – never `&` or `|` (which are vectorised).
- Always use explicit comparisons, avoid implicit type coercion:

```r
# Good
if (length(x) > 0) { ... }

# Bad
if (length(x)) { ... }
```

### Strings

- Use `"double quotes"` for strings.
- Exception: when the string itself contains double quotes.

### Semicolons

- Never use `;` as a line terminator or to place multiple expressions on one line.

### Logical Literals

- Always use `TRUE` and `FALSE` – never `T` or `F`.

---

## Pipes (Tidyverse §4)

- Use base R pipe `|>` – not magrittr's `%>%`.
- Always a space before `|>`; always a new line after.
- Each step indented by 2 spaces.
- Avoid pipes when more than one primary object needs to be manipulated.
- Avoid pipes when meaningful intermediate results deserve informative names.

```r
# Good
iris |>
  summarise(across(where(is.numeric), mean), .by = Species) |>
  pivot_longer(!Species, names_to = "measure", values_to = "value") |>
  arrange(value)

# Bad
iris |> summarise(across(where(is.numeric), mean), .by = Species) |>
pivot_longer(!Species, names_to = "measure", values_to = "value")
```

---

## Functions (SWE 4.4.4 + Tidyverse §3)

### Structure

```r
#' Brief title in sentence case.
#'
#' @description
#' Longer description if needed.
#'
#' @param x A numeric vector to process.
#' @param na.rm Logical. Whether to remove NA values before computing.
#'
#' @return A single numeric value.
#'
#' @examples
#' calculate_mean(c(1, 2, 3))
#'
#' @author Marvin Fenßel
#' @note
#' Created: DD.MM.YYYY
#' Changelog: DD.MM.YYYY – Initial implementation.
calculate_mean <- function(x, na.rm = TRUE) {
  mean(x, na.rm = na.rm)
}
```

- `@author` = output of `git config user.name` (example above is illustrative only – always read fresh from Git).

### Return Values

- Only use `return()` for **early returns**. Otherwise let R implicitly return the last evaluated expression.
- `return()` must always be on its own line inside a `{}` block.
- Side-effect functions (print, plot, write) should return the first argument `invisible(x)`.

```r
# Good
find_abs <- function(x) {
  if (x > 0) {
    return(x)
  }
  x * -1
}

# Bad
add_two <- function(x, y) {
  return(x + y)
}
```

### Anonymous Functions

- Use `\(x) x + 1` for short single-expression anonymous functions.
- Use `function(x) { ... }` for multi-line anonymous functions.
- Avoid `\()` in a pipe or for named functions.

```r
# Good
map(xs, \(x) mean((x + 5)^2))

map(xs, function(x) {
  mean((x + 5)^2)
})

# Bad
map(xs, \(x) {
  mean((x + 5)^2)
})
```

### Multi-line Definitions

Use single-indent style (2 spaces) for long function signatures:

```r
# Good
long_function_name <- function(
  a = "a long argument",
  b = "another argument",
  c = "another long argument"
) {
  # body indented by two spaces
}
```

---

## Documentation (SWE 4.4.5 + Tidyverse §7)

- Use **roxygen2** with markdown enabled for all public functions.
- Documentation block placed **directly above** the function definition.
- Required tags: `@param` (for each parameter), `@return`, `@examples`.
- Recommended tags: `@description`, `@seealso`, `@family`, `@note` (changelog), `@author` (from `git config user.name`).
- Use sentence case with a trailing `.` on all tag descriptions.
- Document parameters in the `param` block, not inline in the function body.

```r
#' Combine values into a vector or list
#'
#' @param ... Objects to combine.
#' @return A vector or list.
#' @examples
#' c(1, 2, 3)
#' @author Marvin Fenßel
```

- Internal helpers get `#'` docs + `@noRd` to suppress `.Rd` generation.

---

## Variables (SWE 4.4.6)

- Declare all variables at the beginning of their scope with initial values.
- No magic numbers – use named constants:

```r
# Good
MAX_ITERATIONS <- 1000L
DEFAULT_THRESHOLD <- 0.05

# Bad
for (i in seq_len(1000)) { ... }
```

- No hardcoded configuration – use config files, environment variables, or `options()`.

---

## Error Handling (SWE 4.4.8)

- Use `tryCatch()` or `withCallingHandlers()` for structured error handling.
- Use `stop()` to signal errors, `warning()` for warnings, `message()` for informational output.
- Error messages must include (SWE 4.4.8): source, criticality, description.
- Set `call. = FALSE` in `stop()` / `warning()` to keep messages clean in packages:

```r
# Good
tryCatch(
  {
    result <- read_data(path)
    process(result)
  },
  error = function(e) {
    stop(
      sprintf("read_data() failed for path '%s': %s", path, conditionMessage(e)),
      call. = FALSE
    )
  }
)

# Bad – silent swallow
tryCatch(
  read_data(path),
  error = function(e) NULL
)
```

- Use `rlang::abort()`, `rlang::warn()`, `rlang::inform()` in package code for structured conditions with metadata.

---

## Logging (SWE 4.4.10)

- No bare `print()` or `cat()` in reusable functions – use `message()` for diagnostics.
- Log start, end, and significant state changes.
- In production scripts use `logger` or `futile.logger` for structured, level-based logging.

---

## Testing (SWE 4.4.11)

- Use **testthat** as the testing framework.
- One test file per source file: `test-fit_models.R`.
- Use realistic business-case data in tests.
- Include boundary tests (empty vectors, NA values, max lengths) and error-path tests.
- Run `lintr::lint_package()` and `styler::style_pkg()` as part of CI.

---

## Library Licenses (SWE 4.5)

Allowed: MIT, Apache 2.0, BSD, ISC, MPL 2.0, LGPL (dynamic linking).
Forbidden: GPL v2/v3, AGPL (without explicit GEF approval).
Every new package dependency requires a documented license review.

---

## Pre-commit checklist

- [ ] `@author` / changelog = current `git config user.name`
- [ ] `lintr::lint_package()` and `styler::style_pkg()` clean
- [ ] No secrets; tests for critical logic
