import { createServer } from "node:http"
import {
  INTEGRATION_ID,
  NOTE,
  REDIRECT_PATH,
  authorizeUrl,
  baseUrl,
  codeFrom,
  credential,
  formatIssue,
  formatList,
  issueId,
  listQuery,
  pkce,
} from "./redmine.js"

const LOGIN_MS = 5 * 60_000
const DEFAULT_SCOPES = ["view_project", "search_project", "view_issues", "view_private_notes", "view_checklists", "view_wiki_pages", "view_changesets"]

const DONE_PAGE = `<!doctype html><html lang="de"><meta charset="utf-8"><title>cube project</title>
<body style="font-family:Inter,system-ui,sans-serif;background:#F5F3F0;color:#1A1A1A;display:grid;place-items:center;height:100vh;margin:0">
<div style="background:#fff;border:1px solid #e5e1da;border-radius:14px;padding:32px 40px;box-shadow:0 1px 3px rgba(0,0,0,.06)">
<h1 style="font-size:20px;font-weight:600;letter-spacing:-.025em;margin:0 0 8px">MESSAGE</h1>
<p style="font-size:14px;margin:0;color:#5A5A5A">Du kannst dieses Fenster schließen und zu OpenCode zurückkehren.</p></div></body></html>`

function page(res, status, message) {
  res.writeHead(status, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" })
  res.end(DONE_PAGE.replace("MESSAGE", message))
}

async function json(response, what) {
  const text = await response.text()
  let body
  try {
    body = text ? JSON.parse(text) : {}
  } catch {
    body = undefined
  }
  if (!response.ok) {
    const detail = body?.error_description || body?.error || body?.errors?.join?.(", ") || `HTTP ${response.status}`
    const error = new Error(`${what}: ${detail}`)
    error.status = response.status
    throw error
  }
  if (body === undefined) throw new Error(`${what}: Antwort ist kein JSON`)
  return body
}

export default {
  id: "cubeone-redmine",
  async setup(ctx) {
    const base = baseUrl(ctx.options?.url ?? "https://project.cubeone.de")
    const clientId = String(ctx.options?.clientId ?? "")
    const scopes = Array.isArray(ctx.options?.scopes) && ctx.options.scopes.length ? ctx.options.scopes.map(String) : DEFAULT_SCOPES
    if (!clientId) return

    const tokenRequest = async (params) =>
      json(
        await fetch(`${base}/oauth/token`, {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
          body: new URLSearchParams({ client_id: clientId, ...params }),
        }),
        "cube-project-Anmeldung",
      )

    const currentUser = async (access) => {
      try {
        const body = await json(await fetch(`${base}/users/current.json`, { headers: { authorization: `Bearer ${access}` } }), "cube project")
        return body.user
      } catch {
        return undefined
      }
    }

    const exchange = async (methodID, code, redirectUri, verifier) => {
      const token = await tokenRequest({ grant_type: "authorization_code", code, redirect_uri: redirectUri, code_verifier: verifier })
      return credential(methodID, token, await currentUser(token.access_token))
    }

    // Loopback redirect per RFC 8252: Redmine accepts any port for the registered http://127.0.0.1/callback.
    const browserLogin = async () => {
      const { verifier, challenge, state } = pkce()
      let settle
      const result = new Promise((resolve, reject) => (settle = { resolve, reject }))
      const server = createServer((req, res) => {
        const url = new URL(req.url ?? "/", "http://127.0.0.1")
        if (url.pathname !== REDIRECT_PATH) return page(res, 404, "Unbekannte Adresse")
        if (url.searchParams.get("state") !== state) return         page(res, 400, "Diese Anmeldung gehört zu einem anderen Versuch")
        const error = url.searchParams.get("error")
        const code = url.searchParams.get("code")
        if (error || !code) {
          page(res, 400, "Anmeldung abgebrochen")
          return settle.reject(new Error(url.searchParams.get("error_description") || error || "Kein Code erhalten"))
        }
        page(res, 200, "Bei cube project angemeldet")
        settle.resolve(code)
      })
      await new Promise((resolve, reject) => {
        server.once("error", reject)
        server.listen(0, "127.0.0.1", resolve)
      })
      const redirectUri = `http://127.0.0.1:${server.address().port}${REDIRECT_PATH}`
      const timer = setTimeout(() => settle.reject(new Error("Die Anmeldung ist abgelaufen")), LOGIN_MS)
      const callback = result
        .then((code) => exchange("browser", code, redirectUri, verifier))
        .finally(() => {
          clearTimeout(timer)
          server.close()
        })
      callback.catch(() => {})
      return {
        url: authorizeUrl({ base, clientId, redirectUri, scopes, challenge, state }),
        instructions: "Melde dich im Browser bei cube project an und bestätige den Zugriff.",
        expiresAt: Date.now() + LOGIN_MS,
        mode: "auto",
        callback,
      }
    }

    // For servers reached over SSH: the browser cannot reach their loopback, so the user pastes the address.
    const codeLogin = async () => {
      const { verifier, challenge, state } = pkce()
      const redirectUri = `http://127.0.0.1${REDIRECT_PATH}`
      return {
        url: authorizeUrl({ base, clientId, redirectUri, scopes, challenge, state }),
        instructions:
          "Melde dich im Browser bei cube project an und bestätige den Zugriff. Der Browser landet danach auf einer Fehlerseite unter 127.0.0.1. Kopiere die komplette Adresse aus der Adresszeile und füge sie hier ein.",
        expiresAt: Date.now() + LOGIN_MS,
        mode: "code",
        callback: async (input) => exchange("code", codeFrom(input, state), redirectUri, verifier),
      }
    }

    const refresh = async (old) => {
      const token = await tokenRequest({ grant_type: "refresh_token", refresh_token: old.refresh })
      return { ...credential(old.methodID, token), metadata: old.metadata }
    }
    const label = (cred) => (typeof cred.metadata?.login === "string" ? `cube project (${cred.metadata.login})` : undefined)

    await ctx.integration.transform((editor) => {
      editor.update(INTEGRATION_ID, (ref) => {
        ref.name = "cube project"
      })
      editor.method.update({
        integrationID: INTEGRATION_ID,
        method: { id: "browser", type: "oauth", label: "Im Browser anmelden" },
        authorize: browserLogin,
        refresh,
        label,
      })
      editor.method.update({
        integrationID: INTEGRATION_ID,
        method: { id: "code", type: "oauth", label: "Anmelden mit Adresse einfügen (SSH-Server)" },
        authorize: codeLogin,
        refresh,
        label,
      })
    })

    const accessToken = async () => {
      const connection = await ctx.integration.connection.active(INTEGRATION_ID).catch(() => undefined)
      const cred = connection && (await ctx.integration.connection.resolve(connection).catch(() => undefined))
      if (cred?.type !== "oauth" || !cred.access) {
        throw new Error("Fehler: Nicht bei cube project angemeldet. Die Anmeldung startet über die Schaltfläche MCP über dem Eingabefeld (Zeile cube project) oder mit dem Werkzeug redmine_anmelden.")
      }
      return cred.access
    }

    const api = async (path, params, signal) => {
      const access = await accessToken()
      const url = `${base}${path}${params ? `?${params}` : ""}`
      try {
        return await json(await fetch(url, { headers: { authorization: `Bearer ${access}`, accept: "application/json" }, signal }), "cube project")
      } catch (error) {
        if (error.status === 401) throw new Error("Fehler: cube project hat die Anmeldung abgelehnt. Bitte über die Schaltfläche MCP neu anmelden.")
        if (error.status === 403) throw new Error("Fehler: Für dieses Ticket oder Projekt fehlt dir in cube project die Berechtigung.")
        if (error.status === 404) throw new Error("Fehler: Nicht gefunden, oder du darfst es in cube project nicht sehen.")
        throw error
      }
    }

    await ctx.tool.transform((editor) => {
      editor.add({
        name: "redmine_ticket",
        description:
          "Liest ein Ticket aus cube project mit Beschreibung, Status, Checkliste, Unteraufgaben, Beziehungen, Anhängen, Commits und Kommentaren. Nimmt die Nummer (1234 oder #1234) oder den Link auf das Ticket.",
        input: {
          type: "object",
          properties: { ticket: { type: "string", description: "Ticketnummer wie 1234 oder #1234, oder der Link auf das Ticket" } },
          required: ["ticket"],
          additionalProperties: false,
        },
        options: { permission: "redmine" },
        execute: async (input, context) => {
          const id = issueId(input?.ticket, base)
          if (!id) throw new Error(`Fehler: "${input?.ticket}" ist keine Ticketnummer und kein Link auf ${base}/issues/…`)
          const params = new URLSearchParams({ include: "journals,children,relations,attachments,changesets,checklists" })
          const body = await api(`/issues/${id}.json`, params, context?.signal)
          return { content: formatIssue(body.issue, base), metadata: { ticket: id } }
        },
      })
      editor.add({
        name: "redmine_tickets",
        description: "Listet Tickets aus cube project, standardmäßig die offenen, die dir zugewiesen sind. Filter nach Projekt, Status und Text im Betreff.",
        input: {
          type: "object",
          properties: {
            projekt: { type: "string", description: "Projekt-Kennung oder -ID, leer für alle Projekte" },
            status: { type: "string", enum: ["offen", "geschlossen", "alle"], description: "Standard: offen" },
            nur_meine: { type: "boolean", description: "Nur mir zugewiesene Tickets. Standard: true" },
            suche: { type: "string", description: "Text, der im Betreff vorkommt" },
            limit: { type: "integer", minimum: 1, maximum: 100, description: "Standard: 25" },
          },
          additionalProperties: false,
        },
        options: { permission: "redmine" },
        execute: async (input, context) => {
          const body = await api("/issues.json", listQuery(input), context?.signal)
          return { content: formatList(body, base) }
        },
      })
      editor.add({
        name: "redmine_anmelden",
        description: "Startet die Anmeldung bei cube project und gibt den Link zurück, den der Benutzer im Browser öffnet. Nur verwenden, wenn ein cube-project-Werkzeug meldet, dass die Anmeldung fehlt.",
        input: { type: "object", properties: {}, additionalProperties: false },
        options: { permission: "redmine" },
        execute: async () => {
          const attempt = await ctx.integration.oauth.connect({ integrationID: INTEGRATION_ID, methodID: "browser" })
          const url = attempt?.url ?? attempt?.data?.url
          if (!url) throw new Error("Fehler: Die Anmeldung konnte nicht gestartet werden.")
          return { content: `Öffne diesen Link im Browser und bestätige den Zugriff. Danach funktionieren die cube-project-Werkzeuge:\n\n${url}` }
        },
      })
    })

    await ctx.session.hook("context", (input) => {
      input.system = [...(input.system ?? []), { type: "text", text: NOTE }]
    })
  },
}
