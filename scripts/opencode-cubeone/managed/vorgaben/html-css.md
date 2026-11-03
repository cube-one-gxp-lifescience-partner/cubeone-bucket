---
titel: HTML- & CSS-Coding-Standards
pfade:
  - "**/*.html"
  - "**/*.css"
  - "**/*.scss"
---
# HTML- & CSS-Standards - cube one GmbH

## Normative Grundlage

- **Google HTML/CSS Style Guide** (https://google.github.io/styleguide/htmlcssguide.html)
- **cube one SWE Guideline V2, Kapitel 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- **WCAG 2.1 AA** (Barrierefreiheit; BFSG wo anwendbar)
- HTML5 / CSS3 (moderne Evergreen-Browser; kein IE-Support)

---

## Author aus Git (verbindlich)

- Feld `author` in Datei-Headern **immer** aus dem lokal wirksamen Git-Namen setzen.
- Ermitteln mit: `git config user.name` (berücksichtigt local → global).
- **Nie** einen Platzhalter (`<Author Name>`), einen Hardcode oder einen vermuteten Namen verwenden.
- Fehlt `user.name`, zuerst nachfragen bzw. `git config user.name` setzen lassen – nicht raten.

```bash
git config user.name
```

---

## Sprache (SWE 4.4.1)

- Ausschließlich **Englisch** in Kommentaren, Klassen-/ID-Namen, Dateinamen und `aria-*`-Werten, die Entwickler lesen.
- Sichtbare UI-Texte nie hart in wiederverwendbaren Partials/Komponenten verdrahten – über i18n-Layer bzw. projektübliche Content-Dateien.
- `lang`-Attribut am Root-Element korrekt setzen (`lang="de"` bzw. `lang="en"` je Zielmarkt).
- Keine HTML-Entities für Umlaute/Sonderzeichen bei UTF-8 (`ä`, nicht `&auml;`).

---

## Datei-Header (SWE 4.4.5)

Jede nicht-triviale HTML-/CSS-Datei beginnt mit einem Header-Kommentar **vor** dem restlichen Inhalt:

```html
<!--
  company: cube one GmbH
  name: index.html
  author: Marvin Fenßel
  created: DD.MM.YYYY
  change log: DD.MM.YYYY – Initial implementation.
-->
```

```css
/**
 * company: cube one GmbH
 * name: style.css
 * author: Marvin Fenßel
 * created: DD.MM.YYYY
 * change log: DD.MM.YYYY – Initial implementation.
 */
```

- `author:` = Ausgabe von `git config user.name` (Beispielwert oben nur illustrativ – immer frisch aus Git lesen).
- Jede relevante Änderung wird in die `change log`-Zeile eingetragen (Datum, Autor aus `user.name`, Beschreibung).
- Git-History ersetzt **nicht** den Change-Log-Eintrag im Header.

---

## Linting & Formatting (SWE 4.4.3)

- **HTML:** W3C Markup Validator (CI und lokal vor Commit).
- **CSS:** W3C CSS Validator (Profil `css3svg` wo verfügbar) und/oder Stylelint.
- Empfohlenes Tooling: Stylelint + `stylelint-config-standard`, Prettier nur wenn projektweit vereinbart.
- Einrückung: **2 Spaces** (niemals Tabs) – Google HTML/CSS Style Guide.
- Zeilenlänge: **100 Zeichen** (projektweite Festlegung analog anderer cube-one-Sprachen).
- Keine offenen Validator-/Linter-Warnungen in CI.
- Lokale Entwicklung: Validator-/Lint-Skript des Projekts vor jedem Commit ausführen.

---

## HTML – Semantik & Struktur (SWE 4.4.4)

1. **HTML5 semantisch:** `header`, `nav`, `main`, `section`, `article`, `aside`, `footer`.
2. Genau **ein** `<h1>` pro Seite; Überschriften-Hierarchie ohne Sprünge (`h1` → `h2` → `h3`).
3. Landmarks und Abschnitte so wählen, dass die Seite ohne CSS sinnvoll lesbar bleibt.
4. Kein `<div>`-/`<span>`-Missbrauch für interaktive Elemente – Buttons sind `<button>`, Links sind `<a href="…">`.
5. Listen nur für Listeninhalte (`ul`/`ol`/`dl`), Tabellen nur für tabellarische Daten.
6. **Keine Inline-Styles** und **keine Inline-Scripts**, außer dokumentiertem kritischem CSS/JS im `<head>`.
7. Externe Assets über relative oder konfigurierte Basis-URLs; keine toten Pfade.

### Pflichtblock im `<head>` (Marketing-/Content-Seiten)

- `<meta charset="utf-8">`
- `<meta name="viewport" content="width=device-width, initial-scale=1">`
- `<title>` (aussagekräftig, projektübliche Längenlimits einhalten)
- `<meta name="description">` wo SEO relevant
- Canonical / Open Graph / Twitter Cards gemäß Projekt-SEO-Regel
- Stylesheets und kritische Prefetches bewusst und sparsam

```html
<!DOCTYPE html>
<html lang="de">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Page topic | Product name</title>
    <meta name="description" content="…">
    <link rel="stylesheet" href="assets/css/style.css">
  </head>
  <body>
    <a class="skip-link" href="#main">Skip to content</a>
    <header>…</header>
    <main id="main">…</main>
    <footer>…</footer>
  </body>
</html>
```

---

## HTML – Attribute & Markup-Stil

- Attributwerte in **doppelten Anführungszeichen**: `class="card"`.
- Boolesche Attribute ohne Wert: `disabled`, `required`, `checked` (nicht `disabled="disabled"`).
- Reihenfolge der Attribute (empfohlen): `id` → `class` → `name` → `data-*` → `src`/`href` → `type` → `alt`/`title` → ARIA → sonstige.
- Leerzeichen um `=` vermeiden: `class="x"`, nicht `class = "x"`.
- Selbstschließende Void-Elemente ohne Slash (HTML5): `<img …>`, `<br>`, `<meta …>`.
- Kein XHTML-Stil (`/>`) außer in SVG/XML-Kontexten.

```html
<!-- ✅ GUT -->
<img src="hero.webp" alt="Practice reception desk" width="1200" height="800" loading="lazy">

<!-- ❌ SCHLECHT -->
<img src='hero.webp' alt="" style="width:100%">
```

---

## HTML – Bilder, Medien, Formulare

### Bilder & Medien

- Jedes `<img>` braucht aussagekräftiges `alt` (dekorativ: `alt=""`).
- Immer `width` und `height` setzen (Layout-Shift vermeiden).
- `loading="lazy"` unterhalb des Folds; LCP-/Hero-Bild **ohne** Lazy-Loading.
- Formate: SVG für Logos/Icons, WebP/AVIF für Fotos (mit sinnvollem Fallback laut Projekt).
- `<iframe>` nur mit `title`; Drittanbieter-Embeds hinter Consent wo rechtlich nötig.
Implementiere eine EU-AI-Act-konforme Kennzeichnung (Art. 50 KI-VO) für alle
KI-generierten Bilder in diesem Projekt – als wiederverwendbare Komponente
„KiBild“ im Clean Design (Icon-only).

## Offizielle Icons
- Verwende AUSSCHLIESSLICH die offiziellen EU-Icons „AI im Kreis“
  (Quelle: https://digital-strategy.ec.europa.eu/en/policies/eu-icons-labelling-ai-generated-content),
  abgelegt unter `assets/eu-ai-icons/ai-white.png` und `ai-black.png`
  (freigestellt, transparenter Hintergrund, ca. 96px).
- Icon im Badge als CSS-`background-image` an einer Varianten-Klasse einbinden,
  NICHT als `<img>` – sonst greifen globale Karten-Selektoren wie
  `.card img { width: 100% }` auf das Icon und blähen es auf.

## Badge-Verhalten (Clean Design)
1. Ruhezustand: NUR der runde Icon-Chip, 24×24px (= Mindest-Touch-Target),
   halbtransparente Pill, rechts unten im Bild mit 8–12px Randabstand,
   `position: absolute` auf relativ positioniertem Wrapper. Kein Layout-Shift.
2. Expansion zu „AI GENERATED“ NUR bei Interaktion mit dem Badge selbst:
   `:hover` und `:focus-visible` auf `.ki-badge` – NICHT auf dem Bild-Container.
   Animation nur über `max-width`/`opacity`/`transform`,
   `prefers-reduced-motion` respektieren.
3. Touch-Geräte (`@media (hover: none)`): Tap auf das Badge toggelt die
   Expansion, Tap außerhalb kollabiert. Das Badge fängt nur auf seiner kleinen
   Chip-Fläche Events (preventDefault/stopPropagation), damit verlinkte Karten
   darunter klickbar bleiben.
4. Das Badge darf nie von anderen Elementen überdeckt werden (z-index, fixe
   Chat-Buttons, Cookie-Banner!). Sonderfall bildschirmhohe Heros (100vh):
   dort kollidiert die rechte untere Ecke dauerhaft mit fixen Elementen am
   Viewport-Boden → Hero-Badge stattdessen oben rechts unter der Navbar
   verankern (`top: clamp(72px, 8vw, 96px); right: 12px`).
5. In Slidern/Galerien/Lightboxen am Bild-Container verankern (wandert mit);
   bei geklonten Slides (z. B. Splide) per MutationObserver nachziehen.
   In der Lightbox/Großansicht die volle Variante zeigen.

## Automatische Farbwahl
- Clientseitig per Canvas die mittlere Luminanz des unteren rechten
  Bildviertels messen (nach `load`; bei Lazy Loading `complete` prüfen).
- Formel: 0.2126*R + 0.7152*G + 0.0722*B, normiert 0–1.
- Dunkel (<0.5): weißes Icon/weiße Schrift auf dunkler Pill.
  Hell (>=0.5): schwarzes Icon/schwarze Schrift auf heller Pill.
- WICHTIG: Alpha der Pill so wählen, dass der Text-Kontrast WCAG AA (≥4.5:1)
  erreicht – rgba(0,0,0,0.45) reicht dafür NICHT (nur ~3.2:1),
  rgba(0,0,0,0.65) verwenden; helle Variante analog prüfen.
- Fallback bei CORS/Canvas-Fehler: weiße Variante auf dunkler Pill.
- Manueller Override per `data-ki-badge="light" | "dark"`.
- CSS-`background-image`-Sektionen (Hero-/Themen-Banner) ebenfalls kennzeichnen:
  Badge per JS in die Sektion injizieren; Farbwahl dort pragmatisch per
  `data-ki-badge` vorgeben, wenn die Banner-Farbwelt bekannt ist.

## Barrierefreiheit
- Alt-Text-Muster: „KI-generiertes Bild: <Beschreibung>“
  (EN-Seiten: „AI-generated image: <description>“).
  Präfix automatisch voranstellen; fehlt die Beschreibung → console.warn.
- `title="KI-generiertes Bild"` / `title="AI-generated image"` auf dem <img>.
- Da das Badge interaktiv ist (Tap/Hover-Toggle): `role="button"`,
  `tabindex="0"`, `aria-expanded`, sprachrichtiges `aria-label`,
  Enter/Space toggeln, Escape kollabiert. KEIN `aria-hidden` auf dem
  interaktiven Element. `<span role="button">` statt `<button>`, wenn Badges
  in verlinkten Karten sitzen (Button in Link wäre invalides HTML).
- Sichtbarer Fokusring auf dem Badge.

## Ausnahmen
- ECHTE Fotos (reale Personen, Team-/Messebilder, Logos, SVG-Icons) werden
  NICHT gekennzeichnet. Lege eine explizite Liste der KI-Assets und der
  Ausnahmen an: [LISTE DER BILDORDNER/ASSETS IM ZIELPROJEKT].

## Footer-Hinweis
Auf jeder Seite (über die zentrale Footer-Komponente):
DE „Bildmaterial auf dieser Website ist KI-generiert und zeigt keine realen
Personen.“ / EN „Imagery on this website is AI-generated and does not depict
real persons.“

## Umsetzung im Bestand
- Rollout über alle Seiten/Sprachversionen; bevorzugt per zentraler
  JS-Injektion (Asset-Manifest + Selektoren) statt hunderte Templates
  anzufassen – kein Wrapper-Umbau, wenn das Layout gefährdet würde
  (dann Badge auf bestehenden Container setzen und diesem
  `position: relative` geben).
- Sauberes, kommentiertes CSS/JS ohne externe Dependencies.
  [STACK-SPEZIFIK: bei Framework-Projekten stattdessen als Komponente/Partial.]

## Qualitätssicherung
- Projektregel anlegen: Jedes neue KI-Bild muss die Kennzeichnung tragen;
  Icons nur aus `assets/eu-ai-icons/`; echte Fotos nie kennzeichnen.
- Reminder-Check (z. B. Post-Commit-Hook, jeder 3. Commit): Script prüft
  heuristisch auf ungekennzeichnete KI-`<img>` – nur Warnung, kein Hard-Fail.

## Akzeptanzkriterien
1. Jedes KI-Bild zeigt beim ersten Rendern den Icon-Chip; „AI GENERATED“
   erscheint bei Hover/Fokus/Tap auf dem Badge – Hover über das Bild abseits
   des Badges expandiert NICHT.
2. Dunkle Ecke → weißes Icon, helle Ecke → schwarzes Icon; Override wirkt.
3. Alt-Texte tragen das Präfix (sprachrichtig je Sprachversion).
4. Badge funktioniert mit Lazy Loading, in Karussells und Lightboxen und wird
   nie von Chat-Buttons/Cookie-Bannern überdeckt (Hero-Sonderfall beachten).
5. Footer-Hinweis auf jeder Seite.
6. Keine Konsolen-Fehler; CORS-Fallback greift; Linter grün.
7. Verifikation per Headless-Browser-Screenshots: Desktop (Ruhe, Hover auf
   Badge, Hover auf Bild), Mobile (Ruhe, Tap expandiert), mehrere Seitentypen.

### Formulare
- Sicherheitsmaßnamen wie Honeypot bzw. Captcha
- Jedes Feld hat ein sichtbares `<label>` (mit `for`/`id` oder Wrapping).
- `autocomplete` setzen, wo sinnvoll (`name`, `email`, `tel`, …).
- Fehlermeldungen als Text (nicht nur Farbe); `aria-invalid` / `aria-describedby` bei Fehlern.
- Kein reines Placeholder-Labeling.
- Submit über `<button type="submit">`, nicht über gestylte `div`s.

---

## Barrierefreiheit (WCAG 2.1 AA)

- Kontrast Text/Hintergrund ≥ **4,5:1** (große Schrift ≥ 3:1).
- Sichtbare Fokus-Stile; Fokus nie mit `outline: none` ohne Ersatz entfernen.
- Icon-only-Controls: `aria-label` (oder sichtbarer Text).
- Skip-Link zur Hauptinhalt-Landmark.
- Touch-Ziele mindestens **44×44 px**.
- `@media (prefers-reduced-motion: reduce)` respektieren – Animationen abschalten oder stark reduzieren.
- Dekorative SVGs: `aria-hidden="true"`; bedeutsame: `role="img"` + `aria-label`.
- Keine Information nur über Farbe vermitteln.

---

## CSS – Architektur & Tokens (SWE 4.4.4)

1. Styles zentral und vorhersehbar organisieren (ein Haupt-Stylesheet und/oder klar getrennte Partials – kein wildes Streuen).
2. Design-Tokens als **CSS Custom Properties** in `:root` (Farben, Radien, Abstände, Schatten, Breakpoints-Hilfen).
3. Keine Magic Numbers im Komponenten-CSS – Werte über Tokens oder benannte Custom Properties.
4. Mobile-first: Basis = schmaler Viewport, Erweiterungen über `min-width`-Media-Queries.
5. Keine ID-Selektoren für Styling (`#header { … }` verboten für Präsentation).
6. Keine `!important` außer in klar begründeten Utility-/Override-Fällen (Kommentar Pflicht).
7. Keine tiefen Selektor-Ketten (max. ca. 3 Ebenen); Spezifität niedrig halten.

```css
:root {
  --color-accent: #b02059;
  --color-ink: #3a3a3c;
  --space-md: 1rem;
  --radius: 12px 0 12px 0;
  --font-sans: "Source Sans 3", system-ui, sans-serif;
}
```

---

## CSS – Naming (SWE 4.4.2)

| Element | Stil | Beispiel |
|---------|------|---------|
| Komponenten / Blöcke | BEM-light, `kebab-case` | `.card`, `.site-header` |
| Elemente | `block__element` | `.card__title` |
| Modifikatoren | `block--modifier` | `.card--accent` |
| Utilities (sparsam) | präfixiert, beschreibend | `.u-sr-only`, `.is-open` |
| Custom Properties | `--kebab-case` | `--color-accent` |
| Dateien | `kebab-case` | `style.css`, `tokens.css` |
| IDs (nur Hooks/A11y/JS) | `camelCase` oder `kebab-case`, sparsam | `#main`, `#contactForm` |

- Aussagekräftige, selbsterklärende Namen (SWE 4.4.2).
- Keine Präsentationsnamen wie `.red-text` oder `.margin-left-10` als Komponentenklassen.
- Keine Abkürzungen außer weit bekannten (`btn` nur wenn projektweit etabliert; bevorzugt ausgeschrieben).

```css
/* ✅ GUT */
.card { … }
.card__title { … }
.card--featured { … }

/* ❌ SCHLECHT */
.CardTitle { … }
.red { … }
#main .wrapper div span { … }
```

---

## CSS – Formatierung (SWE 4.4.3, Google)

- Ein Regelblock pro Selektor-Gruppe; öffnende `{` in derselben Zeile.
- Jede Deklaration in eigener Zeile, mit Semikolon am Ende (auch der letzten).
- Ein Leerzeichen nach `:` und vor `{`.
- Kurzschreibweisen nur wenn alle Werte bewusst gesetzt sind (`margin: 0 1rem`, nicht unklar verkürzen).
- Vendor-Prefixes vermeiden, sofern Build-/Browserziele sie nicht erzwingen; sonst Autoprefixer.
- Reihenfolge innerhalb einer Datei (empfohlen): Tokens → Reset/Base → Layout → Komponenten → Utilities → Media Queries.

```css
/* ✅ GUT */
.site-header {
  display: flex;
  align-items: center;
  gap: var(--space-md);
  background-color: var(--color-surface);
}

/* ❌ SCHLECHT */
.site-header{display:flex;align-items:center;background:#fff}
```

---

## CSS – Layout, Motion, Performance

- Layout bevorzugt mit **Flexbox** / **Grid**; Floats nur für Legacy-Ausnahmen.
- Animationen und Transitions nur über `transform` und `opacity` (keine Layout-Thrashing-Properties wie `top`/`height` animieren).
- Dauer und Easing über Tokens oder benannte Konstanten, keine verstreuten Magic Numbers.
- `prefers-reduced-motion: reduce` muss Bewegung deaktivieren:

```css
@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}
```

- Große Hintergrundbilder und ungenutztes CSS vermeiden; kritisches CSS nur gezielt inlinen.
- `will-change` sparsam und temporär einsetzen.

---

## Kommentare (SWE 4.4.5)

- Kommentare erklären das **Warum**, nicht das Was.
- Abschnitts-Trenner in großen Stylesheets erlaubt, ohne dekorative ASCII-Boxen.
- Auskommentierten Totcode entfernen – nicht liegen lassen.
- TODO nur mit Ticket-Referenz: `/* TODO: JIRA-1234 – Replace legacy grid fallback. */`

---

## Tests & Qualitätssicherung (SWE 4.4.11 / 4.4.9)

- W3C-HTML- und W3C-CSS-Validierung bei relevanten Änderungen (CI-Gate wo vorhanden).
- Manuelle Checks: Tastaturbedienung, Screenreader-Spotcheck kritischer Flows, Mobile-Viewport.
- Visuelle Regression / Lighthouse / Performance-Budgets gemäß Projekt-CI.
- Keine „Testing in Compliance“-Checkboxen ohne Aussagekraft.
- Single Responsibility: große Templates und CSS-Dateien in nachvollziehbare Partials/Sektionen teilen.
- Keine God-Stylesheets ohne Struktur; keine God-Templates mit vermischter Präsentationslogik.

---

## Sicherheit & Content

- Kein unescaped User-Content in HTML (XSS); serverseitig bzw. Template-Engine escapen.
- Externe Scripts nur über HTTPS und nach Projekt-Consent-/CSP-Regeln.
- `target="_blank"` stets mit `rel="noopener noreferrer"`.
- Keine Secrets, Tokens oder internen URLs in Markup/CSS.

---

## Bibliotheken / Lizenzen (SWE 4.5)

Nur kommerziell nutzbare Lizenzen erlaubt: MIT, Apache 2.0, BSD, ISC, MPL 2.0, LGPL (dynamic linking).  
**Verboten:** GPL v2/v3, AGPL (ohne explizite Freigabe durch GEF).  
Neue CSS-/UI-Bibliotheken, Icon-Sets und Fonts erfordern eine dokumentierte Lizenz-Einzelprüfung.

---

## Kurz-Checkliste vor Commit

- [ ] Semantik und eine saubere Heading-Hierarchie
- [ ] `lang`, Meta-Viewport, sinnvolle `alt`-Texte
- [ ] Labels + Tastaturfokus bei Formularen/Controls
- [ ] Tokens statt Magic Values; BEM-light-Klassennamen
- [ ] `prefers-reduced-motion` beachtet
- [ ] W3C-/Stylelint-Checks grün
- [ ] `author` = aktuelles `git config user.name`
- [ ] Change-Log im Datei-Header aktualisiert
