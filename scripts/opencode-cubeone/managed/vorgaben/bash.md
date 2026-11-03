---
titel: Bash Coding Standards
pfade:
  - "**/*.sh"
---
# Bash Coding Standards – cube one GmbH

## Normative Basis

- **Google Shell Style Guide** (https://google.github.io/styleguide/shellguide.html)
- **cube one SWE Guideline V2, Chapter 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- **Tooling:** ShellCheck

---

## Author from Git (required)

- The `Author:` field in function header comments **must** use the locally effective Git user name.
- Resolve with: `git config user.name` (local → global).
- **Never** use a placeholder (`<Author Name>`), a hardcoded guess, or a guessed name.
- If `user.name` is missing, ask to set it via `git config user.name` – do not invent a name.
- For `# TODO(name):` use the same Git user name (or a short stable handle derived from it).

```bash
git config user.name
```

---

## Which Shell to Use

- Bash is the **only** permitted shell scripting language for executables.
- Every executable script must start with `#!/bin/bash` and minimal flags.
- Use `set` to set shell options so that calling the script as `bash script_name` does not break functionality.
- Scripts longer than **100 lines** or with non-straightforward control flow should be rewritten in a more structured language (Python, etc.).

## File Extensions

- Executables: `.sh` extension or no extension.
- Libraries (sourced, not executed): must have `.sh` extension and must **not** be executable.
- SUID/SGID is **forbidden** on shell scripts – use `sudo` for elevated access.

---

## Language (SWE 4.4.1)

- Use **English exclusively** in code, comments, and documentation.

---

## Function Comments (SWE 4.4.5)

Every non-trivial function and every library function must have a header comment:

```bash
#######################################
# Brief description of what the function does.
# Globals:
#   GLOBAL_VAR_NAME
# Arguments:
#   $1 – Description of first argument.
#   $2 – Description of second argument.
# Outputs:
#   Writes result to STDOUT.
# Returns:
#   0 on success, non-zero on error.
# Author:
#   Marvin Fenßel
# Created:
#   DD.MM.YYYY
# Change log:
#   DD.MM.YYYY – Initial implementation.
#######################################
function my_function() {
  ...
}
```

- `Author:` = output of `git config user.name` (example above is illustrative only – always read fresh from Git).
- Use `# TODO(name): description` for temporary or incomplete code (`name` from `git config user.name`).
- Comment *why* code does something, not *what* it does.

---

## Naming Conventions (SWE 4.4.2)

| Element | Style | Example |
|---|---|---|
| Functions | `snake_case` | `get_config_dir` |
| Local variables | `snake_case` | `file_path`, `retry_count` |
| Constants / env variables | `UPPER_SNAKE_CASE` | `MAX_RETRY_COUNT`, `BACKUP_DIR` |
| Source filenames | `snake_case` | `backup_oracle.sh` |
| Library packages | `namespace::function` | `mypackage::my_func` |

- Meaningful, self-descriptive names – no single-letter variables outside of loop counters.
- No abbreviations unless widely accepted (`db`, `id`, `url`, `dir`, `tmp`).
- Loop variables must match the plural they iterate: `for zone in "${zones[@]}"`.

---

## Formatting (SWE 4.4.3)

### Indentation

- **2 spaces** – no tabs (exception: `<<-` heredoc body).
- Use blank lines between logical blocks to improve readability.

### Line Length

- Maximum **80 characters** per line.
- Split long strings using heredoc or embedded newlines:

```bash
# ✅ GOOD
cat <<END
I am an exceptionally long
string.
END

long_string="I am an exceptionally
long string."
```

### Pipelines

- If a pipeline fits on one line, keep it on one line.
- Otherwise split at each `|` with 2-space indent and `\` for continuation:

```bash
# ✅ GOOD
command1 | command2

command1 \
  | command2 \
  | command3 \
  | command4
```

### Control Flow

- `;then` and `;do` on the same line as `if`/`for`/`while`.
- `else` on its own line; `fi` and `done` vertically aligned with opener.

```bash
# ✅ GOOD
for dir in "${dirs[@]}"; do
  if [[ -d "${dir}" ]]; then
    rm -rf "${dir}"
  else
    mkdir -p "${dir}"
  fi
done
```

### Case Statements

- Alternatives indented 2 spaces; `;;` on its own line for multi-line actions.

```bash
case "${flag}" in
  a) action_a ;;
  b) action_b ;;
  *)
    log_error "Unexpected flag: ${flag}"
    exit 1
    ;;
esac
```

---

## Variables (SWE 4.4.6)

- Declare all variables at the beginning of their scope with initial values.
- Always use `local` for function-scoped variables to avoid polluting global namespace.
- **Separate** `local` declaration from command-substitution assignment to preserve exit codes:

```bash
# ✅ GOOD
local my_var
my_var="$(my_func)"
(( $? == 0 )) || return

# ❌ BAD – $? always 0 because 'local' swallows the exit code
local my_var="$(my_func)"
```

- Declare constants with `readonly` at the top of the file, before functions.
- Use `declare -xr` or `readonly` + `export` for constants exported to the environment.
- No magic numbers, no hardcoded configuration – use named constants or config files.

### Variable Expansion

- Always use `"${var}"` (braced + double-quoted) for all variables.
- Exception: single-character shell specials (`$?`, `$#`, `$$`, `$!`) and arithmetic inside `(( ))`.

```bash
# ✅ GOOD
echo "PATH=${PATH}, file=${file_path}"

# ❌ BAD
echo "PATH=$PATH, file=$file_path"
```

### Quoting

- Always double-quote strings that contain variables, command substitutions, spaces, or shell meta characters.
- Use single quotes `'...'` when no substitution is desired.
- Use `"$@"` (not `$*`) when passing positional arguments:

```bash
# ✅ GOOD
mybinary "${flags[@]}"
process_args "$@"
```

---

## Structure (SWE 4.4.4)

- File layout order:
  1. Shebang + file header comment
  2. `set` options (`set -euo pipefail`)
  3. `source` / `include` statements
  4. Constants (`readonly`)
  5. Function definitions
  6. `main` function (if applicable)
  7. `main "$@"` call at the bottom

- For scripts with at least one function, wrap the entry point in `main()` and call it last:

```bash
main() {
  local input="$1"
  process "${input}"
}

main "$@"
```

- Avoid overly complex single-line statements. Spread complex logic over multiple lines.
- Prefer shell builtins over external processes for efficiency and portability.

---

## Features – Do and Don't

### Command Substitution

```bash
# ✅ GOOD
var="$(command "$(command1)")"

# ❌ BAD – backticks are harder to nest and read
var="`command \`command1\``"
```

### Tests and Conditionals

- Always use `[[ … ]]` instead of `[ … ]`, `test`, or `/usr/bin/[`.
- Use `==` for string equality, `-z`/`-n` for empty/non-empty checks.
- Use `(( … ))` for numeric comparisons – never `<`/`>` inside `[[ ]]` for numbers.

```bash
# ✅ GOOD
if [[ "${my_var}" == "expected" ]]; then ...
if [[ -z "${my_var}" ]]; then ...
if (( count > 3 )); then ...

# ❌ BAD
if [ "${my_var}" == "expected" ]; then ...
if [[ "${my_var}" > 3 ]]; then ...  # lexicographic, not numeric!
```

### Arithmetic

- Always use `(( … ))` or `$(( … ))` – never `let`, `$[ ]`, or `expr`.

```bash
# ✅ GOOD
(( i += 1 ))
result="$(( hr * 3600 + min * 60 + sec ))"

# ❌ BAD
let i="i + 1"
result=$(expr $hr \* 3600)
```

### Arrays

- Use arrays for lists of elements and command argument sequences.
- Access with quoted expansion `"${array[@]}"`.
- Prefer `readarray` or process substitution over piped `while` to avoid subshell variable scoping bugs:

```bash
# ✅ GOOD
readarray -t lines < <(your_command)
for line in "${lines[@]}"; do ...

# ❌ BAD – last_line stays 'NULL' because pipe creates a subshell
your_command | while read -r line; do
  last_line="${line}"
done
```

### Wildcard Expansion

- Always use `./*` instead of `*` for wildcard file expansion to avoid treating filenames starting with `-` as flags.

```bash
# ✅ GOOD
rm -v ./*

# ❌ BAD
rm -v *
```

### Aliases

- Do **not** use aliases in scripts – use functions instead.

### eval

- Avoid `eval`. It is a security risk and makes code impossible to audit reliably.

---

## Error Handling (SWE 4.4.8)

- Enable strict mode at the top of every script:

```bash
set -euo pipefail
```

- All error output goes to **STDERR**. Use a dedicated error function:

```bash
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}
```

- Always check return values and provide informative error messages:

```bash
# ✅ GOOD
if ! mv "${file_list[@]}" "${dest_dir}/"; then
  err "Unable to move ${file_list[*]} to ${dest_dir}"
  exit 1
fi
```

- For pipelines, save `PIPESTATUS` immediately before the next command overwrites it:

```bash
tar -cf - ./* | ( cd "${dir}" && tar -xf - )
return_codes=( "${PIPESTATUS[@]}" )
if (( return_codes[0] != 0 )); then
  err "tar archive creation failed"
  exit 1
fi
```

- Error messages must include (SWE 4.4.8): source, criticality, description, and if possible a suggested resolution.
- Never swallow errors silently – minimum: log to STDERR and exit with a non-zero code.

---

## Logging (SWE 4.4.10)

- No production output to STDOUT that isn't part of the script's intended output.
- Status/progress messages go to STDERR.
- Log start time, end time, errors, and success/failure codes where useful for troubleshooting.

---

## Testing (SWE 4.4.11)

- Run **ShellCheck** on every script before committing: `shellcheck script_name.sh`.
- Test with realistic business-case inputs and boundary values.
- Test on the same OS/environment that production will use.

---

## Library Licenses (SWE 4.5)

Allowed: MIT, Apache 2.0, BSD, ISC, MPL 2.0, LGPL (dynamic linking).
Forbidden: GPL v2/v3, AGPL (without explicit GEF approval).
Every new dependency requires a documented license review.

---

## Pre-commit checklist

- [ ] Function header `Author` / Change log = current `git config user.name`
- [ ] `shellcheck` clean
- [ ] `set -euo pipefail`; no secrets
