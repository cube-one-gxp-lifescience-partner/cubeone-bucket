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
const { execFile, spawn } = require("node:child_process")
const fs = require("node:fs")
const net = require("node:net")
const os = require("node:os")
const path = require("node:path")
const { createSignal, createEffect } = require("solid-js")
const { ComposerPill, Plugin } = require("@opencode/plugin/gui")

const SCAN_TIMEOUT_MS = 8_000
const CONNECT_TIMEOUT_MS = 1_500
const FORWARD_WAIT_MS = 5_000
const LOCAL_PORT_RANGE = { from: 20000, to: 20200 }

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
function parseListeningPorts(text, exclude) {
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
  return Number.isInteger(port) && port > 0 && port < 65536
}

/**
 * The session's remote target, or undefined for the local sidecar - only SSH and WSL sessions get this pill.
 * `session.server.id` is the SSH alias for an SSH session (Install-OpenCodeRemote.ps1 registers it under that
 * name); anything else non-local is treated as a WSL distro name, the only other remote kind cube one installs.
 */
function targetOf(session, hosts) {
  const id = session?.server?.id
  if (!id || id === "sidecar") return undefined
  return hosts.includes(id) ? { kind: "ssh", id } : { kind: "wsl", id }
}

function execFileAsync(command, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { timeout: timeoutMs, windowsHide: true, maxBuffer: 2 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) {
        error.message = stderr?.trim() ? `${error.message}: ${stderr.trim()}` : error.message
        reject(error)
        return
      }
      resolve(stdout)
    })
  })
}

async function scanPorts(target, runner = execFileAsync) {
  const command = listPortsCommand()
  const stdout =
    target.kind === "ssh"
      ? await runner("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", target.id, command], SCAN_TIMEOUT_MS)
      : await runner("wsl.exe", ["-d", target.id, "--", "sh", "-c", command], SCAN_TIMEOUT_MS)
  return parseListeningPorts(stdout)
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

function waitReachable(port, deadlineMs) {
  const until = Date.now() + deadlineMs
  const poll = async () => {
    if (await canConnect(port)) return true
    if (Date.now() >= until) return false
    await new Promise((resolve) => setTimeout(resolve, 150))
    return poll()
  }
  return poll()
}

exports.parseSshConfig = parseSshConfig
exports.parseListeningPorts = parseListeningPorts
exports.listPortsCommand = listPortsCommand
exports.isValidPort = isValidPort
exports.targetOf = targetOf
exports.pickLocalPort = pickLocalPort

exports.default = Plugin.define({
  i18n: {
    en: {
      pill: "Preview",
      title: "Preview on the remote target",
      loading: "Checking open ports…",
      none: "No open ports found",
      port: "Port",
      refresh: "Check again",
      stop: "Disconnect",
      "manual.placeholder": "Other port…",
      "manual.open": "Open",
      "manual.invalid": "Enter a port between 1 and 65535",
      "list.failed": "Ports unavailable",
      "open.failed": "Could not open the port",
      "open.noPort": "No free local port found",
      "wsl.unreachable": "Not reachable at 127.0.0.1 inside WSL",
    },
    de: {
      pill: "Vorschau",
      title: "Vorschau auf dem Remote-Ziel",
      loading: "Offene Ports werden geprüft …",
      none: "Keine offenen Ports gefunden",
      port: "Port",
      refresh: "Neu prüfen",
      stop: "Trennen",
      "manual.placeholder": "Anderer Port…",
      "manual.open": "Öffnen",
      "manual.invalid": "Port zwischen 1 und 65535 eingeben",
      "list.failed": "Ports nicht abrufbar",
      "open.failed": "Port konnte nicht geöffnet werden",
      "open.noPort": "Kein freier lokaler Port gefunden",
      "wsl.unreachable": "Unter 127.0.0.1 in WSL nicht erreichbar",
    },
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
    const forwards = new Map() // forwardKey -> { localPort, port, child, kind }

    const keyOf = (session) => `${session.server.id}\n${session.directory}`
    const forwardKey = (session, port) => `${keyOf(session)}\n${port}`
    const store = (key, patch) => {
      const next = new Map(states())
      next.set(key, { ...next.get(key), ...patch })
      setStates(next)
    }

    const refresh = async (session, target) => {
      const key = keyOf(session)
      if (scanning.has(key)) return
      scanning.add(key)
      try {
        const ports = await scanPorts(target)
        store(key, { ports, error: undefined })
      } catch (error) {
        store(key, { ports: [], error: message(error) })
      } finally {
        scanning.delete(key)
      }
    }

    const stopForward = (fKey) => {
      const entry = forwards.get(fKey)
      if (!entry) return
      forwards.delete(fKey)
      entry.child?.kill()
    }

    const open = async (session, target, port) => {
      const key = keyOf(session)
      if (!isValidPort(port)) {
        store(key, { manualError: ctx.t("manual.invalid") })
        return
      }
      store(key, { manualError: undefined, opening: port })
      try {
        if (target.kind === "wsl") {
          if (await canConnect(port)) {
            ctx.system.openExternal(`http://127.0.0.1:${port}`)
            return
          }
          throw new Error(ctx.t("wsl.unreachable"))
        }
        const fKey = forwardKey(session, port)
        const existing = forwards.get(fKey)
        if (existing) {
          ctx.system.openExternal(`http://127.0.0.1:${existing.localPort}`)
          return
        }
        const localPort = await pickLocalPort(port, (candidate) => canConnect(candidate))
        if (!localPort) throw new Error(ctx.t("open.noPort"))
        const child = spawn(
          "ssh",
          ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-L", `${localPort}:127.0.0.1:${port}`, target.id],
          { stdio: "ignore", windowsHide: true },
        )
        child.once("exit", () => {
          forwards.delete(fKey)
          store(key, {})
        })
        forwards.set(fKey, { localPort, port, child, kind: target.kind })
        store(key, {})
        const ready = await waitReachable(localPort, FORWARD_WAIT_MS)
        if (!ready) {
          stopForward(fKey)
          throw new Error(ctx.t("open.failed"))
        }
        ctx.system.openExternal(`http://127.0.0.1:${localPort}`)
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
        if (!state) queueMicrotask(() => void refresh(session, target))
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
        if (!target) {
          container.textContent = ctx.t("none")
          return container
        }
        const key = keyOf(session)

        const status = document.createElement("p")
        const list = document.createElement("div")
        const activeList = document.createElement("div")
        const errorLine = document.createElement("p")
        const form = document.createElement("form")
        const portInput = document.createElement("input")
        portInput.type = "number"
        portInput.min = "1"
        portInput.max = "65535"
        portInput.placeholder = ctx.t("manual.placeholder")
        const submit = document.createElement("button")
        submit.type = "submit"
        submit.textContent = ctx.t("manual.open")
        form.append(portInput, submit)
        form.addEventListener("submit", (event) => {
          event.preventDefault()
          void open(session, target, Number(portInput.value))
        })
        const refreshButton = document.createElement("button")
        refreshButton.type = "button"
        refreshButton.textContent = ctx.t("refresh")
        refreshButton.addEventListener("click", () => void refresh(session, target))

        container.append(status, list, errorLine, activeList, form, refreshButton)

        createEffect(() => {
          const state = states().get(key)
          status.textContent = state?.error ? `${ctx.t("list.failed")}: ${state.error}` : ctx.t(state ? "title" : "loading")
          errorLine.textContent = state?.manualError ?? ""
          errorLine.style.display = state?.manualError ? "" : "none"

          list.replaceChildren()
          for (const port of state?.ports ?? []) {
            const row = document.createElement("button")
            row.type = "button"
            row.textContent = `${ctx.t("port")} ${port}`
            row.disabled = state?.opening === port
            row.addEventListener("click", () => void open(session, target, port))
            list.append(row)
          }
          if (!state?.ports?.length && !state?.error) {
            const empty = document.createElement("p")
            empty.textContent = ctx.t("none")
            list.append(empty)
          }

          activeList.replaceChildren()
          for (const [fKey, entry] of forwards) {
            if (!fKey.startsWith(`${key}\n`)) continue
            const row = document.createElement("div")
            const label = document.createElement("span")
            label.textContent = `${ctx.t("port")} ${entry.port} \u2192 127.0.0.1:${entry.localPort}`
            const stop = document.createElement("button")
            stop.type = "button"
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
      for (const entry of forwards.values()) entry.child?.kill()
      forwards.clear()
    }
  },
})
