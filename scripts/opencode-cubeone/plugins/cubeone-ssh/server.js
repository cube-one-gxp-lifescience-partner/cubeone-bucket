import { readFileSync, statSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { formatNote, parseSshConfig } from "./ssh.js"

const RELOAD_MS = 30_000

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

    await ctx.session.hook("context", (input) => {
      try {
        const note = formatNote(currentHosts())
        if (note) input.system = [...(input.system ?? []), { type: "text", text: note }]
      } catch {
        return
      }
    })
  },
}
