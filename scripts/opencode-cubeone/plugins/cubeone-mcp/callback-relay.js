import { spawn as nodeSpawn } from "node:child_process"

const HOST = "127.0.0.1"
const DEFAULT_TIMEOUT_MS = 30000
const MAX_TARGET_LENGTH = 4096
const CODE_TIMEOUT = 124
const CODE_UNAVAILABLE = 127
const CODE_CANCELLED = 130
const CODE_FAILED = 1
const INVALID_INPUT = "Invalid callback relay input"

/** Only the two callback paths with a non-empty query. No quotes, backslash, backtick, dollar, hash or whitespace. */
const TARGET_PATTERN = /^(?:\/callback|\/mcp\/oauth\/callback)\?(?:%[0-9A-Fa-f]{2}|[A-Za-z0-9\-._~&=+:@/?,;])+$/

/** The tools in the order they are tried. The URL goes through stdin only, never through the arguments. */
const WINDOWS_ATTEMPTS = [
  {
    command: "curl.exe",
    args: ["--disable", "-fsS", "--noproxy", "*", "--max-time", "20", "--output", "NUL", "--config", "-"],
    stdin: (url) => `url = "${url}"\n`,
  },
]
const POSIX_ATTEMPTS = [
  {
    command: "curl",
    args: ["--disable", "-fsS", "--noproxy", "*", "--max-time", "20", "--output", "/dev/null", "--config", "-"],
    stdin: (url) => `url = "${url}"\n`,
  },
  {
    command: "wget",
    args: ["-q", "--no-proxy", "--max-redirect=0", "-T", "20", "-O", "/dev/null", "-i", "-"],
    stdin: (url) => `${url}\n`,
  },
]

/** The local URL for the validated input. Throws a fixed error that does not repeat the input. */
function localUrl(input) {
  const port = input?.port
  const target = input?.target
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(INVALID_INPUT)
  if (typeof target !== "string" || target.length > MAX_TARGET_LENGTH || !TARGET_PATTERN.test(target)) {
    throw new Error(INVALID_INPUT)
  }
  return `http://${HOST}:${port}${target}`
}

function stop(child) {
  try {
    child?.kill()
  } catch {
    // The process is already gone.
  }
}

/**
 * Calls the local OAuth callback of the MCP login with the native download tool of the host.
 * The callback URL carries the authorization code. It is written to stdin of the tool only and
 * never appears in arguments, errors or output.
 *
 * The result is the exit code: 0 on success, 124 on timeout, 130 on cancellation, 127 when no tool
 * could be started, otherwise the code of the last tool (1 if it ended by signal).
 * Invalid input throws before anything is started.
 *
 * @param {{port: number, target: string}} input - Local port (1..65535) and the callback path with query
 * @param {Object} [options={}] - Test seams
 * @param {string} [options.platform=process.platform] - Operating system, "win32" uses curl.exe only
 * @param {Function} [options.spawn=child_process.spawn] - Process starter
 * @param {AbortSignal} [options.signal] - Cancels the relay and kills the running tool
 * @param {number} [options.timeoutMs=30000] - Limit for the whole sequence
 * @returns {Promise<number>} Exit code
 *
 * @author Marvin Fenßel
 * @created 09.11.2026
 * @changelog 09.11.2026 - Initial implementation
 */
export function relayCallback(input, options = {}) {
  const url = localUrl(input)
  const platform = options.platform ?? process.platform
  const spawn = options.spawn ?? nodeSpawn
  const signal = options.signal
  const timeoutMs =
    Number.isFinite(options.timeoutMs) && options.timeoutMs > 0 ? options.timeoutMs : DEFAULT_TIMEOUT_MS
  const attempts = platform === "win32" ? WINDOWS_ATTEMPTS : POSIX_ATTEMPTS

  return new Promise((resolve) => {
    let settled = false
    let child = null
    let timer = null

    const finish = (code) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      signal?.removeEventListener("abort", onAbort)
      stop(child)
      resolve(code)
    }
    const onAbort = () => finish(CODE_CANCELLED)

    const run = (index) => {
      const attempt = attempts[index]
      let over = false
      const end = (code) => {
        if (over || settled) return
        over = true
        if (code === 0 || index + 1 >= attempts.length) finish(code)
        else run(index + 1)
      }
      try {
        child = spawn(attempt.command, attempt.args, {
          shell: false,
          windowsHide: true,
          stdio: ["pipe", "ignore", "ignore"],
        })
      } catch {
        // The tool cannot be started. The next one is tried.
        child = null
        end(CODE_UNAVAILABLE)
        return
      }
      const current = child
      if (!current || typeof current.on !== "function") {
        end(CODE_UNAVAILABLE)
        return
      }
      current.on("error", () => {
        stop(current)
        end(CODE_UNAVAILABLE)
      })
      current.on("close", (exitCode) => end(Number.isInteger(exitCode) ? exitCode : CODE_FAILED))
      try {
        current.stdin?.on("error", () => {
          // A broken pipe ends the tool with a failure code.
        })
        current.stdin?.end(attempt.stdin(url))
      } catch {
        // The timer bounds the sequence if the tool never ends.
      }
    }

    if (signal?.aborted) {
      finish(CODE_CANCELLED)
      return
    }
    signal?.addEventListener("abort", onAbort, { once: true })
    timer = setTimeout(() => finish(CODE_TIMEOUT), timeoutMs)
    run(0)
  })
}
