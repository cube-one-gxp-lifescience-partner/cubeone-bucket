import { execFile } from "node:child_process"
import { readFileSync, statSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { formatNote, parseSshConfig } from "./ssh.js"
import { createMaintainer, ensureHost } from "./setup.js"

const RELOAD_MS = 30_000
const DEFAULT_CHECK_INTERVAL_MS = 10 * 60_000
const MAX_BUFFER = 10 * 1024 * 1024

function expand(file) {
  return file.startsWith("~/") || file.startsWith("~\\") ? path.join(os.homedir(), file.slice(2)) : file
}

function readConfig(configPath) {
  try {
    return readFileSync(configPath, "utf8")
  } catch {
    return ""
  }
}

function mtime(configPath) {
  try {
    return statSync(configPath).mtimeMs
  } catch {
    return 0
  }
}

/** Real exec for setup.js: no shell, so a host alias or path never needs quoting. */
function execFileAsync(command, args, { timeoutMs } = {}) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { timeout: timeoutMs, maxBuffer: MAX_BUFFER, windowsHide: true }, (error, stdout, stderr) => {
      if (error) {
        error.message = stderr?.trim() ? `${error.message}: ${stderr.trim()}` : error.message
        reject(error)
        return
      }
      resolve({ stdout, stderr })
    })
  })
}

/** ~/.ssh/config can also list Windows machines (coding-vm-win-*); those never get a Linux setup. */
function linuxTargets(hosts) {
  return hosts.filter((host) => !/-win-/.test(host.alias))
}

export default {
  id: "cubeone-ssh",
  async setup(ctx) {
    const configPath = expand(typeof ctx.options?.configPath === "string" ? ctx.options.configPath : "~/.ssh/config")
    let hosts = parseSshConfig(readConfig(configPath))
    let loadedMtime = mtime(configPath)
    let checkedAt = Date.now()

    // The coding-vms-ssh package can rewrite this file after cubeone-ssh has already loaded it once.
    const currentHosts = () => {
      if (Date.now() - checkedAt > RELOAD_MS) {
        checkedAt = Date.now()
        const next = mtime(configPath)
        if (next !== loadedMtime) {
          loadedMtime = next
          hosts = parseSshConfig(readConfig(configPath))
        }
      }
      return hosts
    }

    // Only the Windows desktop acts as the orchestrator for its SSH targets; this same package also
    // ships to each Linux target's own OpenCode server (New-LinuxPayload), where none of this applies.
    const onWindows = process.platform === "win32"
    const autoSetup = onWindows && ctx.options?.autoSetup !== false
    const scriptPath =
      typeof ctx.options?.scriptPath === "string" && ctx.options.scriptPath
        ? ctx.options.scriptPath
        : path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "Install-OpenCodeRemote.ps1")
    const checkIntervalMs = Number.isFinite(ctx.options?.checkIntervalMs) ? Number(ctx.options.checkIntervalMs) : DEFAULT_CHECK_INTERVAL_MS
    const maintain = autoSetup ? createMaintainer({ configPath, scriptPath, exec: execFileAsync, intervalMs: checkIntervalMs }) : undefined

    await ctx.session.hook("context", (input) => {
      try {
        const note = formatNote(currentHosts())
        if (note) input.system = [...(input.system ?? []), { type: "text", text: note }]
      } catch {
        // formatNote/currentHosts failing must not block the turn or skip the auto-setup check below.
      }
      // Fire-and-forget: cheap when nothing is due, and never slows down the turn that triggered it.
      if (maintain) void maintain(linuxTargets(currentHosts())).catch(() => {})
    })

    if (!onWindows) return

    await ctx.tool.transform((editor) => {
      editor.add({
        name: "ssh_einrichten",
        description:
          "Richtet OpenCode auf einem SSH-Ziel aus der lokalen Konfiguration (~/.ssh/config) ein, falls die opencode-CLI dort noch fehlt, und prüft dafür zuerst, ob das Ziel gerade erreichbar ist. Nur verwenden, wenn ein Ziel als nicht erreichbar oder nicht eingerichtet gemeldet wird.",
        input: {
          type: "object",
          properties: { ziel: { type: "string", description: "Host-Alias aus ~/.ssh/config, z. B. coding-vm-2" } },
          required: ["ziel"],
          additionalProperties: false,
        },
        options: { permission: "ssh" },
        execute: async (input) => {
          const alias = String(input?.ziel ?? "").trim()
          const known = linuxTargets(currentHosts()).some((host) => host.alias === alias)
          if (!alias || !known) {
            throw new Error(`Fehler: "${input?.ziel}" steht nicht als SSH-Ziel in ~/.ssh/config.`)
          }
          const result = await ensureHost({ alias, configPath, scriptPath, exec: execFileAsync })
          if (result.status === "ready") return { content: `${alias} ist bereits erreichbar und eingerichtet.` }
          if (result.status === "installed") return { content: `${alias} ist jetzt eingerichtet.\n\n${result.detail ?? ""}`.trim() }
          if (result.status === "unreachable") throw new Error(`Fehler: ${alias} ist gerade nicht per SSH erreichbar.${result.detail ? ` (${result.detail})` : ""}`)
          throw new Error(`Fehler: Einrichtung auf ${alias} fehlgeschlagen.${result.detail ? ` ${result.detail}` : ""}`)
        },
      })
    })
  },
}
