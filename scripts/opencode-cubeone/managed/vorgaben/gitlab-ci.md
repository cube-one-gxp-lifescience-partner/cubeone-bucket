---
titel: GitLab CI
pfade:
  - "**/.gitlab-ci.yml"
---
# GitLab CI – Lint, Tests, Komodo (nur Webapps)

Beim Anlegen oder Ändern von `.gitlab-ci.yml` gilt diese Reihenfolge **unverändert**:

1. **Lint** (`stage: lint`)
2. **Unittests** (`stage: test`)
3. **Komodo** (`stage: deploy`) – **nur Webapps**

Keine zusätzlichen Deploy-Jobs, kein Image-Push. Komodo baut aus dem Repo.

## Runner

- Linux/Docker: `tags: [default]`
- Windows-Shell-Runner: `tags: [windows]` – nur wenn der Job wirklich Windows braucht (kein Default für Webapps)

```yaml
default:
  tags:
    - default
```

## Keine Webapp

Libraries, CLIs, Agenten, Windows-Services, Sync-Jobs, Hilfsskripte: **nur Lint + Unittests**. Kein `deploy`-Stage, kein `notify-komodo`, keine `KOMODO_*`-Variablen.

## Webapp – Pflichtgerüst

```yaml
stages:
  - lint
  - test
  - deploy

variables:
  # Komodo procedure deploy (GitLab auth) – GitLab → Settings → CI/CD → Variables (masked):
  #   KOMODO_WEBHOOK_SECRET  → sent as X-Gitlab-Token
  #   KOMODO_WEBHOOK_URL     → must use /listener/gitlab/...

default:
  tags:
    - default
```

Lint- und Test-Jobs sind projektspezifisch (`eslint`/`ruff`/`hadolint`, `pytest`/`npm test`/`phpunit`). Tests `need`en die Lint-Jobs. Kein Test vor Lint.

## Komodo-Block – immer identisch

Nur die `needs`-Liste anpassen (alle Lint- und Test-Jobs). Script, Image, Rules, Header **nicht ändern**. Kein HMAC, kein `X-Hub-Signature-256`, kein `bump-agent-version`.

```yaml
# Docs: https://komo.do/docs/automate/webhooks (gitlab auth → X-Gitlab-Token)
notify-komodo:
  stage: deploy
  image: python:3.12-slim
  timeout: 5m
  interruptible: false
  needs:
    - eslint
    - pytest
  rules:
    - if: $CI_COMMIT_MESSAGE =~ /\[skip ci\]/
      when: never
    - if: $CI_COMMIT_BRANCH == "main"
      when: on_success
  script:
    - |
      echo "Quality gates passed – notifying Komodo for ${CI_COMMIT_SHA}"
      python <<'PY'
      import json
      import os
      import sys
      import urllib.error
      import urllib.request

      secret = os.environ.get("KOMODO_WEBHOOK_SECRET")
      webhook_url = os.environ.get("KOMODO_WEBHOOK_URL")
      if not secret:
          print(
              "KOMODO_WEBHOOK_SECRET is not set "
              "(GitLab → Settings → CI/CD → Variables)",
              file=sys.stderr,
          )
          sys.exit(1)
      if not webhook_url:
          print("KOMODO_WEBHOOK_URL is not set", file=sys.stderr)
          sys.exit(1)

      release_sha = os.environ["CI_COMMIT_SHA"]
      payload = {
          "ref": f"refs/heads/{os.environ['CI_COMMIT_REF_NAME']}",
          "after": release_sha,
          "repository": {
              "id": int(os.environ["CI_PROJECT_ID"]),
              "name": os.environ["CI_PROJECT_NAME"],
              "html_url": os.environ["CI_PROJECT_URL"],
          },
      }
      body = json.dumps(payload).encode()
      req = urllib.request.Request(
          webhook_url,
          data=body,
          headers={
              "Content-Type": "application/json",
              "X-Gitlab-Token": secret,
          },
          method="POST",
      )
      try:
          with urllib.request.urlopen(req, timeout=30) as resp:
              if resp.status >= 400:
                  print(resp.read().decode(), file=sys.stderr)
                  sys.exit(1)
      except urllib.error.HTTPError as exc:
          print(exc.read().decode(), file=sys.stderr)
          sys.exit(1)
      print(f"Komodo webhook sent for commit {release_sha}")
      PY
```

## Nicht tun

- Komodo vor oder parallel zu Lint/Tests
- eigenen Deploy-Job statt `notify-komodo`
- Komodo-Script umschreiben oder Auth mischen
- Windows-Tag auf Linux/Docker-Jobs
