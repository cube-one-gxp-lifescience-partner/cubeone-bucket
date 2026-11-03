---
titel: JavaScript Coding Standards
pfade:
  - "**/*.js"
---
# JavaScript-Standards - cube one GmbH

## Normative Grundlage

- **Airbnb JavaScript Style Guide** (https://github.com/airbnb/javascript) – verbindlich für alle JS-Dateien
- **cube one SWE Guideline V2, Kapitel 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- Kein Bundler / kein Babel – Browser-natives ES2022+ (alle modernen Evergreen-Browser)
- jQuery wird **nicht** verwendet – reines DOM-API

---

## Author aus Git (verbindlich)

- Das `@author`-Feld in JSDoc **immer** aus dem lokal wirksamen Git-Namen setzen.
- Ermitteln mit: `git config user.name` (berücksichtigt local → global).
- **Nie** einen Platzhalter (`<Author Name>`), einen Hardcode oder einen vermuteten Namen verwenden.
- Fehlt `user.name`, zuerst nachfragen bzw. `git config user.name` setzen lassen – nicht raten.

```bash
git config user.name
```

---

## Sprache (SWE 4.4.1)

- Ausschließlich **Englisch** in Code, Kommentaren und JSDoc.
- UI-Strings nie direkt in JS – immer über `data-`-Attribute im Template (i18n-konform).

---

## Tooling (SWE 4.4.3)

- **ESLint v9+** mit Flat-Config (`eslint.config.mjs`) + `globals`-Paket für Browser-Globals.
- Lokale Entwicklung: `npx eslint static/js/` vor Commits ausführen (ESLint + globals via npx).
- Kein Formatter-Zwang (Prettier optional), aber konsistente Formatierung gemäß dieser Rule.

---

## Funktions-JSDoc (SWE 4.4.5, Airbnb §18)

Jede **öffentliche Funktion** (d. h. nicht rein interner Helfer) erhält einen JSDoc-Block:

```js
/**
 * Kurze Beschreibung der Funktion.
 *
 * @param {string} name - Beschreibung des Parameters
 * @param {Object} [options={}] - Optionale Konfiguration
 * @returns {HTMLElement} Das erzeugte Element
 *
 * @author Marvin Fenßel
 * @created TT.MM.JJJJ
 * @changelog TT.MM.JJJJ - Initiale Implementierung
 */
```

- `@author` = Ausgabe von `git config user.name` (Beispielwert oben nur illustrativ – immer frisch aus Git lesen).
- Multiline-Kommentare immer als `/** ... */`, nie als mehrere `//`-Zeilen (Airbnb §18.1).
- Single-line-Kommentare als `//` mit Leerzeichen danach (Airbnb §18.3).
- Kein kommentierter Code im Repo – entfernen statt auskommentieren.

---

## Referenzen: const / let / kein var (Airbnb §2)

```js
// FALSCH
var count = 0;

// RICHTIG
const MAX = 100;   // unveränderlich
let count = 0;     // wird später reassigned
```

- `const` für alles, das nicht reassigned wird.
- `let` nur wenn Reassignment nötig.
- `var` ist verboten (eslint: `no-var`, `prefer-const`).

---

## Strings: Single Quotes + Template Literals (Airbnb §6)

```js
// FALSCH
const name = "cobra";
const msg = "Hello, " + name + "!";

// RICHTIG
const name = 'cobra';
const msg = `Hello, ${name}!`;
```

- Single Quotes `'...'` für alle Strings (außer wenn der String selbst Apostrophe enthält).
- **Template Literals** `` `...` `` bei Interpolation oder Multiline – nie String-Konkatenation mit `+`.
- Kein `eval()` (eslint: `no-eval`).

---

## Funktionen (Airbnb §7–8)

### Named Function Expressions bevorzugen

```js
// VERMEIDEN (anonyme Declaration)
function foo() { … }

// BESSER (named expression)
const handleClick = function handleClick(event) { … };
```

### Arrow Functions für Callbacks

```js
// FALSCH
setTimeout(function () { doSomething(); }, 200);
[1, 2, 3].map(function (x) { return x * 2; });

// RICHTIG
setTimeout(() => { doSomething(); }, 200);
[1, 2, 3].map((x) => x * 2);
```

- Arrow Functions immer mit Klammern um Parameter, auch bei einem Parameter (eslint: `arrow-parens`).
- Kein `arguments`-Objekt – Rest-Syntax `...args` verwenden (eslint: `prefer-rest-params`).
- Default-Parameter ans Ende: `function foo(name, opts = {})`.
- Keine Funktionsdeklarationen innerhalb von Blöcken (`if`, `for`, …).

---

## Objekte & Arrays (Airbnb §3–4)

```js
// Objekt: Shorthand + kein new Object()
const { name, age } = user;
const copy = { ...original, extra: true };

// Array: Spread statt .slice()
const clone = [...items];
const nodes = [...document.querySelectorAll('.foo')];
```

- Objekt-Methoden als Shorthand: `{ doThing() { … } }` (eslint: `object-shorthand`).
- Spread `{ ...obj }` statt `Object.assign({}, obj)` (eslint: `prefer-object-spread`).
- Kein `new Array()` (eslint: `no-array-constructor`).

---

## Destructuring (Airbnb §5)

```js
// FALSCH
const firstName = user.firstName;
const lastName = user.lastName;

// RICHTIG
const { firstName, lastName } = user;
const [first, second] = arr;
```

---

## Variablen (Airbnb §13)

- Eine `const`/`let`-Deklaration pro Variable (eslint: `one-var`).
- Kein Chaining: `let a = b = c = 1;` verboten (eslint: `no-multi-assign`).
- Kein `++`/`--` – stattdessen `+= 1` / `-= 1` (eslint: `no-plusplus`).
- Keine unbenutzten Variablen (eslint: `no-unused-vars`).

---

## Gleichheit & Vergleiche (Airbnb §15)

```js
// FALSCH
if (x == null) { … }

// RICHTIG
if (x === null) { … }
if (x === undefined) { … }
if (x == null) { … }   // Ausnahme: null-check via ==
```

- Immer `===` / `!==` (eslint: `eqeqeq`).
- Nullish coalescing `??` statt `||` wenn nur `null`/`undefined` geprüft wird.
- Keine verschachtelten Ternaries (eslint: `no-nested-ternary`).

---

## Blöcke & Kontrollfluss (Airbnb §16–17)

```js
// FALSCH
if (test)
  return false;

// RICHTIG
if (test) {
  return false;
}

// nach return kein else nötig
if (x) {
  return x;
}
return y;
```

- Immer geschweifte Klammern bei Multiline-Blöcken (eslint: `nonblock-statement-body-position`).
- `else` auf gleicher Zeile wie `}` (eslint: `brace-style`).
- Kein `else` nach `return` im `if`-Block (eslint: `no-else-return`).

---

## Whitespace & Formatierung (Airbnb §19–20)

- **2 Spaces** Einrückung (kein Tab) (eslint: `indent`).
- Zeilen max. **100 Zeichen** (eslint: `max-len`).
- Leerzeichen vor öffnender Klammer bei Kontrollstrukturen: `if (x) {`.
- Kein Leerzeichen zwischen Funktionsname und Klammer: `fn()` nicht `fn ()`.
- Leerzeichen nach Komma: `fn(a, b)` nicht `fn(a,b)`.
- Leerzeichen innerhalb `{ }` bei Objektliteralen: `{ key: value }`.
- Trailing Commas bei mehrzeiligen Objekten, Arrays und Parameterlisten:

```js
const obj = {
  a: 1,
  b: 2,   // ← trailing comma
};
```

- Keine Leerzeilen am Anfang oder Ende eines Blocks.

---

## Semikolons (Airbnb §21)

- **Immer Semikolons** am Ende jeder Anweisung (eslint: `semi`).
- Kein ASI-Vertrauen.

---

## Naming Conventions (Airbnb §23)

| Kontext | Convention | Beispiel |
|---|---|---|
| Variablen, Funktionen | `camelCase` | `getUserName`, `isActive` |
| Klassen, Konstruktoren | `PascalCase` | `class UserModal` |
| Konstanten (exportiert, unveränderlich) | `UPPER_SNAKE_CASE` | `const POLL_MS = 5000` |
| Private Konventionen | kein `_` Präfix | – |
| Boolean-Getter | `isX()` / `hasX()` | `isPaused()`, `hasError()` |

- Keine einbuchstabigen Namen außer in Schleifen (`i`, `j`).
- Akronyme vollständig groß oder klein: `getURL()` oder `getUrl()`, nie gemischt inkonsistent.

---

## Fehlerbehandlung (SWE 4.4.6)

```js
// FALSCH – leerer catch
try {
  doSomething();
} catch (err) {}

// FALSCH – catch ohne Logging
try {
  doSomething();
} catch (err) {
  // ignore
}

// RICHTIG
try {
  doSomething();
} catch (err) {
  console.error('doSomething failed:', err);
}
```

- Kein leerer `catch`-Block (eslint: `no-empty`).
- Erwartete Nicht-Fehler (z. B. WebSocket-Abbruch) explizit kommentieren.
- `console.error()` / `console.warn()` für Fehler – kein stilles Schlucken.

---

## Module & IIFEs (Airbnb §10, Projektkontex)

Da COBRA keine ES-Module im Browser verwendet (kein Bundler), gilt:

- Alle JS-Dateien sind in **IIFEs** eingehüllt: `(function () { … }());`
- Globale Objekte werden explizit ans `window` gehängt, wenn nötig: `window.cobraToast = { … };`
- Kein `require()` / kein `import` in Browser-Dateien.
- IIFEs mit sofortigem Aufruf in Klammern: `(function () { … }());` (Airbnb §7.2).

---

## Was NICHT verwendet wird (Kontext)

- Kein jQuery (`$`) – reines DOM-API
- Kein Babel / kein Transpiling
- Keine ES-Module (`import`/`export`) in Browser-Dateien
- Keine `prototype`-Manipulation – stattdessen `class`-Syntax
- Kein `arguments` – Rest-Parameter `...args`
- Kein `var`

---

## Kurz-Checkliste vor Commit

- [ ] JSDoc `@author` / `@changelog` = aktuelles `git config user.name`
- [ ] `npx eslint static/js/` grün
- [ ] Keine Secrets; kein auskommentierter Totcode
