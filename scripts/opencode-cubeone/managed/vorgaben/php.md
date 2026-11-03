---
titel: PHP Coding Standards
pfade:
  - "**/*.php"
---
# PHP-Standards - cube one GmbH

## Normative Grundlage

- **PHP-FIG** (https://www.php-fig.org/)
- **PSR-1:** Basic Coding Standard (https://www.php-fig.org/psr/psr-1/)
- **PSR-4:** Autoloading Standard (https://www.php-fig.org/psr/psr-4/)
- **PSR-12:** Extended Coding Style (https://www.php-fig.org/psr/psr-12/)
- **PER Coding Style** (aktuell; erweitert/ersetzt PSR-12) (https://www.php-fig.org/per/coding-style/)
- **cube one SWE Guideline V2, Kapitel 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- PHP **8.2+** (Projektziel; ältere Syntax nur bei dokumentierter Legacy-Ausnahme)

RFC-2119-Schlüsselwörter der PHP-FIG-Specs (`MUST` / `MUST NOT` / `SHOULD` / …) gelten auch hier, soweit unten übernommen.

---

## Author aus Git (verbindlich)

- Feld `author` in Datei-Headern und PHPDoc **immer** aus dem lokal wirksamen Git-Namen setzen.
- Ermitteln mit: `git config user.name` (berücksichtigt local → global).
- **Nie** einen Platzhalter (`<Author Name>`), einen Hardcode oder einen vermuteten Namen verwenden.
- Fehlt `user.name`, zuerst nachfragen bzw. `git config user.name` setzen lassen – nicht raten.

```bash
git config user.name
```

---

## PHP-FIG Essentials (extrahiert)

Die folgenden Regeln sind die für den Alltag verbindlichen PHP-FIG-Kernvorgaben. Details und Ausnahmen: Originalspecs auf php-fig.org.

### PSR-1 – Basic Coding Standard

1. Nur `<?php` oder Short-Echo `<?=`; **keine** anderen Tag-Varianten (`<?`, `<%`, …).
2. PHP-Code **UTF-8 ohne BOM**.
3. Eine Datei **SHOULD** entweder nur Symbole deklarieren (Klassen, Funktionen, Konstanten, …) **oder** Side Effects ausführen – **nicht beides** (kein Mix aus `echo`/`include`/`ini_set` und Klassendeklaration in derselben Datei).
4. Namespaces/Klassen folgen einem Autoload-PSR → **PSR-4**.
5. Eine Klasse (Interface/Trait/Enum analog) **pro Datei**; Namespace mit Vendor-Level.
6. Klassennamen: **PascalCase** (PSR-1 „StudlyCaps“).
7. Klassenkonstanten: **`UPPER_SNAKE_CASE`**.
8. Methodennamen: **`camelCase()`**.
9. Property-Naming: in PSR-1 nicht vorgeschrieben → bei cube one einheitlich **`$camelCase`**.

### PSR-4 – Autoloading

1. FQCN: `\<Vendor>(\<SubNamespace>)*\<ClassName>` – Vendor-Namespace **MUST**.
2. Namespace-Prefix ↔ Basisverzeichnis (Composer `autoload.psr-4`).
3. Sub-Namespaces ↔ Unterordner; **case-sensitiv** wie der Namespace.
4. Klassenname ↔ Dateiname `ClassName.php` (**case-sensitiv**).
5. Underscores im Klassennamen haben **keine** Verzeichnisbedeutung.
6. Autoloader **MUST NOT** Exceptions werfen / Errors raisen.

```text
CubeOne\Shop\Repository\OrderRepository
→ src/Repository/OrderRepository.php
(bei Prefix CubeOne\Shop\ → src/)
```

### PER Coding Style / PSR-12 – Extended Coding Style

PER-CS ist der aktuelle Style-Guide; er **erweitert und ersetzt** PSR-12 und setzt PSR-1 voraus. PSR-2 ist deprecated.

#### Dateien & Zeilen

- Zeilenenden: **LF** only.
- Datei endet mit einer non-blank Zeile + genau einem LF.
- Closing `?>` in reinen PHP-Dateien **weglassen**.
- Kein hartes Zeilenlimit; Soft Limit **120**; SHOULD möglichst ≤ 80 (cube one: anstreben ≤ **100**).
- Kein trailing Whitespace; max. **eine** Anweisung pro Zeile.
- Indent: **4 Spaces**, keine Tabs.
- Keywords/Typen lowercase; kurze Formen: `bool`, `int`, `string`, …

#### Dateikopf-Blöcke (Reihenfolge, je eine Leerzeile dazwischen)

```text
1. <?php
2. File-level DocBlock
3. declare(…)
4. namespace …
5. use Class…   (alphabetisch / grouped laut PER-CS)
6. use function …
7. use const …
8. Code (class / functions)
```

#### Klassen, Methoden, Sichtbarkeit

- `{` von Klasse/Methode auf **eigener Zeile**; `}` allein auf einer Zeile.
- Visibility **MUST** an Properties und Methoden.
- `abstract` / `final` / `readonly` vor Visibility; `static` nach Visibility (PER-CS Modifier-Reihenfolge beachten, inkl. asymmetric visibility).
- `extends` auf derselben Zeile wie Klassenname; lange `implements`-Listen umbrechen, ein Interface pro Folgezeile.
- Methodenaufrufe: kein Space vor `(`; Kontrollstrukturen: Space nach Keyword, kein Space nach `(` / vor `)`.

#### Listen & Typen

- Einzeilige Listen: **kein** trailing comma.
- Mehrzeilige Listen (Args, Arrays, `match`, …): trailing comma **MUST**.
- Compound types: keine Spaces um `|` / `&` / innere Klammern; `null` zuletzt; `?T` statt `T|null` bevorzugen.
- Return type: kein Space vor `:`, ein Space danach: `): string`.
- Nullable: `?string` (kein Space nach `?`).

#### Naming (PER-CS 2.7)

- Abkürzungen/Akronyme wie normale Wörter: `XmlHttpRequest`, nicht `XMLHTTPRequest` (Ausnahme: etablierte Konstanten wie `HTTP`/`URL` wo üblich).

#### Moderne Konstrukte (PER-CS)

- `match`, Enums, Attributes, Heredoc/Nowdoc, Anonymous Classes gemäß PER-CS formatieren.
- Attributes auf eigener Zeile unmittelbar vor dem Element; `#[Attr]` ohne Space nach `#[`.

### Interop-Interfaces (anwenden, wenn die Domäne passt)

Nicht jeder Code braucht alle Interfaces – aber **keine Eigenbau-Interfaces**, wenn ein akzeptiertes PSR existiert:

| PSR | Thema | Wann |
|-----|--------|------|
| [PSR-3](https://www.php-fig.org/psr/psr-3/) | Logger | Logging |
| [PSR-6](https://www.php-fig.org/psr/psr-6/) / [PSR-16](https://www.php-fig.org/psr/psr-16/) | Cache | Caching |
| [PSR-7](https://www.php-fig.org/psr/psr-7/) / [15](https://www.php-fig.org/psr/psr-15/) / [17](https://www.php-fig.org/psr/psr-17/) / [18](https://www.php-fig.org/psr/psr-18/) | HTTP | Messages, Middleware, Factories, Client |
| [PSR-11](https://www.php-fig.org/psr/psr-11/) | Container | DI-Container-Zugriff |
| [PSR-14](https://www.php-fig.org/psr/psr-14/) | Event Dispatcher | Events |
| [PSR-13](https://www.php-fig.org/psr/psr-13/) | Hypermedia Links | Link-Relationen |
| [PSR-20](https://www.php-fig.org/psr/psr-20/) | Clock | Zeit (`ClockInterface` statt `time()` hardcoden in testbarem Code) |

---

## Sprache (SWE 4.4.1)

- Ausschließlich **Englisch** in Code, Kommentaren, PHPDoc und Bezeichnern.
- Keine deutschen Strings in PHP – UI über i18n / Content-Dateien.
- UTF-8 ohne BOM; LF – siehe PHP-FIG Essentials.

---

## Datei-Header (SWE 4.4.5)

Jede nicht-triviale PHP-Datei beginnt mit Header-DocBlock nach `<?php` (vor oder gemäß Projektkonvention um `declare`):

```php
<?php

/**
 * company: cube one GmbH
 * name: UserService.php
 * author: Marvin Fenßel
 * created: DD.MM.YYYY
 * change log: DD.MM.YYYY – Initial implementation.
 */

declare(strict_types=1);

namespace CubeOne\Shop;
```

- `author:` = Ausgabe von `git config user.name` (Beispielwert oben nur illustrativ – immer frisch aus Git lesen).
- Jede relevante Änderung in `change log` (Datum, Autor aus `user.name`, Beschreibung).
- Git-History ersetzt **nicht** den Change-Log-Eintrag im Header.

---

## Linting & Formatting (SWE 4.4.3)

### Tooling (verbindlich)

| Zweck | Tool | Ruleset |
|-------|------|---------|
| Auto-Format / Fix | **PHP-CS-Fixer** | `@PER-CS` (bevorzugt) oder `@PER-CS3.0` |
| Lint / CI-Gate | **PHP_CodeSniffer** (`phpcs`) | `PSR12` |
| Auto-Fix (phpcs) | **phpcbf** | `PSR12` |

- Keine offenen Fixer-/phpcs-Findings in CI; lokal vor jedem Commit ausführen.
- `declare(strict_types=1);` in neuem Code **Pflicht** (cube one; per Fixer erzwingbar).

### `.php-cs-fixer.dist.php`

```php
<?php

declare(strict_types=1);

$finder = (new PhpCsFixer\Finder())
    ->in([__DIR__ . '/src', __DIR__ . '/tests'])
    ->exclude(['vendor', 'var', 'storage']);

return (new PhpCsFixer\Config())
    ->setRules([
        '@PER-CS' => true,
        'declare_strict_types' => true,
        'ordered_imports' => ['sort_algorithm' => 'alpha'],
        'no_unused_imports' => true,
        'array_syntax' => ['syntax' => 'short'],
    ])
    ->setRiskyAllowed(true)
    ->setFinder($finder);
```

### `phpcs.xml.dist`

```xml
<?xml version="1.0"?>
<ruleset name="cube-one-php">
  <description>cube one PHP – PHP-FIG PSR-12</description>
  <file>src</file>
  <file>tests</file>
  <exclude-pattern>*/vendor/*</exclude-pattern>
  <arg name="colors"/>
  <arg value="sp"/>
  <rule ref="PSR12"/>
</ruleset>
```

### CLI

```bash
vendor/bin/php-cs-fixer fix --dry-run --diff
vendor/bin/phpcs
vendor/bin/php-cs-fixer fix
vendor/bin/phpcbf
```

```json
{
  "require-dev": {
    "friendsofphp/php-cs-fixer": "^3.0",
    "squizlabs/php_codesniffer": "^3.0"
  }
}
```

---

## Naming (PSR-1 / PER-CS + SWE 4.4.2)

| Element | Stil | Beispiel |
|---------|------|----------|
| Namespaces | PascalCase + Vendor | `CubeOne\Shop` |
| Klassen / Interfaces / Enums / Traits | PascalCase | `UserService` |
| Methoden / Funktionen | camelCase | `findById()` |
| Konstanten | UPPER_SNAKE_CASE | `MAX_RETRY_COUNT` |
| Properties / Variablen | camelCase | `$orderId` |
| Dateien | Klassenname + `.php` | `UserService.php` |

---

## Formatierungsbeispiele

```php
// ✅ GUT
if ($count === 0) {
    return;
}

$result = $this->client->request(
    'GET',
    $path,
    [
        'headers' => $headers,
        'timeout' => self::DEFAULT_TIMEOUT,
    ],
);

// ❌ SCHLECHT
if($count==0) return;
```

```php
<?php

/**
 * company: cube one GmbH
 * name: OrderRepository.php
 * author: Marvin Fenßel
 * created: 27.07.2026
 * change log: 27.07.2026 – Initial implementation.
 */

declare(strict_types=1);

namespace CubeOne\Shop\Repository;

use CubeOne\Shop\Model\Order;
use Psr\Log\LoggerInterface;

use function sprintf;

final class OrderRepository
{
    public function __construct(
        private readonly LoggerInterface $logger,
    ) {
    }

    public function findById(int $orderId): ?Order
    {
        $this->logger->debug(sprintf('Fetching order [%d]', $orderId));

        return null;
    }
}
```

(`author` erneut nur Beispiel – Wert aus `git config user.name`.)

---

## PHPDoc & Kommentare (SWE 4.4.5)

- PHPDoc wo Signatur allein nicht reicht (Generics, Array-Shapes, Side Effects, `@throws`).
- `@author` = `git config user.name`.
- Kommentare erklären **Warum**; kein Totcode; TODO nur mit Ticket: `// TODO: JIRA-1234 – …`.

---

## Struktur, Fehler, Logging (SWE 4.4.4 / 4.4.8 / 4.4.10)

- SRP; Constructor Injection; PSR-Interfaces wo passend.
- Keine Magic Numbers / Secrets im Code.
- Exceptions nicht schlucken; Logging über **PSR-3** `LoggerInterface`.

```php
try {
    $this->repository->save($order);
} catch (StorageException $exception) {
    $this->logger->error(
        'Failed to save order [{orderId}]: {message}',
        [
            'orderId' => $order->getId(),
            'message' => $exception->getMessage(),
            'exception' => $exception,
        ],
    );
    throw new OrderPersistenceException(
        sprintf('Could not persist order %d.', $order->getId()),
        0,
        $exception,
    );
}
```

---

## Sicherheit

- Output escapen (XSS); SQL nur prepared / Query-Builder.
- Kein `eval`, kein dynamisches `include` mit User-Input; keine Secrets im Repo.

---

## Tests (SWE 4.4.11)

- PHPUnit (oder Projektstandard); `ClassNameTest`; PSR-4 unter `tests/`.
- Dieselbe phpcs-/PHP-CS-Fixer-Pipeline wie für Produktivcode.

---

## Bibliotheken / Lizenzen (SWE 4.5)

Erlaubt: MIT, Apache 2.0, BSD, ISC, MPL 2.0, LGPL (dynamic linking).  
**Verboten:** GPL v2/v3, AGPL (ohne GEF-Freigabe). Lizenzprüfung für jedes neue Paket.

---

## Kurz-Checkliste vor Commit

- [ ] PSR-1/4/PER-CS Essentials eingehalten (Tags, UTF-8, eine Klasse/Datei, Autoload-Pfad, Style)
- [ ] `declare(strict_types=1);`, kein `?>`
- [ ] `author` = aktuelles `git config user.name`
- [ ] Change-Log im Header aktualisiert
- [ ] `php-cs-fixer fix --dry-run --diff` und `phpcs` grün
- [ ] Keine Secrets / Totcode; Tests für kritische Logik
