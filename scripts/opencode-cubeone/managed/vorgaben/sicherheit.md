---
titel: Sicherheit
pfade:
  - "**/*.sql"
  - "**/*{repo,repository,repositories}.*"
  - "**/{repo,repos,repository,repositories}"
  - "**/*session*"
  - "**/*migration*"
  - "**/*{password,passwort}*"
inhalt: "passwor[dt]|\\bselect\\b[^;]{0,200}\\bfrom\\b|\\binsert\\s+into\\b|\\bupdate\\s+\\w+\\s+set\\b|\\bdelete\\s+from\\b|\\.query\\s*\\(|\\bbcrypt\\b|\\bargon2"
---
# Sicherheit

Diese Vorgaben gelten für Produktionscode, Produktionskonfiguration und Produktionsdaten. Entwicklung und Test fallen nicht darunter.

- Passwörter nur als Argon2id oder bcrypt speichern, mit eigenem Salt je Passwort. Den Klartext nach der Prüfung verwerfen und nie protokollieren.
- API-Schlüssel, Token und Verbindungsgeheimnisse verschlüsselt speichern. Den Schlüssel außerhalb von Datenbank und Repository halten.
- Datenbankabfragen parametrisieren. Eingaben auf dem Server prüfen.
- Jede Aktion prüft auf dem Server, ob dieser Benutzer sie ausführen darf. Ein verstecktes Bedienelement reicht nicht.
- Sitzungscookies mit `HttpOnly`, `Secure` und `SameSite`. Verkehr nur über TLS.
- Zertifikatsprüfung bleibt aktiv.
- Datenbankkonten bekommen nur die Rechte, die die Anwendung braucht. Passwort-Hashes nicht an den Client ausliefern.
