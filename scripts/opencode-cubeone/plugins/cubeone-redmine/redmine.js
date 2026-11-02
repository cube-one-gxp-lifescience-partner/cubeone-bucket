import { createHash, randomBytes } from "node:crypto"

export const INTEGRATION_ID = "redmine"
export const REDIRECT_PATH = "/callback"
const MAX_TEXT = 20_000
const MAX_JOURNALS = 40

export function pkce() {
  const verifier = randomBytes(48).toString("base64url")
  const challenge = createHash("sha256").update(verifier).digest("base64url")
  return { verifier, challenge, state: randomBytes(24).toString("base64url") }
}

export function baseUrl(value) {
  const url = new URL(value)
  if (url.protocol !== "https:") throw new Error("Die cube-project-Adresse muss https verwenden")
  return url.origin
}

export function authorizeUrl({ base, clientId, redirectUri, scopes, challenge, state }) {
  const params = new URLSearchParams({
    response_type: "code",
    client_id: clientId,
    redirect_uri: redirectUri,
    scope: scopes.join(" "),
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
  })
  return `${base}/oauth/authorize?${params}`
}

/** Accepts the bare code or the whole address the browser landed on. */
export function codeFrom(input, state) {
  const text = String(input ?? "").trim()
  if (!text) throw new Error("Kein Code angegeben")
  if (!/^https?:\/\//i.test(text)) return text
  const url = new URL(text)
  const error = url.searchParams.get("error")
  if (error) throw new Error(url.searchParams.get("error_description") || error)
  const returned = url.searchParams.get("state")
  if (returned && state && returned !== state) throw new Error("Die Anmeldung gehört zu einem anderen Versuch")
  const code = url.searchParams.get("code")
  if (!code) throw new Error("Die Adresse enthält keinen Code")
  return code
}

export function credential(methodID, token, user) {
  return {
    type: "oauth",
    methodID,
    access: token.access_token,
    refresh: token.refresh_token ?? "",
    expires: Date.now() + (Number(token.expires_in) || 7200) * 1000,
    metadata: user ? { login: user.login, name: [user.firstname, user.lastname].filter(Boolean).join(" ") } : undefined,
  }
}

/** "#123", "123" or an issue link on the configured host. */
export function issueId(value, base) {
  const text = String(value ?? "").trim()
  const plain = /^#?(\d{1,9})$/.exec(text)
  if (plain) return Number(plain[1])
  try {
    const url = new URL(text)
    if (base && url.origin !== base) return undefined
    const match = /^\/issues\/(\d{1,9})\/?$/.exec(url.pathname)
    return match ? Number(match[1]) : undefined
  } catch {
    return undefined
  }
}

function clip(text, max = MAX_TEXT) {
  const value = String(text ?? "").replace(/\r\n/g, "\n").trim()
  return value.length > max ? `${value.slice(0, max)}\n[… gekürzt, ${value.length - max} Zeichen mehr]` : value
}

function name(ref) {
  return ref?.name ?? (ref?.id ? `#${ref.id}` : "–")
}

function date(value) {
  return value ? String(value).slice(0, 16).replace("T", " ") : "–"
}

export function formatIssue(issue, base) {
  const lines = [
    `# cube project #${issue.id}: ${issue.subject}`,
    `${base}/issues/${issue.id}`,
    "",
    `- Projekt: ${name(issue.project)}`,
    `- Tracker: ${name(issue.tracker)} · Status: ${name(issue.status)} · Priorität: ${name(issue.priority)}`,
    `- Autor: ${name(issue.author)} · Zugewiesen: ${name(issue.assigned_to)}`,
    `- Erstellt: ${date(issue.created_on)} · Geändert: ${date(issue.updated_on)}`,
  ]
  if (issue.fixed_version) lines.push(`- Version: ${name(issue.fixed_version)}`)
  if (issue.parent?.id) lines.push(`- Übergeordnet: #${issue.parent.id}`)
  if (issue.start_date || issue.due_date) lines.push(`- Zeitraum: ${issue.start_date ?? "–"} bis ${issue.due_date ?? "–"}`)
  if (typeof issue.done_ratio === "number") lines.push(`- Erledigt: ${issue.done_ratio} %`)
  for (const field of issue.custom_fields ?? []) {
    const value = Array.isArray(field.value) ? field.value.filter(Boolean).join(", ") : field.value
    if (value) lines.push(`- ${field.name}: ${value}`)
  }
  lines.push("", "## Beschreibung", "", clip(issue.description) || "(leer)")

  if (issue.checklists?.length) {
    lines.push("", "## Checkliste", "")
    for (const item of issue.checklists) lines.push(`- [${item.is_done ? "x" : " "}] ${item.subject}`)
  }
  if (issue.children?.length) {
    lines.push("", "## Unteraufgaben", "")
    for (const child of issue.children) lines.push(`- #${child.id} ${child.subject ?? ""}`.trimEnd())
  }
  if (issue.relations?.length) {
    lines.push("", "## Beziehungen", "")
    for (const rel of issue.relations) {
      const other = rel.issue_id === issue.id ? rel.issue_to_id : rel.issue_id
      lines.push(`- ${rel.relation_type} #${other}`)
    }
  }
  if (issue.attachments?.length) {
    lines.push("", "## Anhänge", "")
    for (const file of issue.attachments) lines.push(`- ${file.filename} (${file.filesize} Byte): ${file.content_url}`)
  }
  if (issue.changesets?.length) {
    lines.push("", "## Commits", "")
    for (const set of issue.changesets) lines.push(`- ${String(set.revision).slice(0, 12)} ${clip(set.comments, 200).split("\n")[0]}`)
  }
  const notes = (issue.journals ?? []).filter((entry) => entry.notes?.trim())
  if (notes.length) {
    const shown = notes.slice(-MAX_JOURNALS)
    lines.push("", `## Kommentare (${shown.length} von ${notes.length})`, "")
    for (const entry of shown) {
      lines.push(`### ${name(entry.user)}, ${date(entry.created_on)}${entry.private_notes ? " (privat)" : ""}`, "", clip(entry.notes, 4000), "")
    }
  }
  return lines.join("\n").trimEnd()
}

export function formatList(result, base) {
  const issues = result.issues ?? []
  if (!issues.length) return "Keine Tickets gefunden."
  const head = `${issues.length} von ${result.total_count ?? issues.length} Tickets`
  const rows = issues.map(
    (issue) =>
      `- #${issue.id} [${name(issue.status)}] ${issue.subject} · ${name(issue.project)} · ${name(issue.assigned_to)} · ${date(issue.updated_on)}`,
  )
  return [head, "", ...rows, "", `Einzelheiten: redmine_ticket mit der Nummer. Liste im Browser: ${base}/issues`].join("\n")
}

export function listQuery(input) {
  const params = new URLSearchParams()
  const status = input?.status ?? "offen"
  params.set("status_id", status === "alle" ? "*" : status === "geschlossen" ? "closed" : "open")
  if (input?.nur_meine !== false) params.set("assigned_to_id", "me")
  if (input?.projekt) params.set("project_id", String(input.projekt))
  if (input?.suche) {
    params.set("set_filter", "1")
    params.append("f[]", "subject")
    params.set("op[subject]", "~")
    params.append("v[subject][]", String(input.suche))
  }
  params.set("sort", "updated_on:desc")
  params.set("limit", String(Math.min(Math.max(Number(input?.limit) || 25, 1), 100)))
  return params
}

export const NOTE = [
  "cube project ist das Ticketsystem (project.cubeone.de).",
  "Ein Verweis wie #1234 oder ein Link auf /issues/1234 meint ein Ticket aus cube project, sofern der Benutzer nichts anderes sagt.",
  "Lies das Ticket mit redmine_ticket, bevor du daran arbeitest. Offene eigene Tickets liefert redmine_tickets.",
].join(" ")
