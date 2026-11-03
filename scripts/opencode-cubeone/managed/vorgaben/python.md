---
titel: Python Coding Standards
pfade:
  - "**/*.py"
---
# Python-Standards - cube one GmbH

## Normative Grundlage

- **PEP 8** – Style Guide for Python Code (https://peps.python.org/pep-0008/)
- **cube one SWE Guideline V2, Kapitel 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- Python **3.12+**

---

## Author aus Git (verbindlich)

- Feld `Author` in Datei-Headern und Docstrings **immer** aus dem lokal wirksamen Git-Namen setzen.
- Ermitteln mit: `git config user.name` (berücksichtigt local → global).
- **Nie** einen Platzhalter (`<Author Name>`), einen Hardcode oder einen vermuteten Namen verwenden.
- Fehlt `user.name`, zuerst nachfragen bzw. `git config user.name` setzen lassen – nicht raten.

```bash
git config user.name
```

---

## Sprache (SWE 4.4.1)

- Ausschließlich **Englisch** in Code, Kommentaren und Docstrings.
- Keine deutschen Strings in Python-Dateien – UI-Texte immer über den i18n-Layer (`app/i18n/`).
- Seed-Daten (z. B. Gruppenname „Administrators") ebenfalls auf Englisch.

---

## Linting & Formatting (SWE 4.4.3, PEP 8)

- **`ruff`** für Linting und Formatting (konfiguriert in `pyproject.toml`, in `requirements.txt`).
- CI-Pflicht: `ruff check .` + `ruff format --check .` laufen im `lint`-Stage **vor** `pytest`.
- Lokale Entwicklung: `ruff check . && ruff format .` vor jedem Commit ausführen.
- Zeilenlänge: **100 Zeichen** (projektweite Festlegung, begründet abweichend von PEP 8's 79).
- Einrückung: **4 Spaces** (niemals Tabs).
- Ruff-Rules (aktiv): `E, W, F, I, N, UP, B, SIM, PERF, RUF, D, C90` – Ausnahmen in `[tool.ruff.lint.ignore]`.
- Docstring-Convention: **Google Style** (`[tool.ruff.lint.pydocstyle] convention = "google"`).

---

## Datei-Header (SWE 4.4.5)

Steht **vor** allen Imports (auch vor `from __future__ import annotations`).

```python
# company: cube one GmbH
# name: user_service.py
# author: Marvin Fenßel
# created: DD.MM.YYYY
# change log: DD.MM.YYYY – Initial implementation.
```

- `author:` = Ausgabe von `git config user.name` (Beispielwert oben nur illustrativ – immer frisch aus Git lesen).
- Jede relevante Änderung an einer Datei wird in die `change log`-Zeile eingetragen (Datum, Autor aus `user.name`, Beschreibung).
- Git-History ersetzt **nicht** den Change-Log-Eintrag im Header.

---

## Funktions-Docstrings (SWE 4.4.5, PEP 257)

Alle **öffentlichen** Funktionen und Methoden (kein `_`-Prefix) brauchen einen Docstring im **Google-Stil** mit SWE-Pflichtfeldern:

```python
async def my_service_function(db: AsyncSession, user_id: int) -> User | None:
    """Retrieve a user by ID from the database.

    Args:
        db: Active async database session.
        user_id: Primary key of the target user.

    Returns:
        The User ORM object, or None if not found.

    Raises:
        ValueError: If user_id is negative.

    Author:
        Marvin Fenßel

    Created:
        TT.MM.JJJJ

    Change log:
        TT.MM.JJJJ – Initial implementation.
    """
```

- `Author:` = `git config user.name` (Beispiel illustrativ).
- **Ausnahmen:** Getter/Setter, einfache Property-Wrapper, FastAPI-Routen-Handler (deren Signatur als Doku ausreicht), `__init__`, `__str__`.
- Mindest-Docstring bei Ausnahmen: einzeilige Kurzform `"""Brief description."""`.
- Bei komplexen Algorithmen: In-Line-Kommentare erklären das *Warum*, nicht das *Was* (SWE 4.4.5).

---

## Funktions-Header (Inline-Changelog – SWE 4.4.5)

Beim Ändern einer bestehenden Funktion wird ein Eintrag in den `Change log:`-Abschnitt des Docstrings ergänzt. Beispiel:

```python
    Change log:
        29.05.2026 – Initial implementation.
        15.06.2026 – Added pagination support (Ticket #123).
```

---

## Variablen (SWE 4.4.6)

- Variablen am Anfang des Verarbeitungsblocks deklarieren und initialisieren.
- Keine Magic Numbers – Konstanten mit beschreibendem Namen definieren.
- Keine Hardcoded Strings für Konfiguration – immer über `settings` (pydantic-settings).

---

## Naming Conventions (PEP 8, SWE 4.4.2)

| Element | Stil | Beispiel |
|---------|------|---------|
| Funktionen / Methoden | `snake_case` | `get_user_by_id` |
| Klassen | `PascalCase` | `UserRow` |
| Konstanten | `UPPER_SNAKE_CASE` | `PERMISSION_MANAGE_USERS` |
| Module / Packages | `snake_case` | `user_management` |
| Private Symbole | `_prefixed` | `_build_header` |

- Aussagekräftige, selbsterklärende Namen (SWE 4.4.2).
- Keine Abkürzungen außer weit bekannten (`db`, `id`, `url`, `ctx`).

---

## Imports (PEP 8)

- Imports immer am Dateianfang, **niemals inline** (außer nachweislich kreisförmige Abhängigkeiten – dann `# noqa: PLC0415` + Kommentar warum).
- Reihenfolge (ruff/isort erzwingt): stdlib → third-party → lokale Module.
- Kein `from module import *`.

```python
# ✅ GUT
from __future__ import annotations

import os
from pathlib import Path

from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
```

---

## Fehlerbehandlung (SWE 4.4.8, PEP 8)

```python
# ❌ SCHLECHT – stummes Schlucken ohne Log
try:
    do_something()
except Exception:
    pass

# ✅ GUT – spezifischer Typ, mit Log
try:
    do_something()
except SomeSpecificError as exc:
    logger.warning("Operation failed for %s: %s", context, exc)
```

- **`except Exception: pass`** ist verboten. Minimum: `logger.debug(..., exc_info=True)`.
- Fehler-Meldungen müssen enthalten (SWE 4.4.8): Fehlerquelle, Schweregrad (via Log-Level), Beschreibung.  
  API-Responses: `detail`-Feld mit maschinenlesbarem Code (z. B. `"stop_failed"`).
- Kein Stacktrace in API-Antworten an den Client (nur intern loggen).
- Keine `bare except:` ohne Typ.

---

## Logging (SWE 4.4.10)

- Immer `import logging` und `logger = logging.getLogger(__name__)` – kein `print()` im Produktionscode.
- Log-Level korrekt wählen: `DEBUG` (interne Details), `INFO` (Start/Stop, wichtige Ereignisse), `WARNING` (unerwartete Zustände, recoverable), `ERROR`/`EXCEPTION` (Fehler mit Impact).
- Logger-Nachrichten in Englisch, mit strukturierten Parametern: `logger.error("Deploy %d failed: %s", campaign_id, exc)`.

---

## Type Hints (PEP 484)

- `from __future__ import annotations` am Anfang jeder Datei → ermöglicht `list[str]` statt `List[str]`.
- Alle **öffentlichen** Funktionen haben vollständige Type Hints (Parameter + Return).
- `Any` nur wenn unvermeidbar, mit Kommentar.

---

## Tests (SWE 4.4.11)

- pytest als Test-Framework.
- Jedes Modul hat einen eigenen `tests/`-Unterordner.
- Fixtures in `conftest.py`, keine Test-Logik darin.
- **Kein „Testing in Compliance"** – keine Checkbox-Tests nur für Audit/Legal/Health; Details: `.cursor/rules/production-compliance.mdc`.

---

## Code-Qualität (SWE 4.4.9)

- Keine offenen Ruff-/Lint-Warnungen in CI.
- Komplexität: max. McCabe 12 (konfiguriert in `pyproject.toml`).
- Große Funktionen aufteilen – Single Responsibility (SOLID SRP).
- Keine God-Functions / God-Modules.

---

## Konfiguration

- Einstellungen ausschließlich über `pydantic-settings` und `.env`-Dateien.
- Niemals `os.environ.get()` direkt im Anwendungscode – immer über `settings`.
- Secrets nur via Umgebungsvariablen (`.env`), nie im Code.

---

## Bibliotheken / Lizenzen (SWE 4.5)

Nur kommerziell nutzbare Lizenzen erlaubt: MIT, Apache 2.0, BSD, ISC, MPL 2.0, LGPL (dynamic linking).  
**Verboten:** GPL v2/v3, AGPL (ohne explizite Freigabe durch GEF).  
Neue Abhängigkeiten erfordern eine Lizenz-Einzelprüfung (dokumentiert in `docs/manual.md`).

---

## Kurz-Checkliste vor Commit

- [ ] Datei-Header / Docstring-Author = aktuelles `git config user.name`
- [ ] `ruff check .` und `ruff format --check .` grün
- [ ] Keine Secrets; Tests für kritische Logik
