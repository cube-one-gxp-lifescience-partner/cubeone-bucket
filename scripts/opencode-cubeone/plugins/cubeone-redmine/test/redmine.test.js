import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import test from "node:test"
import plugin from "../server.js"
import { authorizeUrl, codeFrom, formatIssue, formatList, issueId, listQuery, pkce } from "../redmine.js"

const BASE = "https://project.cubeone.de"

test("pkce uses S256 over the verifier", () => {
  const { verifier, challenge, state } = pkce()
  assert.match(verifier, /^[A-Za-z0-9_-]{43,128}$/)
  assert.equal(challenge, createHash("sha256").update(verifier).digest("base64url"))
  assert.ok(state.length >= 32)
})

test("authorize url carries PKCE, state and scopes", () => {
  const url = new URL(authorizeUrl({ base: BASE, clientId: "abc", redirectUri: "http://127.0.0.1:5000/callback", scopes: ["view_issues", "view_project"], challenge: "ch", state: "st" }))
  assert.equal(url.origin + url.pathname, `${BASE}/oauth/authorize`)
  assert.equal(url.searchParams.get("code_challenge_method"), "S256")
  assert.equal(url.searchParams.get("scope"), "view_issues view_project")
  assert.equal(url.searchParams.get("redirect_uri"), "http://127.0.0.1:5000/callback")
})

test("codeFrom takes the pasted address or the bare code", () => {
  assert.equal(codeFrom("abc123", "s"), "abc123")
  assert.equal(codeFrom("http://127.0.0.1/callback?code=xyz&state=s", "s"), "xyz")
  assert.throws(() => codeFrom("http://127.0.0.1/callback?code=xyz&state=other", "s"), /anderen Versuch/)
  assert.throws(() => codeFrom("http://127.0.0.1/callback?error=access_denied", "s"), /access_denied/)
  assert.throws(() => codeFrom("  ", "s"), /Kein Code/)
})

test("issueId accepts numbers, #numbers and links on the own host", () => {
  assert.equal(issueId("1234", BASE), 1234)
  assert.equal(issueId("#77", BASE), 77)
  assert.equal(issueId(`${BASE}/issues/42`, BASE), 42)
  assert.equal(issueId("https://evil.example/issues/42", BASE), undefined)
  assert.equal(issueId("abc", BASE), undefined)
})

test("listQuery defaults to my open tickets", () => {
  const params = listQuery({})
  assert.equal(params.get("status_id"), "open")
  assert.equal(params.get("assigned_to_id"), "me")
  assert.equal(params.get("limit"), "25")
  const all = listQuery({ status: "alle", nur_meine: false, suche: "Login", limit: 500 })
  assert.equal(all.get("status_id"), "*")
  assert.equal(all.get("assigned_to_id"), null)
  assert.equal(all.get("v[subject][]"), "Login")
  assert.equal(all.get("limit"), "100")
})

test("formatIssue renders the parts the agent needs", () => {
  const text = formatIssue(
    {
      id: 5,
      subject: "Login kaputt",
      project: { id: 1, name: "Portal" },
      tracker: { name: "Fehler" },
      status: { name: "Neu" },
      priority: { name: "Hoch" },
      author: { name: "Anna" },
      description: "Schritte:\r\n1. Öffnen",
      checklists: [{ subject: "Repro", is_done: true }],
      journals: [{ user: { name: "Ben" }, created_on: "2026-11-01T10:00:00Z", notes: "Tritt nur in Firefox auf" }, { notes: "" }],
    },
    BASE,
  )
  assert.match(text, /# cube project #5: Login kaputt/)
  assert.match(text, /project\.cubeone\.de\/issues\/5/)
  assert.match(text, /- \[x\] Repro/)
  assert.match(text, /Kommentare \(1 von 1\)/)
  assert.match(text, /Tritt nur in Firefox auf/)
  assert.doesNotMatch(text, /\r/)
})

test("formatList handles empty and filled results", () => {
  assert.equal(formatList({ issues: [] }, BASE), "Keine Tickets gefunden.")
  assert.match(formatList({ total_count: 9, issues: [{ id: 1, subject: "A", status: { name: "Neu" }, project: { name: "P" } }] }, BASE), /1 von 9 Tickets/)
})

function fakeCtx(cred) {
  const registered = { tools: [], methods: [], hooks: [] }
  return {
    registered,
    ctx: {
      options: { url: BASE, clientId: "client-1" },
      integration: {
        transform: async (fn) =>
          fn({
            update: (id, update) => update({ id, name: id }),
            method: { update: (input) => registered.methods.push(input) },
          }),
        connection: {
          active: async () => (cred ? { type: "credential", id: "c1" } : undefined),
          resolve: async () => cred,
        },
        oauth: { connect: async () => ({ url: `${BASE}/oauth/authorize?x=1` }) },
      },
      tool: { transform: async (fn) => fn({ add: (tool) => registered.tools.push(tool) }) },
      session: { hook: async (name, fn) => registered.hooks.push([name, fn]) },
    },
  }
}

test("plugin registers the integration, three tools and the context note", async () => {
  const { ctx, registered } = fakeCtx()
  await plugin.setup(ctx)
  assert.deepEqual(registered.methods.map((m) => m.method.id), ["browser", "code"])
  assert.deepEqual(registered.tools.map((t) => t.name), ["redmine_ticket", "redmine_tickets", "redmine_anmelden"])
  const input = { system: [] }
  registered.hooks[0][1](input)
  assert.match(input.system[0].text, /redmine_ticket/)
})

test("tools refuse without sign-in and send the bearer token when signed in", async () => {
  const signedOut = fakeCtx()
  await plugin.setup(signedOut.ctx)
  await assert.rejects(signedOut.registered.tools[0].execute({ ticket: "5" }, {}), /Fehler: Nicht bei cube project angemeldet/)

  const signedIn = fakeCtx({ type: "oauth", access: "tok", refresh: "r", expires: Date.now() + 1000 })
  await plugin.setup(signedIn.ctx)
  const calls = []
  const original = globalThis.fetch
  globalThis.fetch = async (url, init) => {
    calls.push([String(url), init?.headers?.authorization])
    return new Response(JSON.stringify({ issue: { id: 5, subject: "S", description: "D" } }), { status: 200 })
  }
  try {
    const result = await signedIn.registered.tools[0].execute({ ticket: "#5" }, {})
    assert.match(result.content, /cube project #5: S/)
    assert.equal(calls[0][1], "Bearer tok")
    assert.match(calls[0][0], /\/issues\/5\.json\?include=/)
  } finally {
    globalThis.fetch = original
  }
})

test("browser login exchanges the code with the verifier on the loopback port", async () => {
  const { ctx, registered } = fakeCtx()
  await plugin.setup(ctx)
  const original = globalThis.fetch
  const bodies = []
  globalThis.fetch = async (url, init) => {
    if (String(url).endsWith("/oauth/token")) {
      bodies.push(Object.fromEntries(new URLSearchParams(String(init.body))))
      return new Response(JSON.stringify({ access_token: "a", refresh_token: "r", expires_in: 60 }), { status: 200 })
    }
    if (String(url).startsWith("http://127.0.0.1")) return original(url, init)
    return new Response(JSON.stringify({ user: { login: "mfenssel", firstname: "Marvin" } }), { status: 200 })
  }
  try {
    const attempt = await registered.methods[0].authorize({})
    const url = new URL(attempt.url)
    const redirect = url.searchParams.get("redirect_uri")
    const page = await original(`${redirect}?code=c0de&state=${url.searchParams.get("state")}`)
    assert.equal(page.status, 200)
    const cred = await attempt.callback
    assert.equal(cred.access, "a")
    assert.equal(cred.metadata.login, "mfenssel")
    assert.equal(bodies[0].grant_type, "authorization_code")
    assert.equal(bodies[0].redirect_uri, redirect)
    assert.equal(bodies[0].client_id, "client-1")
    assert.ok(bodies[0].code_verifier.length >= 43)
    assert.equal(bodies[0].client_secret, undefined)
  } finally {
    globalThis.fetch = original
  }
})
