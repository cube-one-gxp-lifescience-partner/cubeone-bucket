"use strict"

// cubeone-ssh's "Vorschau" pill shows browser-reachable localhost ports from an SSH or WSL session, so the user can
// see a dev server that is actually running on the remote target. Nothing like this is built into OpenCode Desktop:
// its own SSH/WSL tunnels only carry the opencode API itself, and no API lets a server-side tool reach into the
// desktop's browser. So this file, unlike the sibling pills, does the forwarding itself from here (the Windows
// desktop), reusing the same `~/.ssh/config` alias the session is already connected with.
//
// The one thing this pill needs that `rows` cannot give it is a free-text port field, so unlike the sibling pills
// it renders its popover with plain DOM calls instead of `rows` - still no JSX and no bundler, just the browser DOM
// plus solid-js's `createSignal`/`createEffect`, which work the same with or without a JSX compiler.
// The window only gets inert stand-ins for `node:` modules, so reading ports goes through the session's own server
// and the SSH forward runs in `main`. The popover is plain DOM: the host draws every button as a menu row, which
// crushed the port field against "Öffnen".
const { spawn } = require("node:child_process")
const fs = require("node:fs")
const net = require("node:net")
const os = require("node:os")
const path = require("node:path")
const { Schema } = require("effect")
const { createSignal, createEffect } = require("solid-js")
const gui = require("@opencode/plugin/gui")
const { ComposerPill, Plugin } = gui

const PREVIEW_SPEC = {
  id: "cubeone-ssh",
  methods: {
    kind: { input: Schema.String, output: Schema.String },
    reachable: { input: Schema.String, output: Schema.String },
    forward: { input: Schema.String, output: Schema.String },
    stop: { input: Schema.String },
  },
}
const Preview = gui.Ipc ? gui.Ipc.define(PREVIEW_SPEC) : { kind: "ipc", id: PREVIEW_SPEC.id, spec: PREVIEW_SPEC }

const SCAN_TIMEOUT_MS = 8_000
const CONNECT_TIMEOUT_MS = 1_500
const FORWARD_WAIT_MS = 12_000
const LOCAL_PORT_RANGE = { from: 20000, to: 20200 }
/** sshd itself. Forwarding it only opens another login, and it is not a service to preview. */
const EXCLUDED_PORTS = new Set([22])

function expand(file) {
  return file.startsWith("~/") || file.startsWith("~\\") ? path.join(os.homedir(), file.slice(2)) : file
}

/** A token is a real host alias only if it has no OpenSSH pattern characters. */
function isConcreteAlias(token) {
  return !!token && !/[*?!]/.test(token)
}

/** Mirrors ssh.js's parser. Kept here too so this CommonJS file needs no cross-import of its ESM sibling. */
function parseSshConfig(text) {
  const hosts = new Map()
  let aliases = []
  for (const raw of String(text ?? "").split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, "").trim()
    if (!line) continue
    const match = line.match(/^(\S+)\s+(.*)$/)
    if (!match) continue
    const key = match[1].toLowerCase()
    if (key === "host") {
      aliases = match[2].trim().split(/\s+/).filter(isConcreteAlias)
      for (const alias of aliases) if (!hosts.has(alias)) hosts.set(alias, true)
      continue
    }
    if (key === "match") aliases = []
  }
  return [...hosts.keys()]
}

function message(error) {
  return error instanceof Error ? error.message : String(error)
}

/**
 * Parses `/proc/net/tcp` and `/proc/net/tcp6`: each data line's 2nd column is "local_address:port" in hex, and the
 * 4th column is the connection state in hex, where `0A` is LISTEN. Returns the sorted, de-duplicated port numbers.
 */
function parseListeningPorts(text, exclude = EXCLUDED_PORTS) {
  const skip = exclude instanceof Set ? exclude : new Set(exclude ?? [])
  const ports = new Set()
  for (const line of String(text ?? "").split("\n")) {
    const columns = line.trim().split(/\s+/)
    if (columns.length < 4 || columns[0] === "sl") continue
    const state = columns[3]?.toUpperCase()
    if (state !== "0A") continue
    const port = parseInt(columns[1]?.split(":")[1] ?? "", 16)
    if (!Number.isInteger(port) || port <= 0 || port >= 65536 || skip.has(port)) continue
    ports.add(port)
  }
  return [...ports].sort((a, b) => a - b)
}

function listPortsCommand() {
  return "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"
}

function isValidPort(value) {
  const port = Number(value)
  return Number.isInteger(port) && port > 0 && port < 65536 && !EXCLUDED_PORTS.has(port)
}

/**
 * Same shape as the desktop's own tunnel: bind explicitly on 127.0.0.1. Without the bind address, Windows OpenSSH
 * listens on ::1 only, and the readiness check against 127.0.0.1 then never succeeds.
 */
function forwardArgs(localPort, port, alias) {
  return [
    "-N",
    "-T",
    "-o",
    "BatchMode=yes",
    "-o",
    "ExitOnForwardFailure=yes",
    "-o",
    "ConnectTimeout=8",
    "-o",
    "ControlMaster=no",
    "-o",
    "ControlPersist=no",
    "-L",
    `127.0.0.1:${localPort}:127.0.0.1:${port}`,
    alias,
  ]
}

/** Desktop server ids are the SSH alias, or `ssh:` plus that alias. */
function sshAliasOf(id, hosts) {
  const text = String(id ?? "")
  const bare = text.replace(/^ssh:/i, "")
  return hosts.find((host) => host === text || host === bare || host.toLowerCase() === bare.toLowerCase())
}

/**
 * The session's remote target, or undefined for the local sidecar - only SSH and WSL sessions get this pill.
 * Anything else non-local is a WSL distro name, the only other remote kind cube one installs.
 */
function targetOf(session, hosts) {
  const id = session?.server?.id
  if (!id || id === "sidecar") return undefined
  const alias = sshAliasOf(id, hosts)
  return alias ? { kind: "ssh", id: alias } : { kind: "wsl", id }
}

/** Runs the port listing on the session's server, through the connection OpenCode already has, and reads its output. */
async function shellPorts(client, location, command = listPortsCommand()) {
  const created = await client.shell.create({ location, command, timeout: SCAN_TIMEOUT_MS })
  const id = created?.data?.id
  if (!id) throw new Error("Fehler: Der Server hat die Portprüfung nicht gestartet.")
  try {
    const until = Date.now() + SCAN_TIMEOUT_MS
    let info
    while (Date.now() < until) {
      info = (await client.shell.get({ id, location }))?.data
      if (info?.status && info.status !== "running") break
      await new Promise((resolve) => setTimeout(resolve, 200))
    }
    if (info?.status !== "exited" || (info.exit ?? 0) !== 0) throw new Error("Fehler: Die Portprüfung auf dem Server ist fehlgeschlagen.")
    const page = await client.shell.output({ id, location, cursor: 0, limit: 500_000 })
    return parseListeningPorts(page?.data?.output)
  } finally {
    void Promise.resolve(client.shell.remove?.({ id, location })).catch(() => {})
  }
}

/** The main-process side of `Preview`: which server is an SSH alias, whether a local port answers, and the forward. */
function previewService(options) {
  const configPath = expand(typeof options?.configPath === "string" ? options.configPath : "~/.ssh/config")
  const held = new Map()
  let next = 0
  const aliases = () => {
    try {
      return parseSshConfig(fs.readFileSync(configPath, "utf8"))
    } catch {
      return []
    }
  }
  const stop = (id) => {
    const child = held.get(String(id))
    if (!child) return
    held.delete(String(id))
    child.kill?.()
  }
  return {
    kind(server) {
      return targetOf({ server: { id: String(server ?? "") } }, aliases())?.kind ?? ""
    },
    reachable(text) {
      const port = Number(text)
      if (!isValidPort(port)) return Promise.resolve("")
      return canConnect(port).then((ok) => (ok ? "1" : ""))
    },
    async forward(text) {
      const request = JSON.parse(String(text))
      const port = Number(request?.port)
      const requested = String(request?.alias ?? "")
      const alias = sshAliasOf(requested, aliases()) ?? requested
      if (!alias || !isValidPort(port)) throw new Error("Fehler: Weiterleitung ohne Ziel oder Port.")
      const localPort = await pickLocalPort(port, (candidate) => canConnect(candidate))
      if (!localPort) throw new Error("Fehler: Kein freier lokaler Port gefunden.")
      const child = spawn("ssh", forwardArgs(localPort, port, alias), {
        stdio: ["ignore", "ignore", "pipe"],
        windowsHide: true,
      })
      let stderr = ""
      child.stderr?.on("data", (chunk) => {
        stderr = `${stderr}${chunk}`.slice(-500)
      })
      const sshError = (fallback) => {
        const detail = stderr.trim()
        return new Error(detail ? `Fehler: ${detail}` : fallback)
      }
      await new Promise((resolve, reject) => {
        let settled = false
        const finish = (error) => {
          if (settled) return
          settled = true
          if (error) {
            child.kill?.()
            reject(error)
            return
          }
          resolve()
        }
        child.once("error", finish)
        child.once("exit", (code) => finish(sshError(`Fehler: ssh hat die Weiterleitung beendet (${code ?? "?"}).`)))
        const until = Date.now() + FORWARD_WAIT_MS
        const poll = async () => {
          if (settled) return
          if (await canConnect(localPort)) {
            child.removeAllListeners("exit")
            child.removeAllListeners("error")
            finish()
            return
          }
          if (Date.now() >= until) {
            finish(sshError("Fehler: Die Weiterleitung wurde nicht rechtzeitig bereit."))
            return
          }
          setTimeout(poll, 100)
        }
        void poll()
      })
      const id = String(++next)
      held.set(id, child)
      return JSON.stringify({ id, localPort })
    },
    stop,
    dispose() {
      for (const id of [...held.keys()]) stop(id)
    },
  }
}

function canConnect(port, timeoutMs = CONNECT_TIMEOUT_MS) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ port, host: "127.0.0.1" })
    const done = (ok) => {
      socket.destroy()
      resolve(ok)
    }
    socket.setTimeout(timeoutMs)
    socket.once("connect", () => done(true))
    socket.once("timeout", () => done(false))
    socket.once("error", () => done(false))
  })
}

/** The preferred port if it is free locally, else the first free port in `range`. `isTaken` is injectable for tests. */
async function pickLocalPort(preferred, isTaken, range = LOCAL_PORT_RANGE) {
  if (!(await isTaken(preferred))) return preferred
  for (let port = range.from; port < range.to; port++) {
    if (!(await isTaken(port))) return port
  }
  return undefined
}

exports.parseSshConfig = parseSshConfig
exports.parseListeningPorts = parseListeningPorts
exports.listPortsCommand = listPortsCommand
exports.isValidPort = isValidPort
exports.forwardArgs = forwardArgs
exports.targetOf = targetOf
exports.pickLocalPort = pickLocalPort
exports.shellPorts = shellPorts
exports.previewService = previewService
exports.Preview = Preview

exports.default = Plugin.define({
  i18n: {
    en: {
      pill: "Ports",
      title: "Ports",
      loading: "Checking open ports…",
      none: "No open ports found",
      port: "Port",
      refresh: "Check again",
      stop: "Disconnect",
      "manual.label": "Other port",
      "manual.placeholder": "3000",
      "manual.open": "Open",
      "manual.invalid": "Enter a port between 1 and 65535",
      "port.excluded": "Port 22 is excluded",
      "list.failed": "Ports unavailable",
      "open.failed": "Could not open the port",
      "open.noPort": "No free local port found",
      "wsl.unreachable": "Not reachable at 127.0.0.1 inside WSL",
    },
    de: {
      pill: "Ports",
      title: "Ports",
      loading: "Offene Ports werden geprüft …",
      none: "Keine offenen Ports gefunden",
      port: "Port",
      refresh: "Neu prüfen",
      stop: "Trennen",
      "manual.label": "Anderer Port",
      "manual.placeholder": "3000",
      "manual.open": "Öffnen",
      "manual.invalid": "Port zwischen 1 und 65535 eingeben",
      "port.excluded": "Port 22 ist ausgenommen",
      "list.failed": "Ports nicht abrufbar",
      "open.failed": "Port konnte nicht geöffnet werden",
      "open.noPort": "Kein freier lokaler Port gefunden",
      "wsl.unreachable": "Unter 127.0.0.1 in WSL nicht erreichbar",
    },
  },
  main(ctx) {
    const service = previewService(ctx.options)
    ctx.provide(Preview, {
      kind: (server) => service.kind(server),
      reachable: (port) => service.reachable(port),
      forward: (text) => service.forward(text),
      stop: (id) => service.stop(id),
    })
    return () => service.dispose()
  },
  setup(ctx) {
    const configPath = expand(typeof ctx.options?.configPath === "string" ? ctx.options.configPath : "~/.ssh/config")
    const hosts = () => {
      try {
        return parseSshConfig(fs.readFileSync(configPath, "utf8"))
      } catch {
        return []
      }
    }

    const [states, setStates] = createSignal(new Map())
    const scanning = new Set()
    const forwards = new Map()

    const keyOf = (session) => `${session.server.id}\n${session.directory}`
    const forwardKey = (session, port) => `${keyOf(session)}\n${port}`
    const store = (key, patch) => {
      const next = new Map(states())
      next.set(key, { ...next.get(key), ...patch })
      setStates(next)
    }
    const bridge = () => ctx.main(Preview)

    const refresh = async (session) => {
      const key = keyOf(session)
      if (scanning.has(key)) return
      scanning.add(key)
      try {
        const ports = await shellPorts(session.server.client, { directory: session.directory })
        store(key, { ports, error: undefined, checked: true })
      } catch (error) {
        store(key, { ports: [], error: message(error), checked: true })
      } finally {
        scanning.delete(key)
      }
    }

    const stopForward = (fKey) => {
      const entry = forwards.get(fKey)
      if (!entry) return
      forwards.delete(fKey)
      void bridge().stop(entry.id).catch(() => {})
    }

    const open = async (session, port) => {
      const key = keyOf(session)
      if (EXCLUDED_PORTS.has(Number(port))) {
        store(key, { manualError: ctx.t("port.excluded") })
        return
      }
      if (!isValidPort(port)) {
        store(key, { manualError: ctx.t("manual.invalid") })
        return
      }
      store(key, { manualError: undefined, opening: port })
      try {
        const preview = bridge()
        const fKey = forwardKey(session, port)
        const existing = forwards.get(fKey)
        if (existing) {
          ctx.system.openExternal(`http://127.0.0.1:${existing.localPort}`)
          return
        }
        if ((await preview.reachable(String(port))) === "1") {
          ctx.system.openExternal(`http://127.0.0.1:${port}`)
          return
        }
        if ((await preview.kind(session.server.id)) !== "ssh") throw new Error(ctx.t("wsl.unreachable"))
        const opened = JSON.parse(await preview.forward(JSON.stringify({ alias: session.server.id, port })))
        forwards.set(fKey, { id: opened.id, localPort: opened.localPort, port })
        store(key, {})
        ctx.system.openExternal(`http://127.0.0.1:${opened.localPort}`)
      } catch (error) {
        ctx.toast.show({ variant: "error", title: ctx.t("pill"), description: message(error) })
      } finally {
        store(key, { opening: undefined })
      }
    }

    ctx.add(ComposerPill, {
      id: "vorschau",
      order: -8,
      show: (input) => {
        const session = input.session
        const target = targetOf(session, hosts())
        if (!target) return undefined
        const key = keyOf(session)
        const state = states().get(key)
        if (!state) queueMicrotask(() => void refresh(session))
        const activeCount = [...forwards.keys()].filter((fKey) => fKey.startsWith(`${key}\n`)).length
        return {
          label: activeCount ? `${ctx.t("pill")} (${activeCount})` : ctx.t("pill"),
          icon: "globe",
          tone: state?.error ? "danger" : activeCount ? "success" : undefined,
          title: ctx.t("title"),
        }
      },
      menu: (input) => {
        const session = input.session
        const target = targetOf(session, hosts())
        const container = document.createElement("div")
        container.className = "cubeone-vorschau"
        if (!target) {
          container.textContent = ctx.t("none")
          return container
        }
        const key = keyOf(session)
        const style = document.createElement("style")
        style.textContent = MENU_STYLE
        const status = document.createElement("p")
        status.className = "status"
        const list = document.createElement("div")
        list.className = "ports"
        const activeList = document.createElement("div")
        activeList.className = "active"
        const errorLine = document.createElement("p")
        const form = document.createElement("form")
        const portInput = document.createElement("input")
        portInput.type = "number"
        portInput.min = "1"
        portInput.max = "65535"
        portInput.placeholder = ctx.t("manual.label")
        portInput.setAttribute("aria-label", ctx.t("manual.label"))
        const submit = document.createElement("button")
        submit.type = "submit"
        submit.className = "primary"
        submit.textContent = ctx.t("manual.open")
        form.append(portInput, submit)
        form.addEventListener("submit", (event) => {
          event.preventDefault()
          void open(session, Number(portInput.value))
        })
        const refreshButton = document.createElement("button")
        refreshButton.type = "button"
        refreshButton.textContent = ctx.t("refresh")
        refreshButton.addEventListener("click", () => void refresh(session))

        container.append(style, status, list, errorLine, activeList, form, refreshButton)

        createEffect(() => {
          const state = states().get(key)
          status.hidden = Boolean(state?.checked) && !state?.error
          status.textContent = state?.error ? `${ctx.t("list.failed")}: ${state.error}` : ctx.t("loading")
          errorLine.textContent = state?.manualError ?? ""
          errorLine.hidden = !state?.manualError

          list.replaceChildren()
          for (const port of state?.ports ?? []) {
            const row = document.createElement("button")
            row.type = "button"
            const name = document.createElement("span")
            name.textContent = String(port)
            const detail = document.createElement("span")
            detail.className = "detail"
            detail.textContent = ctx.t("manual.open")
            row.append(name, detail)
            row.disabled = state?.opening === port
            row.addEventListener("click", () => void open(session, port))
            list.append(row)
          }
          if (state?.checked && !state.ports?.length && !state.error) {
            const empty = document.createElement("p")
            empty.textContent = ctx.t("none")
            list.append(empty)
          }

          activeList.replaceChildren()
          for (const [fKey, entry] of forwards) {
            if (!fKey.startsWith(`${key}\n`)) continue
            const row = document.createElement("div")
            row.className = "row"
            const label = document.createElement("span")
            label.textContent = `${ctx.t("port")} ${entry.port} \u2192 127.0.0.1:${entry.localPort}`
            const stop = document.createElement("button")
            stop.type = "button"
            stop.className = "stop"
            stop.textContent = ctx.t("stop")
            stop.addEventListener("click", () => {
              stopForward(fKey)
              store(key, {})
            })
            row.append(label, stop)
            activeList.append(row)
          }
        })

        return container
      },
    })

    return () => {
      for (const entry of forwards.values()) void bridge().stop(entry.id).catch(() => {})
      forwards.clear()
    }
  },
})

const MENU_STYLE = `
.cubeone-vorschau { display: flex; flex-direction: column; gap: 2px; min-width: 220px; max-width: 280px; box-sizing: border-box; }
.cubeone-vorschau p { margin: 0; padding: 4px 8px; opacity: 0.7; font-size: 13px; }
.cubeone-vorschau .ports, .cubeone-vorschau .active { display: flex !important; flex-direction: column !important; gap: 0; max-height: 240px; overflow: auto; }
.cubeone-vorschau form { display: flex !important; flex-direction: row !important; align-items: center; gap: 8px; padding: 4px 8px; }
.cubeone-vorschau input { flex: 1; min-width: 0; width: auto !important; box-sizing: border-box; height: 28px !important; border: 0 !important; border-radius: 6px !important; background: color-mix(in srgb, currentColor 8%, transparent) !important; color: inherit !important; padding: 0 8px; font: inherit; }
.cubeone-vorschau button { height: 28px !important; width: 100% !important; box-sizing: border-box; display: flex !important; align-items: center; justify-content: space-between; gap: 12px; border: 0 !important; border-radius: 6px !important; background: transparent !important; color: inherit !important; cursor: pointer; font: inherit; padding: 0 8px; text-align: left; }
.cubeone-vorschau button:hover { background: color-mix(in srgb, currentColor 8%, transparent) !important; }
.cubeone-vorschau button .detail { opacity: 0.55; font-size: 12px; }
.cubeone-vorschau button.primary { width: auto !important; flex: none; color: #F47A27 !important; }
.cubeone-vorschau button.primary:hover { color: #F05037 !important; }
.cubeone-vorschau .row { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 0 8px; min-height: 28px; }
.cubeone-vorschau .row button.stop { width: auto !important; }
`
