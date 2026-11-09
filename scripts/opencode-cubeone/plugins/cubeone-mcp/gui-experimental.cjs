"use strict"

// Plain CommonJS on purpose: the app provides solid-js and @opencode/plugin/gui, and a pill needs no JSX.
// The app evaluates this bundle from source text and shares only its own modules with it, so it must not require a
// sibling file. It evaluates it twice: in a window the `node:` modules are inert stand-ins, so the loopback listener
// runs in `main`, the desktop's main process, and the window talks to it over the `Callback` Ipc.
const http = require("node:http")
const { Schema } = require("effect")
const { createSignal } = require("solid-js")
const gui = require("@opencode/plugin/gui")
const { ComposerPill, Plugin } = gui

const CALLBACK_SPEC = {
  id: "cubeone-mcp",
  methods: {
    listen: { input: Schema.String, output: Schema.String },
    wait: { input: Schema.String, output: Schema.String },
    release: { input: Schema.String },
  },
}
const Callback = gui.Ipc ? gui.Ipc.define(CALLBACK_SPEC) : { kind: "ipc", id: CALLBACK_SPEC.id, spec: CALLBACK_SPEC }

// No sibling require is available in GUI bundles; match the server's plain RPC contract.
const CallbackRelay = {
  id: "cubeone-mcp.callback",
  methods: {
    send: {
      input: {
        type: "object",
        properties: {
          port: { type: "integer", minimum: 1, maximum: 65535 },
          target: { type: "string", maxLength: 4096 },
        },
        required: ["port", "target"],
        additionalProperties: false,
      },
      output: { type: "integer" },
    },
  },
  events: {},
}

const REFRESH_MS = 20_000
const LOGIN_POLL_MS = 3_000
const LOGIN_WAIT_MS = 5 * 60_000
// Integrations registered by cube one server plugins rather than by an MCP server.
const PLUGIN_INTEGRATIONS = [{ id: "redmine", label: "cube project", method: "browser" }]

/** The note server still introduces itself as Outline. Show the product name instead. */
function labelOf(server) {
  if (server?.name === "cube-note" || server?.title === "Outline") return "cube note"
  return server?.title || server?.name || ""
}

const ROW = {
  connected: { icon: "circle-check", tone: "success", key: "status.connected" },
  needs_auth: { icon: "lock", tone: "warning", key: "status.needs_auth" },
  failed: { icon: "circle-xmark", tone: "danger", key: "status.failed" },
  pending: { icon: "refresh", tone: undefined, key: "status.pending" },
  disabled: { icon: "circle-ban-sign", tone: undefined, key: "status.disabled" },
}

const DONE_PAGE =
  '<!doctype html><html lang="de"><head><meta charset="utf-8"><title>Anmeldung</title></head>' +
  '<body style="font-family:Inter,system-ui,sans-serif;background:#F5F3F0;color:#1A1A1A;padding:48px">' +
  "<h1 style=\"font-weight:600;letter-spacing:-0.025em\">Anmeldung wird abgeschlossen</h1>" +
  "<p>OpenCode gibt die Anmeldung an den Server weiter. Dieses Fenster kann geschlossen werden.</p></body></html>"

function message(error) {
  return error instanceof Error ? error.message : String(error)
}

/** Resolves on the next poll, or sooner when the plugin context is aborted, so a closed session does not wait out the interval. */
function waitForPoll(signal, ms) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms)
    if (!signal) return
    if (signal.aborted) {
      clearTimeout(timer)
      resolve()
      return
    }
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer)
        resolve()
      },
      { once: true },
    )
  })
}

/**
 * The loopback port an OAuth authorize URL sends the browser back to, from `redirect_uri` when that parameter
 * is present, otherwise from the URL itself. Undefined when the redirect is not a loopback address.
 */
function loopbackPort(url) {
  let target
  try {
    target = new URL(String(url))
    const redirect = target.searchParams.get("redirect_uri")
    if (redirect) target = new URL(redirect)
  } catch {
    return undefined
  }
  const host = target.hostname.replace(/^\[|\]$/g, "")
  if (host !== "127.0.0.1" && host !== "localhost" && host !== "::1") return undefined
  const port = Number(target.port)
  return Number.isInteger(port) && port > 0 && port < 65536 ? port : undefined
}

/** Accept only OAuth callback paths with a plain query, never an arbitrary loopback request. */
function isCallbackTarget(target) {
  return typeof target === "string" && target.length <= 4096 &&
    /^(?:\/callback|\/mcp\/oauth\/callback)\?(?:%[0-9A-Fa-f]{2}|[A-Za-z0-9\-._~&=+:@/?,;])+$/.test(target)
}

/** Current SessionRef uses location; retain compatibility with older GUI session objects. */
function directoryOf(session) {
  return session?.location?.directory ?? session?.directory
}

/**
 * The main-process side of `Callback`. A remote server's OAuth redirect points at 127.0.0.1 on that server, but the
 * browser runs here, so `listen` takes the same port on this machine and `wait` hands over the first callback the
 * browser sends to it. Each listener closes on `release`, after its callback, or after `holdMs`.
 */
function callbackService(holdMs = LOGIN_WAIT_MS + 60_000, createServer = http.createServer) {
  const open = new Map()
  let next = 0
  const release = (id) => {
    const key = String(id)
    const entry = open.get(key)
    if (!entry) return
    open.delete(key)
    clearTimeout(entry.timer)
    entry.server.close()
    entry.settle("")
  }
  return {
    listen(text) {
      const port = Number(text)
      if (!Number.isInteger(port) || port <= 0 || port >= 65536) return Promise.resolve("")
      return new Promise((resolve) => {
        let settle
        const received = new Promise((done) => (settle = done))
        const server = createServer((request, response) => {
          const target = String(request.url ?? "")
          if (request.method !== "GET" || !isCallbackTarget(target) || target.startsWith("/favicon")) {
            response.writeHead(404, { "content-type": "text/plain; charset=utf-8" })
            response.end("Nicht gefunden")
            return
          }
          response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" })
          response.end(DONE_PAGE)
          settle(target)
        })
        server.once("error", () => resolve(""))
        server.listen(port, "127.0.0.1", () => {
          const id = String(++next)
          const entry = { server, settle, received, timer: setTimeout(() => release(id), holdMs) }
          open.set(id, entry)
          resolve(id)
        })
      })
    },
    wait(id) {
      const entry = open.get(String(id))
      if (!entry) return Promise.resolve("")
      return entry.received.then((target) => {
        if (target) release(id)
        return target
      })
    },
    release,
    dispose() {
      for (const id of [...open.keys()]) release(id)
    },
  }
}

/** Replay through the existing plugin RPC; credentials belong in the body, never shell-command logs. */
async function relayOnServer(client, location, port, target, signal) {
  if (!location?.directory) throw new Error("Missing callback relay location")
  if (!Number.isInteger(port) || port <= 0 || port >= 65536 || !isCallbackTarget(target)) {
    throw new Error("Invalid callback relay input")
  }
  return client.rpc(CallbackRelay).send({ port, target }, { location, signal })
}

/** Sign-in state of the plugin integrations this server knows; unknown ones are left out. */
async function pluginIntegrations(client, location) {
  const found = await Promise.all(
    PLUGIN_INTEGRATIONS.map(async (item) => {
      try {
        const integration = (await client.integration.get({ integrationID: item.id, location }))?.data
        if (!integration) return undefined
        return { ...item, connected: (integration.connections ?? []).length > 0 }
      } catch {
        return undefined
      }
    }),
  )
  return found.filter(Boolean)
}

const OPEN_TAGS = new Set(["FilesOpenExternal", "FilesOpenBrowser"])

/** The URL carried by the desktop's IPC request that opens a browser, if this message is one. */
function externalUrl(message) {
  if (!message || message._tag !== "Request" || !OPEN_TAGS.has(message.tag)) return undefined
  const url = message.payload && message.payload.url
  return typeof url === "string" ? url : undefined
}

/**
 * Wraps MessagePort.postMessage. The desktop sends FilesOpenExternal through that port and does not await it, so the
 * wrapper holds the message until `schedule` settles. `schedule` returns a promise when the URL needs a forward.
 */
function guardPostMessage(original, schedule) {
  function guarded(message, transfer) {
    const url = externalUrl(message)
    const pending = url ? schedule(url) : undefined
    if (!pending) return original.call(this, message, transfer)
    void Promise.resolve(pending).finally(() => original.call(this, message, transfer))
  }
  guarded.cubeoneGuard = true
  return guarded
}

exports.loopbackPort = loopbackPort
exports.CallbackRelay = CallbackRelay
exports.directoryOf = directoryOf
exports.callbackService = callbackService
exports.relayOnServer = relayOnServer
exports.Callback = Callback
exports.externalUrl = externalUrl
exports.guardPostMessage = guardPostMessage

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
      "status.signed_out": "not signed in",
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
      "status.signed_out": "nicht angemeldet",
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
  main(ctx) {
    const service = callbackService()
    ctx.provide(Callback, {
      listen: (port) => service.listen(port),
      wait: (id) => service.wait(id),
      release: (id) => service.release(id),
    })
    return () => service.dispose()
  },
  setup(ctx) {
    const [states, setStates] = createSignal(new Map())
    const loading = new Set()
    const warned = new Set()

    const keyOf = (session) => `${session.server.id}\n${directoryOf(session)}`
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
        description: locked.map((server) => labelOf(server)).join(", "),
        icon: "lock",
        persistent: true,
        actions: locked.slice(0, 3).map((server) => ({
          label: `${ctx.t("toast.action")}: ${labelOf(server)}`,
          run: () => void login(session, server.name),
        })),
      })
    }

    const refresh = async (session) => {
      if (!directoryOf(session)) return
      const key = keyOf(session)
      if (loading.has(key)) return
      loading.add(key)
      try {
        const location = { directory: directoryOf(session) }
        const listed = await session.server.client.mcp.list({ location })
        const servers = listed?.data ?? []
        const integrations = await pluginIntegrations(session.server.client, location)
        store(key, { servers, integrations, at: Date.now() })
        warn(session, key, servers)
      } catch (error) {
        store(key, { servers: [], error: message(error), at: Date.now() })
      } finally {
        loading.delete(key)
      }
    }

    // The desktop browser pane, when this build provides one. Otherwise the system browser. Both run on this
    // machine, so a loopback redirect from an SSH session only works after exposeLoopback.
    const openInApp = (session, url) => {
      try {
        const { Browser } = require("@opencode/plugin/gui/browser")
        const read = ctx.use?.(Browser)
        const pane = typeof read === "function" ? read() : undefined
        if (pane?.status === "active" && pane.value?.canOpen?.(session)) {
          pane.value.open(session, url)
          return
        }
      } catch {
        // Older builds and the unit tests have no browser contract.
      }
      ctx.system.openExternal(url)
    }

    // On a remote session the OAuth client listens on the server's 127.0.0.1, which the browser here cannot reach.
    // Main takes the same port on this machine before the browser opens; the callback the browser sends there is
    // replayed on the server through the session's own connection, so no second SSH connection is needed. When the
    // port is taken here (WSL mirrors its localhost onto Windows), the browser already reaches the server directly.
    const exposeLoopback = async (session, url) => {
      const port = loopbackPort(url)
      const server = session?.server?.id
      if (!port || !server || server === "sidecar" || !directoryOf(session)) return undefined
      const callback = ctx.main(Callback)
      const id = await callback.listen(String(port))
      if (!id) return undefined
      let stopped = false
      const stop = () => {
        if (stopped) return
        stopped = true
        void callback.release(id).catch(() => {})
      }
      void relayWhenCalled(session, port, id, () => stopped).finally(stop)
      return stop
    }

    const relayWhenCalled = async (session, port, id, stopped) => {
      const callback = ctx.main(Callback)
      const until = Date.now() + LOGIN_WAIT_MS
      let target = ""
      while (!stopped() && !ctx.signal?.aborted && Date.now() < until) {
        try {
          target = await callback.wait(id)
          break
        } catch {
          await waitForPoll(ctx.signal, 1_000)
        }
      }
      if (!target) return
      try {
        const code = await relayOnServer(
          session.server.client, { directory: directoryOf(session) }, port, target, ctx.signal,
        )
        if (code !== 0) throw new Error(`Fehler: Die Anmeldung konnte nicht an den Server übergeben werden (${code ?? "Zeitüberschreitung"}).`)
        void refresh(session)
      } catch (error) {
        ctx.toast.show({ variant: "error", title: ctx.t("login.failed"), description: message(error) })
      }
    }

    // The project settings switch calls the app's own open, which never reaches the pill above. Every such open is
    // an IPC message on MessagePort. Holding that message until the forward answers means the browser cannot load
    // the redirect before this machine is listening.
    const unguard = installExternalGuard()
    function installExternalGuard() {
      const proto = globalThis.MessagePort && globalThis.MessagePort.prototype
      if (!proto || typeof proto.postMessage !== "function" || proto.postMessage.cubeoneGuard) return () => {}
      const original = proto.postMessage
      const guarded = guardPostMessage(original, (url) => {
        const session = ctx.sessions.current()
        const server = session?.server?.id
        if (!loopbackPort(url) || !server || server === "sidecar") return undefined
        return exposeLoopback(session, url).then(
          (stop) => stop && setTimeout(stop, LOGIN_WAIT_MS),
          (error) => ctx.toast.show({ variant: "error", title: ctx.t("login.failed"), description: message(error) }),
        )
      })
      try {
        proto.postMessage = guarded
      } catch {
        return () => {}
      }
      return () => {
        if (proto.postMessage === guarded) proto.postMessage = original
      }
    }

    // Same steps as the app's own MCP toggle: the server's integration, its OAuth method, then the browser.
    const login = async (session, name) => {
      const client = session.server.client
      const location = { directory: directoryOf(session) }
      let stop
      try {
        const server = (await client.mcp.list({ location })).data.find((item) => item.name === name)
        if (!server?.integrationID) throw new Error(`${name}: keine Anmelde-Integration`)
        const integration = await client.integration.get({ integrationID: server.integrationID, location })
        const method = integration.data?.methods.find((item) => item.type === "oauth" && !item.form?.length)
        if (!method) throw new Error(`${name}: keine OAuth-Anmeldung ohne Formular`)
        const attempt = await client.integration.oauth.connect({ integrationID: server.integrationID, methodID: method.id, location })
        const url = attempt?.data?.url
        if (!url) throw new Error("Fehler: Die Anmeldung hat keine Adresse geliefert.")
        stop = await exposeLoopback(session, url)
        openInApp(session, url)
        ctx.toast.show({ title: ctx.t("login.started"), description: labelOf(server), icon: "lock" })
        const until = Date.now() + LOGIN_WAIT_MS
        while (Date.now() < until && !ctx.signal?.aborted) {
          await waitForPoll(ctx.signal, LOGIN_POLL_MS)
          if (ctx.signal?.aborted) return
          await refresh(session)
          const now = states().get(keyOf(session))?.servers.find((item) => item.name === name)
          if (now?.status.status === "connected") {
            ctx.toast.show({ variant: "success", title: ctx.t("login.done"), description: labelOf(server) })
            return
          }
        }
      } catch (error) {
        ctx.toast.show({ variant: "error", title: ctx.t("login.failed"), description: message(error) })
      } finally {
        stop?.()
      }
    }

    const loginIntegration = async (session, item) => {
      const client = session.server.client
      const location = { directory: directoryOf(session) }
      let stop
      try {
        const attempt = await client.integration.oauth.connect({ integrationID: item.id, methodID: item.method, location })
        const url = attempt?.data?.url
        if (!url) throw new Error("Fehler: Die Anmeldung hat keine Adresse geliefert.")
        stop = await exposeLoopback(session, url)
        openInApp(session, url)
        ctx.toast.show({ title: ctx.t("login.started"), description: item.label, icon: "lock" })
        const until = Date.now() + LOGIN_WAIT_MS
        while (Date.now() < until && !ctx.signal?.aborted) {
          await waitForPoll(ctx.signal, LOGIN_POLL_MS)
          if (ctx.signal?.aborted) return
          await refresh(session)
          const now = states().get(keyOf(session))?.integrations?.find((entry) => entry.id === item.id)
          if (now?.connected) {
            ctx.toast.show({ variant: "success", title: ctx.t("login.done"), description: item.label })
            return
          }
        }
      } catch (error) {
        ctx.toast.show({ variant: "error", title: ctx.t("login.failed"), description: message(error) })
      } finally {
        stop?.()
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
        const integrations = state.integrations ?? []
        const total = enabled.length + integrations.length
        const connected = enabled.filter((server) => server.status.status === "connected").length
          + integrations.filter((item) => item.connected).length
        const tone = enabled.some((server) => server.status.status === "failed")
          ? "danger"
          : enabled.some((server) => server.status.status === "needs_auth") || integrations.some((item) => !item.connected)
            ? "warning"
            : total
              ? "success"
              : undefined
        const rows = state.servers.map((server) => {
          const look = ROW[server.status.status] ?? ROW.pending
          const status = server.status.status
          return {
            id: `server:${server.name}`,
            label: labelOf(server),
            icon: look.icon,
            tone: look.tone,
            detail: ctx.t(look.key),
            run:
              status === "needs_auth"
                ? () => void login(session, server.name)
                : status === "failed"
                  ? () =>
                      void session.server.client.experimental.mcp
                        .connect({ server: server.name, location: { directory: directoryOf(session) } })
                        .catch(() => {})
                        .then(() => refresh(session))
                  : undefined,
          }
        })
        for (const item of integrations) {
          rows.push({
            id: `integration:${item.id}`,
            label: item.label,
            icon: item.connected ? ROW.connected.icon : ROW.needs_auth.icon,
            tone: item.connected ? ROW.connected.tone : undefined,
            detail: item.connected ? ctx.t(ROW.connected.key) : ctx.t("status.signed_out"),
            run: item.connected ? undefined : () => void loginIntegration(session, item),
          })
        }
        if (!rows.length) rows.push({ id: "none", label: ctx.t("none"), icon: "mcp" })
        rows.push({ id: "refresh", label: ctx.t("refresh"), icon: "refresh", run: () => void refresh(session) })
        return { label: `${ctx.t("pill")} ${connected}/${total}`, icon: "mcp", tone, title: ctx.t("title"), rows }
      },
    })

    return () => {
      clearInterval(timer)
      unguard()
    }
  },
})
