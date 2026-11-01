const STATUS_TEXT = {
  needs_auth: "Anmeldung nötig",
  failed: "nicht erreichbar",
  pending: "startet noch",
}

/** The note for the model, or "" when every enabled server is connected. */
export function unavailableNote(servers) {
  const missing = (servers ?? []).filter((server) => STATUS_TEXT[server?.status?.status])
  if (!missing.length) return ""
  const list = missing.map((server) => `${server.title || server.name} (${STATUS_TEXT[server.status.status]})`).join(", ")
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
