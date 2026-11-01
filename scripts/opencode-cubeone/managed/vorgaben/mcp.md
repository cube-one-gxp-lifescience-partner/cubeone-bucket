---
titel: MCP-Server
pfade:
  - "**/*mcp*"
---
# MCP-Server

HTTP und stdio sind zwei Transporte derselben Rollenprüfung. HTTP-Clients nutzen nur `https://<anwendung>/mcp`. `python -m <paket>.mcp` bleibt stdio und bindet keinen Port. Der Server ist dieselbe Anwendung, mit demselben Icon. Es gibt kein zweites API und keine eigene Datenbank.

## Routen

Der HTTP-Einstieg verarbeitet die Anfrage, bevor der Anwendungskörper gelesen wird, und gibt die Anfrage an die Anwendung zurück, wenn der Pfad nicht hierher gehört.

- `GET /.well-known/oauth-protected-resource` und `.../mcp`
- `GET /.well-known/oauth-authorization-server`
- `POST /oauth/register`, `GET` und `POST /oauth/authorize`, `POST /oauth/token`, `POST /oauth/revoke`
- `POST /mcp`, `GET /api/mcp-grants`, `POST /api/mcp-grants`
- `OPTIONS` auf diesen Pfaden: 204, `WWW-Authenticate` und `Mcp-Session-Id` sind freigegeben

`/mcp` ohne Bearer-Token antwortet 401 mit `WWW-Authenticate: Bearer realm="<dienst>", resource_metadata="{basis}/.well-known/oauth-protected-resource/mcp"`. Nach der Anmeldung ist `GET /mcp` 405 und `DELETE /mcp` 204. Eine Methode, die mit `notifications/` beginnt, antwortet 202 ohne Body.

## OAuth

Die Anwendung ist der Authorization Server. Clients sind öffentlich, `token_endpoint_auth_method=none`, PKCE nur `S256`, ein Scope `mcp`. Die Ressource ist exakt `{basis}/mcp`, ohne Schrägstrich am Ende. Die Basis kommt aus `Host` und `X-Forwarded-Proto: https`. Fehlt das Proto-Feld, wird der Aussteller `http://` und die Prüfung gegen die gespeicherte `https://`-Ressource scheitert.

`POST /oauth/register` vergibt `mcp_` plus `token_urlsafe(24)`. Ein Redirect ist `https`, Loopback-`http` (`127.0.0.1`, `localhost`, `::1`) oder ein privates Schema. `javascript`, `data`, `file`, Fragmente und Userinfo sind ausgeschlossen. Ein `client_id`, der mit `https://` beginnt, ist ein Metadaten-Dokument: die URL hat einen Pfad, leitet nicht um und zeigt nicht auf eine private Adresse.

`GET /oauth/authorize` verlangt `response_type=code`, die Challenge `^[A-Za-z0-9_-]{43,128}$` und die Ressource. Ohne Anwendungssitzung folgt die Weiterleitung zur Anmeldung mit einem HttpOnly-Cookie für die Rückkehr, gültig 600 Sekunden. Die Rückkehradresse entspricht `^/oauth/authorize\?[A-Za-z0-9._~%&=:+/?-]{0,1800}$`. Ist die Anmeldung aus, gilt der lokale Administrator mit dem Subjekt `local`.

Die Einwilligung liegt nur im Speicher, 600 Sekunden, und die Seite ist deutsch. Sie nennt die Rollenbezeichnung und die erlaubten Werkzeuge. `POST /oauth/authorize` enthält nur `consent` und `decision` und prüft die ursprüngliche Anfrage nicht erneut als vollständiges OAuth-Formular. `decision` ist `approve`, sonst `access_denied`. Subjekt und Rolle passen noch zur Sitzung.

Der Code beginnt mit `mcp_code_`, gilt 300 Sekunden und ist einmalig. Access-Token `mcp_at_` gelten 3600 Sekunden, Refresh-Token `mcp_rt_` 30 Tage. Gespeichert wird der SHA-256. Klartext und Logs enthalten den Token nicht. Ein Refresh widerruft das alte Refresh-Token und gibt ein neues Paar aus. Die Rolle steht auf der Genehmigung und wird beim Ausstellen und Erneuern von dort gelesen. `POST /oauth/revoke` antwortet 200 und leer.

## Rollen und Werkzeuge

Die Genehmigung speichert die Rolle der Anwendung. `tools/list` zeigt nur Werkzeuge, deren Mindestrolle die Genehmigung erfüllt. `tools/call` prüft die Aktion danach erneut serverseitig, auch wenn die Anmeldung der Oberfläche aus ist. Ein verstecktes Werkzeug ist keine Prüfung. Für den HTTP-Aufruf gilt die Rolle des Aufrufers vor einem statischen Zugriffstoken.

Jedes Werkzeug nennt seine Aktion und die Mindestrolle. Ein Werkzeug für die Anmeldung nimmt kein Client-Geheimnis an. Ein verweigerter Aufruf liefert Text, der mit `Fehler:` beginnt, und `isError: true`. Protokollversionen sind `2024-11-05`, `2025-03-26` und `2025-06-18`. Der Servername in der Initialize-Antwort ist der Name der Anwendung.

## Speicher

Die OAuth-Datei liegt im Datenvolume der Anwendung, heißt `.mcp-oauth.json` und hat den Modus `0600`. Tests dürfen den Pfad über eine Umgebungsvariable setzen. Eine Auslieferung liefert keine Datei aus, deren Pfadteil mit einem Punkt beginnt. Clients, Codes, Grants und Token-Hashes liegen in dieser Datei. `.env` und die Anmeldedatei der Anwendung bleiben eigene Dateien und bleiben außerhalb des Repository.

Die Oberfläche zeigt `location.origin + "/mcp"` und die Genehmigungen der aktuellen Sitzung. Das Widerrufen einer Genehmigung trifft nur das Subjekt dieser Sitzung.

## Nicht ändern

Nach einem abgelaufenen Container löscht die Weiterleitung die Client-ID im Client. Der Server stellt eine verlorene ID nicht wieder her. Der Client registriert sich neu. Der Host der Anwendung steht in der Domain-Freigabe des Clients, sonst endet die Prüfung mit `Domain is not allowed` und `inspectionFailed` bleibt im Config-Cache. Ein erneutes Initialisieren wiederholt diese Prüfung nicht. Die Serverkonfiguration muss neu gespeichert werden.
