import { relayCallback } from "./callback-relay.js"

// Rpc.define preserves this plain definition; keep the GUI's inline contract in sync.
export const CallbackRelay = {
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

const STATUS_TEXT = {
  needs_auth: "Anmeldung nötig",
  failed: "nicht erreichbar",
  pending: "startet noch",
}

/** The note server still introduces itself as Outline. The config name is cube-note. */
export function labelOf(server) {
  if (server?.name === "cube-note" || server?.title === "Outline") return "cube note"
  return server?.title || server?.name || ""
}

/** The note for the model, or "" when every enabled server is connected. */
export function unavailableNote(servers) {
  const missing = (servers ?? []).filter((server) => STATUS_TEXT[server?.status?.status])
  if (!missing.length) return ""
  const list = missing.map((server) => `${labelOf(server)} (${STATUS_TEXT[server.status.status]})`).join(", ")
  const login = missing.some((server) => server.status.status === "needs_auth")
  return [
    `Diese MCP-Server stehen in dieser Sitzung nicht zur Verfügung: ${list}. Ihre Werkzeuge fehlen.`,
    login
      ? "Braucht die Aufgabe einen davon, sag das dem Benutzer: Die Anmeldung startet über die Schaltfläche MCP über dem Eingabefeld."
      : "Braucht die Aufgabe einen davon, sag das dem Benutzer.",
  ].join(" ")
}

export default {
  id: "cubeone-mcp",
  async setup(ctx) {
    await ctx.rpc.register(CallbackRelay, {
      send: async (input, context) => relayCallback(input, { signal: context.signal }),
    })
    const directories = new Map()
    await ctx.session.hook("context", async (input) => {
      try {
        let directory = directories.get(input.sessionID)
        if (directory === undefined) {
          const info = await ctx.session.get({ sessionID: input.sessionID })
          directory = info?.location?.directory ?? ""
          directories.set(input.sessionID, directory)
        }
        const listed = await ctx.mcp.list(directory ? { location: { directory } } : undefined)
        const note = unavailableNote(listed?.data)
        if (note) input.system = [...(input.system ?? []), { type: "text", text: note }]
      } catch {
        return
      }
    })
  },
}
