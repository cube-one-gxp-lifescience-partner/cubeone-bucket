---
titel: Docker Coding Standards
pfade:
  - "**/Dockerfile*"
  - "**/*.Dockerfile"
  - "**/docker-compose*.yml"
  - "**/docker-compose*.yaml"
  - "**/compose*.yml"
  - "**/compose*.yaml"
---
# Docker-Standards - cube one GmbH

## Normative Grundlage

- **Docker Building Best Practices** (https://docs.docker.com/build/building/best-practices/)
- **Dockerfile reference** (https://docs.docker.com/reference/dockerfile/)
- **Multi-stage builds** (https://docs.docker.com/build/building/multi-stage/)
- **Docker build cache** (https://docs.docker.com/build/cache/)
- **Compose Specification** (https://docs.docker.com/reference/compose-file/) – empfohlenes File-Format (v2/v3 legacy merged)
- **How Compose works** (https://docs.docker.com/compose/intro/compose-application-model/)
- **Multiple Compose files** (https://docs.docker.com/compose/how-tos/multiple-compose-files/)
- **Twelve-Factor App – Processes** (https://12factor.net/processes) – ephemeral containers
- **cube one SWE Guideline V2, Kapitel 4** (Dok-ID: 4CAF90EDCA7592FECC3A95BA15633141)
- Dockerfile syntax directive: `# syntax=docker/dockerfile:1` (aktuell; BuildKit-Features)
- Compose CLI: **`docker compose`** (V2 Plugin; nicht legacy `docker-compose` Binary)

RFC-2119-Schlüsselwörter (`MUST` / `MUST NOT` / `SHOULD` / …) gelten in diesem Dokument, soweit unten übernommen.
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

## Docker Best-Practice Essentials (extrahiert)

Die folgenden Regeln sind die für den Alltag verbindlichen Vorgaben aus den Docker Building Best Practices. Details und Ausnahmen: Originaldocs auf docs.docker.com.

### Multi-stage Builds

1. Builds **SHOULD** Multi-stage nutzen, um Build-Tools von der Runtime zu trennen.
2. Die finale Stage **MUST** nur Dateien enthalten, die zur Laufzeit nötig sind.
3. Gemeinsame Schritte in wiederverwendbare Stages auslagern (DRY); derivative Stages basieren darauf.
4. Parallelisierbare Stages nutzen, wo Build-Zeit kritisch ist.

### Base Images

1. Base Images **MUST** aus vertrauenswürdiger Quelle stammen:
   - Docker Official Images
   - Verified Publisher
   - Docker-Sponsored Open Source
2. Möglichst **kleine** Bases wählen (weniger Angriffsfläche, schnellere Pulls).
3. Build-/Test-Image und Production-Image **SHOULD** getrennt sein (schlanke Runtime).
4. Tags sind mutable – für Supply-Chain-Integrität Digest-Pinning **SHOULD**:
   `FROM alpine:3.21@sha256:…`
5. Images regelmäßig neu bauen (`docker build --pull`; bei Bedarf `--no-cache`).

### Ephemeral Containers & Decoupling

1. Container **MUST** möglichst ephemeral sein (stoppen/zerstören/ersetzen mit minimalem Setup).
2. Ein Container = eine Concern (Web, DB, Cache getrennt skalierbar).
3. „Ein Prozess pro Container“ ist Faustregel, keine harte Regel (Init/Worker-Prozesse ok).
4. Keine unnötigen Packages nur „weil nice to have“.

### Build Context & Cache

1. Irrelevanten Context über `.dockerignore` ausschließen (analog `.gitignore`).
2. Instruction-Reihenfolge so wählen, dass der Build-Cache maximal greift (selten Änderndes zuerst).
3. Multi-line Argumente alphanumerisch sortieren; Space vor `\`.

---

## Docker Compose Essentials (extrahiert)

Die folgenden Regeln gelten für Compose-Dateien gemäß Compose Specification und Docker Docs. Details: docs.docker.com / compose-spec.

### Dateiname & Spec

1. Kanonischer Dateiname: **`compose.yaml`** (bevorzugt) oder `compose.yml`.
2. Legacy-Namen `docker-compose.yaml` / `docker-compose.yml` nur bei bestehendem Projektbedarf; wenn beide existieren, gewinnt `compose.yaml`.
3. **Kein** top-level `version:`-Key – Legacy; Compose Specification braucht ihn nicht.
4. CLI: immer **`docker compose …`** (Compose V2), nicht `docker-compose`.

### Application Model

1. **Services** = lauffähige Komponenten (Image + Config, ggf. skaliert).
2. **Networks** = Isolation / Kommunikationspfade zwischen Services.
3. **Volumes** = persistente Daten (named volumes für DB/State).
4. **Configs** = nicht-sensible Runtime-Konfiguration (als Datei gemountet).
5. **Secrets** = sensible Daten (als Datei gemountet; Plattform-/Secret-Store).
6. **Project name** (`name:` top-level oder `-p` / `COMPOSE_PROJECT_NAME`) gruppiert und isoliert Ressourcen.

### Multi-file / Modularisierung

1. Basis + Override: `compose.yaml` + `compose.override.yaml` (automatisch gemerged lokal) oder explizit `-f`.
2. Environment-spezifisch: `compose.prod.yaml`, `compose.ci.yaml` – per `-f` mergen.
3. Wiederverwendung: `include:` oder `extends:` statt Copy-Paste großer Stacks.
4. Merge-Regeln kennen: Maps/Scalars überschreiben; Listen werden appended; relative Pfade relativ zur **ersten** Compose-Datei.

### Services – verbindliche Praxis

1. Ein Service = eine Concern (wie Decoupling bei Containern).
2. Images **pinning**: konkrete Tags (kein `latest`); Production **SHOULD** Digest.
3. Service-zu-Service-Kommunikation über **Service-Namen** als Hostname – nie `localhost` für andere Container.
4. `depends_on` mit **Health-Condition**, wo Startreihenfolge kritisch ist:

```yaml
depends_on:
  db:
    condition: service_healthy
```

5. Jeder langlebige Service **SHOULD** einen `healthcheck` haben.
6. Ports nur publishen, was von außen nötig ist; interne Services nur am Netzwerk hängen.
7. Resource Limits (`deploy.resources` / `mem_limit` je nach Engine) setzen, wo Host-Schutz nötig ist.
8. `restart`-Policy bewusst wählen (`unless-stopped` / `on-failure`), nicht unreflektiert `always`.

### Env, Interpolation, Secrets

1. Konfiguration über Interpolation (`${VAR}`) und `.env` / `--env-file` – **nicht** hartcoden.
2. `.env` für lokale Defaults; **MUST NOT** Secrets committen (`.env` in `.gitignore`; `.env.example` ohne Geheimnisse).
3. Nicht-sensible Settings: `environment:` / `env_file:`.
4. Secrets: Compose `secrets:` (oder Vault/Plattform-Secrets) – **MUST NOT** Passwörter/API-Keys als Klartext in YAML.
5. cube-one Binding: Secrets nur per Referenz (`endpoint_ref` / Env / Vault) – nie URLs/Tokens in DB oder Compose-Repo.

### Networks & Volumes

1. Explizite Networks für Tier-Trennung (`front-tier` / `back-tier`), wo Isolation sinnvoll ist.
2. Persistenz über **named volumes**, nicht anonyme Volumes für produktive Daten.
3. Bind-Mounts primär für Dev (Source-Code); Production eher Image-Inhalt + Volumes für State.

---

## Sprache (SWE 4.4.1)
- Ausschließlich **Englisch** in Kommentaren, Stage-Namen, Labels, ENV-Keys und Skripten im Image.
- Keine deutschen Strings in Dockerfiles / Entry-Skripten – UI über i18n / Content-Dateien der App.
- UTF-8 ohne BOM; Zeilenenden **LF** only.

---

## Datei-Header (SWE 4.4.5)

Jede nicht-triviale Dockerfile beginnt mit Header-Kommentar **vor** den Instructions (nach optionalem `# syntax=`):

```dockerfile
# syntax=docker/dockerfile:1
#
# company: cube one GmbH
# name: Dockerfile
# author: Marvin Fenßel
# created: DD.MM.YYYY
# change log: DD.MM.YYYY – Initial implementation.
#

FROM alpine:3.21
```

- `author:` = Ausgabe von `git config user.name` (Beispielwert oben nur illustrativ – immer frisch aus Git lesen).
- Jede relevante Änderung in `change log` (Datum, Autor aus `user.name`, Beschreibung).
- Git-History ersetzt **nicht** den Change-Log-Eintrag im Header.

`.dockerignore`, Compose-Dateien und Entry-Skripte erhalten analoge Header (Shell-Header gemäß Bash-Standards).

### Compose-Header

```yaml
# company: cube one GmbH
# name: compose.yaml
# author: Marvin Fenßel
# created: DD.MM.YYYY
# change log: DD.MM.YYYY – Initial local stack.
#

name: cube-shop

services:
  shop:
    image: dockware/dev:6.6.10.2
```

---

## Linting & Formatting (SWE 4.4.3)

### Tooling (verbindlich)

| Zweck | Tool | Hinweis |
|-------|------|---------|
| Lint / CI-Gate | **Hadolint** | Dockerfile Best Practices / ShellCheck-Integration |
| Editor / DX | **Docker DX** (VS Code / Cursor) | Linting, Navigation, Vulnerability Hints |
| Compose validate | **`docker compose config`** | Render + Syntax; CI-Gate Pflicht |
| Compose dry-run | **`docker compose config --quiet`** | Exit ≠ 0 bei Fehlern |
| Image-Scan (empfohlen) | Docker Scout / Trivy | Base-Image & CVE-Status |

- Keine offenen Hadolint-Findings in CI ohne dokumentierte `# hadolint ignore=DLxxxx` + Begründung.
- Lokal vor jedem Commit: `hadolint Dockerfile` und `docker compose config`.

### Formatierung – Dockerfile

- Indent: **2 Spaces** für Fortsetzungszeilen (kein Tab).
- Soft Limit **100** Zeichen; lange `RUN`/`LABEL`-Listen umbrechen.
- Kein trailing Whitespace; Datei endet mit genau einem LF.
- Keywords uppercase: `FROM`, `RUN`, `COPY`, `CMD`, … (Dockerfile-Konvention).
- Stage-Namen: `kebab-case` oder `snake_case`, beschreibend: `AS builder`, `AS runtime`.

### Formatierung – Compose (YAML)

- Indent: **2 Spaces** (kein Tab); konsistent mit Google HTML/CSS / YAML-Praxis.
- Soft Limit **100** Zeichen; lange Listen umbrechen.
- Maps alphabetisch oder logisch gruppiert (Image/Build → Env → Ports → Volumes → Networks → Health → Depends).
- Quotes nur wo nötig (Ports `"8002:8002"`, Strings mit Sonderzeichen).
- Boolean/Null YAML-native: `true` / `false` / `null`.
- Kein legacy `version:`-Key.
- Fragments (`x-` Extensions / YAML anchors) sparsam und dokumentiert für DRY.

### CLI

```bash
hadolint Dockerfile
docker build --pull -t cube-shop:local .
docker compose config
docker compose -f compose.yaml -f compose.prod.yaml config
docker compose up -d
docker compose ps
docker compose logs -f --tail=100
docker compose down
```

---

## Naming (SWE 4.4.2)

| Element | Stil | Beispiel |
|---------|------|----------|
| Dockerfile-Dateiname | `Dockerfile` oder `Dockerfile.<purpose>` | `Dockerfile`, `Dockerfile.ci` |
| Compose-Dateiname | `compose.yaml` (+ Override) | `compose.yaml`, `compose.prod.yaml` |
| Stage-Namen | `kebab-case` / beschreibend | `AS builder`, `AS runtime` |
| Image-Tags | SemVer / Zweck + Digest wo nötig | `6.6.10.2`, `sha256:…` |
| Labels | reverse-DNS / OCI | `org.opencontainers.image.title` |
| ENV / ARG Keys | `UPPER_SNAKE_CASE` | `SHOP_DOMAIN`, `APP_VERSION` |
| Scripts im Image | `kebab-case.sh` | `install-plugins.sh` |
| Compose project `name` | `kebab-case` | `cube-shop` |
| Compose-Services | `kebab-case` | `shop`, `mysql`, `redis` |
| Networks / Volumes | `kebab-case` | `front-tier`, `db-data` |
| Secrets / Configs | `kebab-case` | `db-password`, `httpd-config` |
---

## Dockerfile-Instructions (verbindlich)

### `# syntax=` / `FROM`

- Jede Dockerfile **SHOULD** mit `# syntax=docker/dockerfile:1` starten (BuildKit).
- `FROM` **SHOULD** Official / Verified / Sponsored Images nutzen; wo möglich schlanke Bases.
- Digest-Pinning für reproduzierbare Production-Builds **SHOULD**.

```dockerfile
# syntax=docker/dockerfile:1
FROM alpine:3.21@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c AS runtime
```

### `LABEL`

- OCI-Labels setzen (`org.opencontainers.image.*`) für Title, Description, Vendor, Source, Version.
- cube one: mindestens `title`, `description`, `vendor="cube one GmbH"`.

```dockerfile
LABEL org.opencontainers.image.title="cube-shop.de"
LABEL org.opencontainers.image.description="Shopware 6.6 with CubeShop plugins"
LABEL org.opencontainers.image.vendor="cube one GmbH"
```

### `RUN`

- Lange / komplexe `RUN`s umbrechen; Befehle mit `&&` ketten.
- Multi-line Paketlisten **alphanumerisch** sortieren.
- `apt-get update` und `apt-get install` **MUST** in **derselben** `RUN`-Zeile stehen (Cache-Busting).
- `--no-install-recommends` nutzen; danach `rm -rf /var/lib/apt/lists/*`.
- Pipes: `set -o pipefail` (bzw. Exec-Form mit Bash, wenn Shell kein `pipefail` kennt).
- Temporäre Build-Dateien lieber via Bind-Mount (`RUN --mount=type=bind,…`) statt dauerhaftem `COPY`, wenn sie nicht im finalen Image bleiben sollen.

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*
```

```dockerfile
# ❌ SCHLECHT – getrenntes update → stale cache
RUN apt-get update
RUN apt-get install -y curl
```

### `CMD` / `ENTRYPOINT`

- `CMD` **SHOULD** Exec-Form: `CMD ["executable", "arg"]`.
- `ENTRYPOINT` für das Hauptkommando; `CMD` für Default-Flags.
- Entry-Helper-Skripte: `exec` nutzen, damit die App PID 1 wird und Signale erhält.
- Selten: `CMD ["param"]` nur mit bewusstem `ENTRYPOINT`-Verständnis.

```dockerfile
ENTRYPOINT ["s3cmd"]
CMD ["--help"]
```

### `COPY` vs `ADD`

- Standard: **`COPY`** (Context → Image oder Stage → Stage).
- **`ADD`** nur wenn Remote-URL-Download und/oder Auto-Extract bewusst nötig (inkl. `--checksum` wo möglich).
- Kein `ADD` für lokale Dateien „aus Gewohnheit“.

### `ENV` / `ARG`

- Versionsnummern und wiederkehrende Werte über `ARG`/`ENV`, nicht hardcoden.
- Secrets **MUST NOT** als `ENV` im Image landen (Layer-Historie); Build-Secrets / Runtime-Env / Vault.
- Temporäre Shell-Variablen in **einer** `RUN`-Layer setzen/nutzen/unsetzen (`export … && …`), nicht nur `ENV` + späteres `unset`.

### `EXPOSE` / `VOLUME` / `WORKDIR` / `USER`

- `EXPOSE`: konventionelle / dokumentierte App-Ports.
- `VOLUME`: mutable / user-serviceable Pfade (DB-Daten, Config).
- `WORKDIR`: **immer absolute** Pfade; kein `RUN cd … && …`-Wirrwarr.
- `USER`: Non-root, wenn der Service ohne Privilegien lauffähig ist; explizite UID/GID wo nötig; `useradd --no-log-init`.
- Kein `sudo` im Image; Alternativen wie `gosu` nur bei begründetem Drop-Privileges-Pattern.
- `USER` nicht ständig hin- und herschalten.

### `ONBUILD`

- Sparsam; Images mit `ONBUILD` **MUST** eigenen Tag bekommen (`*-onbuild`).
- `ADD`/`COPY` in `ONBUILD` vorsichtig – fehlender Context bricht Child-Builds.

---

## `.dockerignore`

Jedes Image-Build-Repo **MUST** eine `.dockerignore` haben, die mindestens ausschließt:

```plaintext
.git
.cursor
*.md
docs
**/node_modules
**/vendor
**/.env
**/.env.*
**/var/cache
**/var/log
```

Anpassen je Projekt; Secrets und lokale IDE-Artefakte immer ausschließen.

---

## Sicherheit

- Keine Secrets, Tokens, Private Keys in Dockerfile, Image-Layern, Build-Context oder Compose-YAML (Binding Decision: Secrets nur per Referenz / Env / Vault / `secrets:`).
- `.env` mit Geheimnissen **MUST NOT** committed werden; nur `.env.example` ohne Secrets.
- Non-root Runtime wo möglich; Ports und Networks so eng wie nötig exponieren.
- Regelmäßig rebuilden (`--pull`); CVEs in Bases zeitnah adressieren.
- Nur erlaubte Lizenzen in Base-/Zusatzpaketen (SWE 4.5): MIT, Apache 2.0, BSD, ISC, MPL 2.0, LGPL (dynamic). **Verboten:** GPL v2/v3, AGPL ohne GEF-Freigabe.
- Production: getestete Images/Stacks; nie ungetestete Plugin-/Image-Änderungen direkt live.

---

## CI / Rebuild

- Jeder Push/PR **SHOULD** Image und Compose-Config prüfen (GitHub Actions o. ä.).
- CI-Mindestgate: `hadolint` + `docker compose config` (+ optional Stack-Smoke).
- Frische Bases: `docker build --pull …`
- Saubere Dependency-Rebuilds: `docker build --no-cache …` (gezielt, nicht default lokal).
- Kombiniert für Full Refresh: `docker build --pull --no-cache -t my-image:tag .`

---

## Formatierungsbeispiele

```dockerfile
# syntax=docker/dockerfile:1
#
# company: cube one GmbH
# name: Dockerfile
# author: Marvin Fenßel
# created: 27.07.2026
# change log: 27.07.2026 – Initial multi-stage runtime image.
#

FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/app ./cmd/app

FROM alpine:3.21 AS runtime
RUN addgroup -S app && adduser -S -G app app
WORKDIR /app
COPY --from=builder /out/app /app/app
USER app
EXPOSE 8080
ENTRYPOINT ["/app/app"]
```

```dockerfile
# ✅ GUT – apt update+install zusammen, sortiert, Cache bereinigt
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
  && rm -rf /var/lib/apt/lists/*

# ❌ SCHLECHT
RUN apt-get update
RUN apt-get install -y curl git vim emacs
USER root
USER app
USER root
```

(`author` erneut nur Beispiel – Wert aus `git config user.name`.)

### Compose-Beispiel

```yaml
# company: cube one GmbH
# name: compose.yaml
# author: Marvin Fenßel
# created: 27.07.2026
# change log: 27.07.2026 – Initial local multi-service stack.
#

name: cube-shop

services:
  shop:
    image: dockware/dev:6.6.10.2
    ports:
      - "${APP_PORT:-8002}:8002"
    environment:
      SHOP_DOMAIN: ${SHOP_DOMAIN:-localhost:8002}
    env_file:
      - path: .env
        required: false
    volumes:
      - shop-db:/var/lib/mysql
    networks:
      - front-tier
      - back-tier
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:8002"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s
    restart: unless-stopped

  redis:
    image: redis:7.4-alpine
    networks:
      - back-tier
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    restart: unless-stopped

networks:
  front-tier: {}
  back-tier: {}

volumes:
  shop-db:
```

```yaml
# ✅ GUT – pinned image, health + depends_on condition, no secrets in file
services:
  api:
    image: ghcr.io/cube-one/api:1.2.3
    environment:
      DB_HOST: db
    secrets:
      - db-password
    depends_on:
      db:
        condition: service_healthy

# ❌ SCHLECHT – latest, plaintext secret, localhost to sibling, no health
services:
  api:
    image: api:latest
    environment:
      DB_PASSWORD: "SuperSecret123"
      DB_HOST: localhost
```

---

## Kommentare (SWE 4.4.5)

- Kommentare erklären **Warum** (z. B. warum `USER` nicht überschrieben wird, warum ein Port gewählt wurde, warum ein Override-File existiert).
- Kein Totcode; TODO nur mit Ticket: `# TODO: JIRA-1234 – Pin base digest after Scout policy is enabled.`

---

## Tests (SWE 4.4.11)

- Smoke: Container startet, Healthcheck/Port antwortet, erwarteter Process läuft.
- Compose: `docker compose config` in CI; Stack lokal mit realistischer `.env` (ohne echte Secrets).
- Abhängigkeiten über Healthchecks verifizieren (`depends_on: condition: service_healthy`).
- Hadolint + `docker compose config` in derselben Quality-Gate-Pipeline wie App-Code.

---

## Kurz-Checkliste vor Commit

### Dockerfile

- [ ] `# syntax=docker/dockerfile:1` (wo BuildKit genutzt wird)
- [ ] Header: `author` = aktuelles `git config user.name`, Change-Log aktualisiert
- [ ] Vertrauenswürdige, möglichst kleine Base; Digest-Pinning wo Production es verlangt
- [ ] Multi-stage / keine Build-Tools in der Runtime-Stage
- [ ] `.dockerignore` vorhanden; keine Secrets im Context
- [ ] `apt-get update && install` in einer `RUN`; Listen sortiert; Cache gelöscht
- [ ] `COPY` statt unnötigem `ADD`; absolute `WORKDIR`; Non-root wo möglich
- [ ] `hadolint` grün; Image in CI gebaut/getestet

### Compose

- [ ] Dateiname `compose.yaml` (oder bewusstes Legacy + dokumentiert)
- [ ] Kein legacy `version:`-Key; Header + Change-Log aktuell
- [ ] Images gepinnt (kein `latest`); Service-DNS statt `localhost`
- [ ] Healthchecks + `depends_on` mit `condition: service_healthy` wo nötig
- [ ] Env via `.env` / Interpolation; Secrets nicht in YAML committed
- [ ] Named volumes für Persistenz; Networks bewusst getrennt
- [ ] `docker compose config` grün; Stack-Smoke getestet

### Allgemein

- [ ] Englisch in Kommentaren/Labels/Keys; LF; keine Magic Secrets
