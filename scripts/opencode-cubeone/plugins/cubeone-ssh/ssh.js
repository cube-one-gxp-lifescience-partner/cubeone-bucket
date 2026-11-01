/**
 * Pure parsing helpers for cubeone-ssh, kept free of Node file I/O so they are easy to unit-test.
 */

/** A token is a real host alias only if it has no OpenSSH pattern characters. */
function isConcreteAlias(token) {
  return !!token && !/[*?!]/.test(token)
}

/**
 * Parses an OpenSSH client config and returns one entry per concrete (non-pattern) Host alias:
 * { alias, hostName, user }. Wildcard blocks ("Host *") and Match blocks contribute no aliases and
 * are skipped, so their directives never attach to the wrong host.
 */
export function parseSshConfig(text) {
  const hosts = new Map()
  let aliases = []
  for (const raw of (text ?? "").split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, "").trim()
    if (!line) continue
    const match = line.match(/^(\S+)\s+(.*)$/)
    if (!match) continue
    const key = match[1].toLowerCase()
    const value = match[2].trim()
    if (key === "host") {
      aliases = value.split(/\s+/).filter(isConcreteAlias)
      for (const alias of aliases) if (!hosts.has(alias)) hosts.set(alias, {})
      continue
    }
    if (key === "match") {
      aliases = []
      continue
    }
    if (!aliases.length) continue
    if (key === "hostname") for (const alias of aliases) hosts.get(alias).hostName = value
    if (key === "user") for (const alias of aliases) hosts.get(alias).user = value
  }
  return [...hosts.entries()].map(([alias, info]) => ({ alias, hostName: info.hostName, user: info.user }))
}

/** The note for the model, or "" when the config has no concrete host. */
export function formatNote(hosts) {
  if (!hosts?.length) return ""
  const list = hosts
    .map((host) => (host.hostName ? `${host.alias} (${host.user ? `${host.user}@` : ""}${host.hostName})` : host.alias))
    .join(", ")
  return [
    `Bekannte Ziele aus der lokalen SSH-Konfiguration (~/.ssh/config): ${list}.`,
    "Verbindung über pty_spawn mit ssh, nicht-interaktiv mit -o BatchMode=yes -o StrictHostKeyChecking=accept-new, wie in der Shell-Regel beschrieben.",
  ].join(" ")
}
