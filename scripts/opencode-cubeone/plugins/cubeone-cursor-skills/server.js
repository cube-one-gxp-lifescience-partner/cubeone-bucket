import { discoverCursorSkills, stamp } from "./cursor-skills.js"

const RELOAD_MS = 10_000

/** Rescans `directory` on disk at most every `RELOAD_MS`, and only re-parses rule files that actually changed. */
function liveSkills(directory) {
  let cachedStamp
  let cached = []
  let checkedAt = 0
  return () => {
    const now = Date.now()
    if (cachedStamp !== undefined && now - checkedAt <= RELOAD_MS) return cached
    checkedAt = now
    const next = stamp(directory)
    if (next === cachedStamp) return cached
    cachedStamp = next
    cached = discoverCursorSkills(directory)
    return cached
  }
}

export default {
  id: "cubeone-cursor-skills",
  async setup(ctx) {
    const sessions = new Map()
    const registeredDirs = new Set()

    const stateOf = (sessionID) => {
      let state = sessions.get(sessionID)
      if (!state) {
        state = { directory: undefined }
        sessions.set(sessionID, state)
      }
      return state
    }
    const directoryOf = async (sessionID, state) => {
      if (state.directory === undefined) {
        const info = await ctx.session.get({ sessionID }).catch(() => undefined)
        state.directory = info?.location?.directory ?? info?.directory ?? ctx.location?.directory ?? ""
      }
      return state.directory
    }

    // One registration per project directory, kept fresh by rescanning on every future call instead of
    // snapshotting once: a rule edited mid-session is picked up the next time the skill list is built.
    const ensureRegistered = async (directory) => {
      if (!directory || registeredDirs.has(directory)) return
      registeredDirs.add(directory)
      const currentSkills = liveSkills(directory)
      let previousIds = new Set()
      await ctx.skill.transform((editor) => {
        const discovered = currentSkills()
        const ids = new Set(discovered.map((skill) => skill.id))
        for (const id of previousIds) {
          if (!ids.has(id) && editor.get(id)) editor.remove(id)
        }
        for (const skill of discovered) {
          if (editor.get(skill.id)) editor.update(skill.id, (entry) => Object.assign(entry, skill))
          else editor.add(skill)
        }
        previousIds = ids
      })
    }

    await ctx.session.hook("context", async (input) => {
      const state = stateOf(input.sessionID)
      const directory = await directoryOf(input.sessionID, state)
      await ensureRegistered(directory)
    })
  },
}
