/**
 * Automatic setup for Linux SSH targets that lack the OpenCode CLI, plus the pure command-building
 * and output-shaping helpers behind it. The exec function is injected so this stays testable without
 * a real ssh/powershell binary; see server.js for the real one (node:child_process execFile).
 */

const READY = "__READY__"
const MISSING = "__MISSING__"
const TAIL_CHARS = 500

/** ssh argv that checks, non-interactively, whether `opencode` resolves on the target's default PATH. */
export function probeArgs(configPath, alias) {
  return [
    "-F",
    configPath,
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=8",
    "-o",
    "StrictHostKeyChecking=accept-new",
    alias,
    `command -v opencode >/dev/null 2>&1 && echo ${READY} || echo ${MISSING}`,
  ]
}

/** PowerShell argv that runs the shared remote installer for exactly one host. */
export function installArgs(scriptPath, alias) {
  return ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath, "-OnlyHost", alias, "-SkipWsl"]
}

function message(error) {
  return error instanceof Error ? error.message : String(error)
}

/** Keeps toasts and logs short; the install script never prints secrets, so truncating here is safe. */
export function tail(text, limit = TAIL_CHARS) {
  const trimmed = (text ?? "").trim()
  return trimmed.length > limit ? `…${trimmed.slice(-limit)}` : trimmed
}

export function parseProbe(stdout) {
  const text = stdout ?? ""
  if (text.includes(READY)) return "ready"
  if (text.includes(MISSING)) return "missing"
  return "unknown"
}

/**
 * Probes one host and, only when it is reachable but missing the CLI, runs the shared installer for
 * it. Never throws: every outcome, including a failed install (e.g. a VM CPU too old for Bun), comes
 * back as a status plus a short, secret-free detail string.
 */
export async function ensureHost({ alias, configPath, scriptPath, exec }) {
  let probe
  try {
    probe = await exec("ssh", probeArgs(configPath, alias), { timeoutMs: 8_000 })
  } catch (error) {
    return { alias, status: "unreachable", detail: tail(message(error)) }
  }
  const state = parseProbe(probe?.stdout)
  if (state === "ready") return { alias, status: "ready" }
  if (state === "unknown") return { alias, status: "unreachable", detail: "Unerwartete Antwort von ssh." }

  try {
    const result = await exec("powershell.exe", installArgs(scriptPath, alias), { timeoutMs: 5 * 60_000 })
    return { alias, status: "installed", detail: tail(result?.stdout) }
  } catch (error) {
    return { alias, status: "failed", detail: tail(message(error)) }
  }
}

/**
 * Runs ensureHost for every host that is not already being checked and was not checked within
 * intervalMs, serialised one host at a time so a slow or hanging SSH target cannot starve the others.
 * Returns the outcomes actually attempted this call, for callers that want to report or log them.
 */
export function createMaintainer({ configPath, scriptPath, exec, intervalMs }) {
  const lastAttempt = new Map()
  let running = false

  return async function maintain(hosts) {
    if (running) return []
    running = true
    const now = Date.now()
    const due = hosts.filter((host) => now - (lastAttempt.get(host.alias) ?? 0) >= intervalMs)
    const results = []
    try {
      for (const host of due) {
        lastAttempt.set(host.alias, Date.now())
        results.push(await ensureHost({ alias: host.alias, configPath, scriptPath, exec }))
      }
    } finally {
      running = false
    }
    return results
  }
}
