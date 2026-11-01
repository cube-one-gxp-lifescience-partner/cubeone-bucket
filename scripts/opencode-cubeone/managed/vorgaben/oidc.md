---
titel: OIDC
pfade:
  - "**/*auth*"
  - "**/*oidc*"
  - "**/*oauth*"
---
# OIDC

Anwendungen müssen mindestens OIDC via Keycloak unterstützen, falls nicht schon implementiert oder falls keine Benutzeranmeldung vorgesehen ist.

Die Anwendung prüft das Token serverseitig. Eine Rolle aus der Oberfläche oder aus einem unsignierten Claim gilt nicht. Zertifikatsprüfung bleibt an. Geheimnisse liegen außerhalb von Git, Logs und Client-Code.

## Aussteller

Der Issuer ist exakt die `issuer`-Zeile aus der Discovery, Schema `https`, ohne Schrägstrich am Ende: `https://<host>/realms/<realm>`. Die Discovery-URL ist `{issuer}/.well-known/openid-configuration`. Ein GET darauf antwortet `200` mit `application/json`. Ein `302` auf eine Bot-Challenge ist ein Fehler. `HEAD` reicht als Prüfung nicht, weil die Challenge oft nur `GET` trifft.

Hinter einem Proxy setzt die Anwendung `X-Forwarded-Proto: https` und `X-Forwarded-Host`. In Keycloak gelten `KC_PROXY_HEADERS=xforwarded` und ein öffentlicher Hostname. Fehlt das Proto-Feld, wird der Aussteller `http://` und die Prüfung gegen den gespeicherten `https://`-Issuer scheitert.

Diese Pfade bleiben für Aufrufe ohne Browser-Cookie frei von Bot-Challenge und Zwangsredirect, weil der Client sie selbst abruft:

- `/.well-known/openid-configuration`
- `/.well-known/oauth-authorization-server`
- `/protocol/openid-connect/token`
- `/protocol/openid-connect/certs`
- `/protocol/openid-connect/userinfo`
- `/protocol/openid-connect/introspect`
- `/protocol/openid-connect/revoke`
- `/protocol/openid-connect/logout`

## Client

Der Flow ist Authorization Code. Öffentliche Clients, auch SPAs, nutzen PKCE `S256`. Vertrauliche Clients nutzen ein Client-Geheimnis oder Private Key JWT. Die Methode steht auf beiden Seiten gleich: `client_secret_basic` oder `client_secret_post`.

Die Redirect-URI ist exakt eingetragen, Schema `https`, Loopback-`http` nur für lokale Entwicklung. Dieselbe Strenge gilt für die Post-Logout-Redirect-URI. Web Origins enthalten die Browser-Herkunft, wenn der Browser den Token-Endpunkt selbst ruft.

Scopes enthalten `openid`. Dazu `profile` und `email`, wenn die Anwendung Name oder E-Mail liest. Ohne `openid` gibt es kein ID-Token.

## Rollen im Token

Die Anwendung liest die Rolle aus dem Access-Token, das sie selbst geprüft hat. Realm-Rollen stehen in `realm_access.roles`, Client-Rollen in `resource_access.<client>.roles`. Beides sind Arrays. Die Anwendung legt einen dieser Pfade fest und liest nur den.

In Keycloak hängt der Client-Scope `roles` am Client, als Default-Scope, nicht als optionaler Scope, den der Client vergessen kann. Der Realm-Roles-Mapper und der Client-Roles-Mapper schreiben in das Access-Token und in das ID-Token. Ist das Lightweight Access Token an, steht zusätzlich „Include in lightweight access token“ am Mapper. Sonst fehlt die Rolle im Token, obwohl sie in der Admin-Konsole am Benutzer hängt.

`aud` enthält den Client der API. Dafür gibt es einen Audience-Mapper. `azp` ist der anfragende Client und ersetzt die Zielgruppe nicht. Die E-Mail steht im Token nur mit Scope `email` und dem E-Mail-Mapper auf Access-Token und ID-Token.

„Full scope allowed“ bleibt aus, wenn der Client nur seine eigenen Rollen sehen soll. Composite Roles lösen sich im Token in die enthaltenen Rollen auf. Die Anwendung prüft den Rollennamen aus dieser Liste.

## Prüfung

Der Resource Server prüft Signatur über `jwks_uri` aus der Discovery, `iss`, `aud`, `exp` und `nbf`. Erlaubt ist `RS256`. Der Token-Endpunkt ist `POST` mit `application/x-www-form-urlencoded`. Der Authorization Code ist einmalig. Ein Refresh widerruft das alte Refresh-Token, wenn Rotation an ist.

Jede Aktion prüft die Rolle aus dem geprüften Token erneut. Ein verstecktes Bedienelement reicht nicht. Sitzungscookies der eigenen Anwendung bleiben `HttpOnly`, `Secure` und `SameSite`.

Direct Access Grants und der Implicit Flow bleiben aus.
