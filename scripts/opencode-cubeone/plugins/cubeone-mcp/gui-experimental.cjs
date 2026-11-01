"use strict"

// Plain CommonJS on purpose: the app provides solid-js and @opencode/plugin/gui, and a pill needs no JSX.
const { createSignal } = require("solid-js")
const { ComposerPill, Plugin } = require("@opencode/plugin/gui")

const REFRESH_MS = 20_000
const LOGIN_POLL_MS = 3_000
const LOGIN_WAIT_MS = 5 * 60_000

const ROW = {
  connected: { icon: "circle-check", tone: "success", key: "status.connected" },
  needs_auth: { icon: "lock", tone: "warning", key: "status.needs_auth" },
  failed: { icon: "circle-xmark", tone: "danger", key: "status.failed" },
  pending: { icon: "refresh", tone: undefined, key: "status.pending" },
  disabled: { icon: "circle-ban-sign", tone: undefined, key: "status.disabled" },
}

function message(error) {
  return error instanceof Error ? error.message : String(error)
}

exports.default = Plugin.define({
  i18n: {
    en: {
      pill: "MCP",
      title: "MCP servers",
      loading: "Checking MCP servers…",
      "status.connected": "signed in",
      "status.needs_auth": "sign-in needed",
      "status.failed": "unreachable",
      "status.pending": "starting",
      "status.disabled": "off",
      none: "No MCP servers configured",
      refresh: "Check again",
      "toast.title": "MCP sign-in needed",
      "toast.action": "Sign in",
      "login.started": "Sign-in opened in the browser",
      "login.done": "Signed in",
      "login.failed": "Sign-in failed",
      "list.failed": "MCP status unavailable",
    },
    de: {
      pill: "MCP",
      title: "MCP-Server",
      loading: "MCP-Server werden geprüft …",
      "status.connected": "angemeldet",
      "status.needs_auth": "Anmeldung nötig",
      "status.failed": "nicht erreichbar",
      "status.pending": "startet",
      "status.disabled": "aus",
      none: "Keine MCP-Server eingerichtet",
      refresh: "Neu prüfen",
      "toast.title": "MCP-Anmeldung nötig",
      "toast.action": "Anmelden",
      "login.started": "Anmeldung im Browser geöffnet",
      "login.done": "Angemeldet",
      "login.failed": "Anmeldung fehlgeschlagen",
      "list.failed": "MCP-Status nicht abrufbar",
    },
  },
  setup(ctx) {
    const [states, setStates] = createSignal(new Map())
    const loading = new Set()
    const warned = new Set()

    const keyOf = (session) => `${session.server.id}\n${session.directory}`
    const store = (key, value) => {
      const next = new Map(states())
      next.set(key, value)
      setStates(next)
    }

    const warn = (session, key, servers) => {
      const locked = servers.filter((server) => server.status.status === "needs_auth")
      if (!locked.length || warned.has(key)) return
      warned.add(key)
      ctx.toast.show({
        title: ctx.t("toast.title"),
        description: locked.map((server) => server.title || server.name).join(", "),
        icon: "lock",
        persistent: true,
        actions: locked.slice(0, 3).map((server) => ({
          label: `${ctx.t("toast.action")}: ${server.title || server.name}`,
          run: () => void login(session, server.name),
        })),
      })
    }

    const refresh = async (session) => {
      if (!session?.directory) return
      const key = keyOf(session)
      if (loading.has(key)) return
      loading.add(key)
      try {
        const listed = await session.server.client.mcp.list({ location: { directory: session.directory } })
        const servers = listed?.data ?? []
        store(key, { servers, at: Date.now() })
        warn(session, key, servers)
      } catch (error) {
        store(key, { servers: [], error: message(error), at: Date.now() })
      } finally {
        loading.delete(key)
      }
    }

    // Same steps as the app's own MCP toggle: the server's integration, its OAuth method, then the browser.
    const login = async (session, name) => {
      const client = session.server.client
      const location = { directory: session.directory }
      try {
        const server = (await client.mcp.list({ location })).data.find((item) => item.name === name)
        if (!server?.integrationID) throw new Error(`${name}: keine Anmelde-Integration`)
        const integration = await client.integration.get({ integrationID: server.integrationID, location })
        const method = integration.data?.methods.find((item) => item.type === "oauth" && !item.form?.length)
        if (!method) throw new Error(`${name}: keine OAuth-Anmeldung ohne Formular`)
        const attempt = await client.integration.oauth.connect({ integrationID: server.integrationID, methodID: method.id, location })
        ctx.system.openExternal(attempt.data.url)
        ctx.toast.show({ title: ctx.t("login.started"), description: server.title || name, icon: "lock" })
        const until = Date.now() + LOGIN_WAIT_MS
        while (Date.now() < until && !ctx.signal.aborted) {
          await new Promise((resolve) => setTimeout(resolve, LOGIN_POLL_MS))
          await refresh(session)
          const now = states().get(keyOf(session))?.servers.find((item) => item.name === name)
          if (now?.status.status === "connected") {
            ctx.toast.show({ variant: "success", title: ctx.t("login.done"), description: server.title || name })
            return
          }
        }
      } catch (error) {
        ctx.toast.show({ variant: "error", title: ctx.t("login.failed"), description: message(error) })
      }
    }

    const timer = setInterval(() => {
      const session = ctx.sessions.current()
      if (session) void refresh(session)
    }, REFRESH_MS)

    ctx.add(ComposerPill, {
      id: "mcp",
      order: -10,
      show: (input) => {
        const session = input.session
        const state = states().get(keyOf(session))
        if (!state) {
          queueMicrotask(() => void refresh(session))
          return { label: ctx.t("pill"), icon: "mcp", title: ctx.t("loading") }
        }
        if (state.error) {
          return { label: ctx.t("pill"), icon: "mcp", tone: "danger", title: ctx.t("list.failed"), rows: [{ id: "error", label: state.error, icon: "circle-xmark", tone: "danger" }, { id: "refresh", label: ctx.t("refresh"), icon: "refresh", run: () => void refresh(session) }] }
        }
        const enabled = state.servers.filter((server) => server.status.status !== "disabled")
        const connected = enabled.filter((server) => server.status.status === "connected").length
        const tone = enabled.some((server) => server.status.status === "failed")
          ? "danger"
          : enabled.some((server) => server.status.status === "needs_auth")
            ? "warning"
            : enabled.length
              ? "success"
              : undefined
        const rows = state.servers.map((server) => {
          const look = ROW[server.status.status] ?? ROW.pending
          const status = server.status.status
          return {
            id: `server:${server.name}`,
            label: server.title || server.name,
            icon: look.icon,
            tone: look.tone,
            detail: ctx.t(look.key),
            run:
              status === "needs_auth"
                ? () => void login(session, server.name)
                : status === "failed"
                  ? () =>
                      void session.server.client.experimental.mcp
                        .connect({ server: server.name, location: { directory: session.directory } })
                        .catch(() => {})
                        .then(() => refresh(session))
                  : undefined,
          }
        })
        if (!rows.length) rows.push({ id: "none", label: ctx.t("none"), icon: "mcp" })
        rows.push({ id: "refresh", label: ctx.t("refresh"), icon: "refresh", run: () => void refresh(session) })
        return { label: `${ctx.t("pill")} ${connected}/${enabled.length}`, icon: "mcp", tone, title: ctx.t("title"), rows }
      },
    })

    return () => clearInterval(timer)
  },
})
