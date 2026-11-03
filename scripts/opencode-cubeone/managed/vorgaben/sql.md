---
titel: SQL Coding Guidelines
pfade:
  - "**/*.sql"
---
# SQL Coding Standards – cube one GmbH

## Normative Basis

- **SQL Style Guide by Simon Holywell** (https://www.sqlstyle.guide/)
- **cube one SWE Guideline V2, Chapter 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- **Tooling:** SQLFluff, pgFormatter

---

## Author from Git (required)

- The `author` field in SQL file headers **must** use the locally effective Git user name.
- Resolve with: `git config user.name` (local → global).
- **Never** use a placeholder (`<Author Name>`), a hardcoded guess, or a guessed name.
- If `user.name` is missing, ask to set it via `git config user.name` – do not invent a name.

```bash
git config user.name
```

---

## Language (SWE 4.4.1)

- Use **English exclusively** in SQL code, comments, and documentation.
- No German strings in SQL files – UI text via resource files only.

---

## File Header (SWE 4.4.5)

Every non-trivial `.sql` file begins with a header comment:

```sql
/*
 * company: cube one GmbH
 * name: usp_get_user_by_id.sql
 * author: Marvin Fenßel
 * created: DD.MM.YYYY
 * change log: DD.MM.YYYY – Initial implementation.
 */
```

- `author:` = output of `git config user.name` (example above is illustrative only – always read fresh from Git).
- Every relevant change is added to `change log` (date, author from `user.name`, description).
- Git history does **not** replace the change-log entry in the header.

---

## Naming Conventions (SWE 4.4.2 + sqlstyle.guide)

| Element | Style | Example |
|---|---|---|
| Tables | `snake_case`, collective/singular | `staff`, `order_item` |
| Columns | `snake_case`, singular | `first_name`, `release_date` |
| Stored procedures | `snake_case`, contains a verb | `usp_get_user_by_id` |
| Views | `snake_case`, descriptive | `vw_active_users` |
| Indexes | `snake_case`, descriptive | `idx_staff_last_name` |
| Constraints | `snake_case`, descriptive | `chk_age_range`, `fk_order_user` |

- **Max 30 characters** per identifier name.
- Names must begin with a letter and may not end with an underscore.
- Only use letters, numbers, and underscores.
- Avoid multiple consecutive underscores.
- No `tbl_`, `sp_`, `vw_` Hungarian-notation prefixes (exception: `usp_`, `vw_` for stored procs/views per internal convention).
- No camelCase identifiers – they are difficult to scan quickly.
- No quoted identifiers unless absolutely necessary; use SQL-92 double quotes if required.

### Uniform Column Suffixes

| Suffix | Usage |
|---|---|
| `_id` | Unique identifier / primary key |
| `_status` | Flag or status value |
| `_total` | Sum or aggregate value |
| `_num` | Any numeric field |
| `_name` | Name field (e.g. `first_name`) |
| `_date` | Date or datetime field |
| `_seq` | Contiguous sequence |
| `_tally` | Count value |
| `_size` | Size measurement |
| `_addr` | Address (physical or IP) |

---

## Formatting (SWE 4.4.3 + sqlstyle.guide)

### Reserved Keywords

- Always use **UPPERCASE** for SQL reserved keywords: `SELECT`, `FROM`, `WHERE`, `JOIN`, `ON`, `GROUP BY`, `ORDER BY`, `HAVING`, `INSERT`, `UPDATE`, `DELETE`, `CREATE`, `ALTER`, `DROP`, `NULL`, `NOT NULL`, etc.
- Use the full-length keyword form where available (`ABSOLUTE` not `ABS`).
- Prefer ANSI SQL keywords over vendor-specific alternatives for portability.

### Right-Alignment River

Align root keywords to end on the same character boundary, creating a visual "river" down the middle:

```sql
-- ✅ GOOD
SELECT first_name,
       last_name,
       email
  FROM staff AS s
 WHERE s.is_active = 1
   AND s.department_id = 5
 ORDER BY s.last_name;

-- ❌ BAD
SELECT first_name, last_name, email FROM staff WHERE is_active = 1
```

### Spaces

Always include spaces:
- before and after `=`
- after commas `,`
- surrounding apostrophes `'` where not within parentheses

### Line Breaks

Always place on a new line:
- `AND` / `OR` conditions
- Each `SELECT` column group
- Each `JOIN` clause
- After each major keyword (`FROM`, `WHERE`, `GROUP BY`, `ORDER BY`, `HAVING`)
- After semicolons to separate queries

### Indentation

- Use **4 spaces** for indentation within `CREATE`, `BEGIN`/`END` blocks, and subqueries – no tabs.
- `JOIN` conditions (`ON`) indented 4 spaces beneath the `JOIN`:

```sql
SELECT r.last_name,
       b.model
  FROM riders AS r
  JOIN bikes AS b
    ON r.bike_id = b.bike_id
   AND b.engine_size > 2;
```

- Subqueries indented to the right of the river:

```sql
SELECT r.last_name,
       (SELECT MAX(championship_date)
          FROM champions AS c
         WHERE c.last_name = r.last_name
           AND c.confirmed = 'Y') AS last_championship_year
  FROM riders AS r
 WHERE r.last_name IN
       (SELECT c.last_name
          FROM champions AS c
         WHERE c.confirmed = 'Y');
```

---

## Query Structure (SWE 4.4.4 + sqlstyle.guide)

- Use `BETWEEN` instead of combining multiple `AND` conditions for ranges.
- Use `IN()` instead of multiple `OR` clauses.
- Use `CASE` expressions for conditional logic within queries; nest only where necessary.
- Avoid `UNION` and temporary tables where the schema can be optimized instead.
- Store ISO 8601 compliant datetime values: `YYYY-MM-DDTHH:MM:SS.SSSSS`.
- Prefer `NUMERIC` / `DECIMAL` over `REAL` / `FLOAT` unless floating-point math is strictly required.

```sql
-- ✅ GOOD
SELECT CASE postcode
       WHEN 'MUC' THEN 'Munich'
       WHEN 'BER' THEN 'Berlin'
       END AS city
  FROM office_locations
 WHERE country = 'Germany'
   AND opening_hour BETWEEN 8 AND 9
   AND postcode IN ('MUC', 'BER', 'HAM');
```

---

## Aliasing

- Always use the `AS` keyword explicitly when aliasing:

```sql
-- ✅ GOOD
SELECT s.first_name AS fn
  FROM staff AS s;
```

- Alias should reflect the first letter(s) of each word in the object name.
- Append a number if an alias collision occurs (`s1`, `s2`).
- Aggregated computed columns must be aliased with a meaningful name:

```sql
SELECT SUM(s.salary) AS total_salary
  FROM staff AS s;
```

---

## Comments (SWE 4.4.5)

- Use `/* ... */` for block/multi-line comments.
- Use `--` with a trailing space for single-line inline comments.
- Comment intent and the *why*, not the *what*.
- Complex logic, non-obvious joins, or business rule implementations must be explained:

```sql
/* Exclude soft-deleted records and historical snapshots;
   only current active rows are relevant for reporting. */
SELECT user_id,
       email
  FROM users
 WHERE deleted_at IS NULL  -- soft delete flag
   AND is_current = 1;
```

---

## Variables & Parameters (SWE 4.4.6)

- Declare all variables with appropriate initial values at the start of the processing block.
- No magic numbers or hardcoded configuration values – use named variables or parameterized queries.
- Use parameterized queries / prepared statements to prevent SQL injection:

```sql
-- ✅ GOOD (parameterized)
SELECT *
  FROM orders
 WHERE customer_id = @customer_id
   AND status = @status;
```

---

## Error Handling (SWE 4.4.8)

- All stored procedures must include structured error handling.
- Error messages must contain: error source, criticality, description, and context.

```sql
-- ✅ GOOD (T-SQL example)
BEGIN TRY
    UPDATE orders
       SET status = 'SHIPPED'
     WHERE order_id = @order_id;
END TRY
BEGIN CATCH
    DECLARE @error_msg NVARCHAR(500) = ERROR_MESSAGE();
    DECLARE @error_num INT           = ERROR_NUMBER();

    RAISERROR('Order update failed [Error %d]: %s', 16, 1, @error_num, @error_msg);
END CATCH;
```

---

## CREATE Syntax

- Indent column definitions by **4 spaces** inside `CREATE TABLE`.
- Declare `PRIMARY KEY` first, directly after the `CREATE TABLE` statement.
- Constraints placed directly beneath the column they apply to, indented to align right of the column name.
- Use alphabetical order for `ON DELETE` before `ON UPDATE`.
- Align `NOT NULL`, data types, and constraint definitions vertically where practical:

```sql
CREATE TABLE staff (
    PRIMARY KEY (staff_id),
    staff_id    INT          NOT NULL,
    first_name  VARCHAR(100) NOT NULL,
    last_name   VARCHAR(100) NOT NULL,
    email       VARCHAR(255) NOT NULL,
                CONSTRAINT uq_staff_email UNIQUE (email),
    hire_date   DATE         NOT NULL,
    salary      DECIMAL(10, 2) NOT NULL,
                CONSTRAINT chk_salary_positive CHECK (salary > 0)
);
```

### Designs to Avoid

- No object-oriented design patterns applied to relational schema.
- No Entity-Attribute-Value (EAV) tables.
- No splitting data that belongs in one table across multiple tables for arbitrary reasons (archiving, geography).
- Never store value and unit in separate columns – embed unit in the column name or use `CHECK()`.

---

## Testing (SWE 4.4.11)

- Test all stored procedures and functions with realistic business-case data.
- Include boundary and null value tests.
- Attach executed SQL statements and results to the Development Test Report.

---

## Library / Tool Licenses (SWE 4.5)

Allowed tools/extensions: MIT, Apache 2.0, BSD, ISC, MPL 2.0, LGPL (dynamic linking).
Forbidden: GPL v2/v3, AGPL (without explicit GEF approval).

---

## Pre-commit checklist

- [ ] File header `author` / change log = current `git config user.name`
- [ ] SQLFluff / pgFormatter clean
- [ ] Parameterized queries; no secrets
