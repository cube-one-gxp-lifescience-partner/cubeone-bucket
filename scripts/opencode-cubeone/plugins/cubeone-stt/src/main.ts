import { execFileSync } from "node:child_process"
import type { Plugin } from "@opencode/plugin/gui"
import { Transcriber } from "./contract"

const DEFAULT_ENDPOINT = "https://eu.openrouter.ai/api/v1"
const DEFAULT_MODEL = "mistralai/voxtral-mini-transcribe-3-0"
const REQUEST_TIMEOUT_MS = 90_000

function option(options: Readonly<Record<string, unknown>>, key: string, fallback: string) {
  const value = options[key]
  return typeof value === "string" && value.trim() ? value.trim() : fallback
}

// The desktop app keeps the environment it was started with, so a key that was
// set later is only visible in the registry until the next sign-in.
function readApiKey(): string {
  const fromEnv = process.env.OPENROUTER_API_KEY?.trim()
  if (fromEnv) return fromEnv
  if (process.platform !== "win32") return ""
  for (const hive of ["HKCU\\Environment", "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment"]) {
    try {
      const output = execFileSync("reg.exe", ["query", hive, "/v", "OPENROUTER_API_KEY"], {
        encoding: "utf8",
        windowsHide: true,
        stdio: ["ignore", "pipe", "ignore"],
      })
      const match = /OPENROUTER_API_KEY\s+REG_(?:EXPAND_)?SZ\s+(\S+)/.exec(output)
      if (match) return match[1]
    } catch {
      continue
    }
  }
  return ""
}

export const main: Plugin.MainSetup = (ctx) => {
  const endpoint = option(ctx.options, "endpoint", DEFAULT_ENDPOINT).replace(/\/+$/, "")
  const model = option(ctx.options, "model", DEFAULT_MODEL)
  const language = option(ctx.options, "language", "")

  if (!endpoint.startsWith("https://")) {
    ctx.log.write("error", "cubeone-stt endpoint must use https", { endpoint })
  }

  ctx.provide(Transcriber, {
    status: () => ({ configured: readApiKey() !== "", model, endpoint }),
    transcribe: async (input, caller) => {
      if (!endpoint.startsWith("https://")) throw new Error("Der STT-Endpunkt muss HTTPS verwenden.")
      const apiKey = readApiKey()
      if (!apiKey) throw new Error("OPENROUTER_API_KEY ist nicht gesetzt.")
      if (!input.audio) throw new Error("Die Aufnahme ist leer.")

      const body: Record<string, unknown> = {
        model,
        input_audio: { data: input.audio, format: input.format },
        provider: { zdr: true, data_collection: "deny" },
      }
      if (language) body.language = language

      const response = await fetch(`${endpoint}/audio/transcriptions`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
          "User-Agent": "cubeone-stt/1.0",
          "HTTP-Referer": "https://cubeone.de",
          "X-Title": "OpenCode cube one",
        },
        body: JSON.stringify(body),
        signal: AbortSignal.any([caller.signal, ctx.signal, AbortSignal.timeout(REQUEST_TIMEOUT_MS)]),
      })

      if (!response.ok) {
        let detail = ""
        try {
          const payload = (await response.json()) as { error?: { message?: string } }
          detail = payload.error?.message ?? ""
        } catch {
          detail = ""
        }
        ctx.log.write("warn", "cubeone-stt transcription failed", { status: response.status })
        throw new Error(`OpenRouter antwortet mit ${response.status}${detail ? `: ${detail}` : ""}`)
      }

      const result = (await response.json()) as { text?: string }
      return { text: (result.text ?? "").trim() }
    },
  })
}
