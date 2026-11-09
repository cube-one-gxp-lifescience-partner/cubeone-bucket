import assert from "node:assert/strict"
import { spawn as realSpawn, spawnSync } from "node:child_process"
import { EventEmitter } from "node:events"
import http from "node:http"
import test from "node:test"
import { relayCallback } from "../callback-relay.js"

const TARGET = "/callback?code=FIXTURE%2Fcode%3D&state=s1"
const URL_TEXT = `http://127.0.0.1:4096${TARGET}`

/** A fake child process. `script` runs once the stdin has been closed. */
function fakeChild(script) {
  const child = new EventEmitter()
  child.stdinText = null
  child.killed = false
  child.stdin = Object.assign(new EventEmitter(), {
    end(text) {
      child.stdinText = text
      if (script) setImmediate(() => script(child))
    },
  })
  child.kill = () => {
    child.killed = true
    return true
  }
  return child
}

/** A spawn double that records the calls and takes its behavior per call from `scripts`. */
function fakeSpawn(...scripts) {
  const calls = []
  const spawn = (command, args, spawnOptions) => {
    const script = scripts[calls.length]
    const call = { command, args, spawnOptions, child: null }
    calls.push(call)
    if (script instanceof Error) throw script
    call.child = fakeChild(script)
    return call.child
  }
  return { spawn, calls }
}

const exits = (code) => (child) => child.emit("close", code, null)
const errors = (code) => (child) => child.emit("error", Object.assign(new Error("spawn failed"), { code }))
const never = () => {}

test("Windows runs curl.exe with NUL and the URL only on stdin", async () => {
  const { spawn, calls } = fakeSpawn(exits(0))
  assert.equal(await relayCallback({ port: 4096, target: TARGET }, { platform: "win32", spawn }), 0)
  assert.equal(calls.length, 1)
  assert.equal(calls[0].command, "curl.exe")
  assert.deepEqual(calls[0].args, ["--disable", "-fsS", "--noproxy", "*", "--max-time", "20", "--output", "NUL", "--config", "-"])
  assert.deepEqual(calls[0].spawnOptions, {
    shell: false,
    windowsHide: true,
    stdio: ["pipe", "ignore", "ignore"],
  })
  assert.equal(calls[0].child.stdinText, `url = "${URL_TEXT}"\n`)
  assert.ok(!calls[0].args.join(" ").includes("FIXTURE"))
})

test("Windows has no POSIX fallback and returns the failure code", async () => {
  const { spawn, calls } = fakeSpawn(exits(22), exits(0))
  assert.equal(await relayCallback({ port: 4096, target: TARGET }, { platform: "win32", spawn }), 22)
  assert.equal(calls.length, 1)
  const missing = fakeSpawn(errors("ENOENT"), exits(0))
  assert.equal(
    await relayCallback({ port: 4096, target: TARGET }, { platform: "win32", spawn: missing.spawn }),
    127,
  )
  assert.equal(missing.calls.length, 1)
})

test("Linux runs curl with /dev/null and the URL only on stdin", async () => {
  const { spawn, calls } = fakeSpawn(exits(0))
  assert.equal(await relayCallback({ port: 4096, target: TARGET }, { platform: "linux", spawn }), 0)
  assert.equal(calls.length, 1)
  assert.equal(calls[0].command, "curl")
  assert.deepEqual(calls[0].args, ["--disable", "-fsS", "--noproxy", "*", "--max-time", "20", "--output", "/dev/null", "--config", "-"])
  assert.equal(calls[0].spawnOptions.shell, false)
  assert.equal(calls[0].child.stdinText, `url = "${URL_TEXT}"\n`)
  assert.ok(!calls[0].args.join(" ").includes("FIXTURE"))
})

test("Linux falls back to wget when curl fails or is missing", async () => {
  for (const first of [exits(7), errors("ENOENT"), new Error("EACCES"), (child) => child.emit("close", null, "SIGSEGV")]) {
    const { spawn, calls } = fakeSpawn(first, exits(0))
    assert.equal(await relayCallback({ port: 4096, target: TARGET }, { platform: "linux", spawn }), 0)
    assert.equal(calls.length, 2)
    assert.equal(calls[1].command, "wget")
    assert.deepEqual(calls[1].args, ["-q", "--no-proxy", "--max-redirect=0", "-T", "20", "-O", "/dev/null", "-i", "-"])
    assert.equal(calls[1].child.stdinText, `${URL_TEXT}\n`)
    assert.ok(!calls[1].args.join(" ").includes("FIXTURE"))
  }
})

test("Darwin behaves like Linux", async () => {
  const { spawn, calls } = fakeSpawn(exits(1), exits(0))
  assert.equal(await relayCallback({ port: 4096, target: TARGET }, { platform: "darwin", spawn }), 0)
  assert.deepEqual(calls.map((call) => call.command), ["curl", "wget"])
})

test("failure codes: last tool code, 127 when nothing starts, 1 after a signal", async () => {
  const input = { port: 4096, target: TARGET }
  assert.equal(await relayCallback(input, { platform: "linux", ...fakeSpawn(exits(22), exits(4)) }), 4)
  assert.equal(await relayCallback(input, { platform: "linux", ...fakeSpawn(errors("ENOENT"), errors("ENOENT")) }), 127)
  assert.equal(await relayCallback(input, { platform: "linux", ...fakeSpawn(new Error("x"), new Error("y")) }), 127)
  const signaled = (child) => child.emit("close", null, "SIGKILL")
  assert.equal(await relayCallback(input, { platform: "linux", ...fakeSpawn(signaled, signaled) }), 1)
})

test("invalid input is rejected before anything is started", () => {
  const bad = [
    null,
    undefined,
    {},
    { port: 0, target: TARGET },
    { port: 65536, target: TARGET },
    { port: -1, target: TARGET },
    { port: 1.5, target: TARGET },
    { port: "4096", target: TARGET },
    { port: Number.NaN, target: TARGET },
    { port: 4096 },
    { port: 4096, target: 42 },
    { port: 4096, target: "" },
    { port: 4096, target: "/callback" },
    { port: 4096, target: "/callback?" },
    { port: 4096, target: "callback?code=1" },
    { port: 4096, target: "/other?code=1" },
    { port: 4096, target: "//evil.example/callback?code=1" },
    { port: 4096, target: "http://evil.example/callback?code=1" },
    { port: 4096, target: "/callback/../admin?code=1" },
    { port: 4096, target: "/callbackx?code=1" },
    { port: 4096, target: "/mcp/oauth/callback/x?code=1" },
    { port: 4096, target: "/callback?code=1#frag" },
    { port: 4096, target: '/callback?code="1"' },
    { port: 4096, target: "/callback?code='1'" },
    { port: 4096, target: "/callback?code=1\n" },
    { port: 4096, target: "/callback?code=1\r\nurl = x" },
    { port: 4096, target: "/callback?code=`id`" },
    { port: 4096, target: "/callback?code=$(id)" },
    { port: 4096, target: "/callback?code=$HOME" },
    { port: 4096, target: "/callback?code=a\\b" },
    { port: 4096, target: "/callback?code=a b" },
    { port: 4096, target: "/callback?code=a|b" },
    { port: 4096, target: "/callback?code=a%b" },
    { port: 4096, target: "/callback?code=a%2" },
    { port: 4096, target: "/callback?code=a%zz" },
    { port: 4096, target: "/callback?code=%G1" },
    { port: 4096, target: "/callback?code=%" },
    { port: 4096, target: "/callback?code=1&" + "a".repeat(5000) },
    { port: 4096, target: "/callback?code=ä" },
  ]
  for (const input of bad) {
    const { spawn, calls } = fakeSpawn(exits(0))
    assert.throws(
      () => relayCallback(input, { platform: "linux", spawn }),
      (error) => error instanceof Error && error.message === "Invalid callback relay input",
      JSON.stringify(input)?.slice(0, 60),
    )
    assert.equal(calls.length, 0)
  }
})

test("both callback paths and percent encoded queries are accepted", async () => {
  for (const target of ["/callback?code=a", "/mcp/oauth/callback?code=a%20b%2Fc&state=x%3D%3D"]) {
    const { spawn, calls } = fakeSpawn(exits(0))
    assert.equal(await relayCallback({ port: 65535, target }, { platform: "linux", spawn }), 0)
    assert.equal(calls[0].child.stdinText, `url = "http://127.0.0.1:65535${target}"\n`)
  }
  const max = "/callback?code=" + "a".repeat(4096 - "/callback?code=".length)
  assert.equal(max.length, 4096)
  assert.equal(await relayCallback({ port: 1, target: max }, { platform: "linux", ...fakeSpawn(exits(0)) }), 0)
})

test("a pre-aborted signal starts nothing", async () => {
  const { spawn, calls } = fakeSpawn(exits(0))
  const controller = new AbortController()
  controller.abort()
  assert.equal(await relayCallback({ port: 4096, target: TARGET }, { platform: "linux", spawn, signal: controller.signal }), 130)
  assert.equal(calls.length, 0)
})

test("abort kills the running tool and removes the listener", async () => {
  const { spawn, calls } = fakeSpawn(never)
  const controller = new AbortController()
  const pending = relayCallback({ port: 4096, target: TARGET }, { platform: "linux", spawn, signal: controller.signal })
  await new Promise((resolve) => setImmediate(resolve))
  controller.abort()
  assert.equal(await pending, 130)
  assert.equal(calls[0].child.killed, true)
  assert.equal(calls.length, 1)
  // A late close of the killed tool changes nothing and starts no fallback.
  calls[0].child.emit("close", 1, null)
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(calls.length, 1)
})

test("abort during the fallback kills wget", async () => {
  const { spawn, calls } = fakeSpawn(exits(7), never)
  const controller = new AbortController()
  const pending = relayCallback({ port: 4096, target: TARGET }, { platform: "linux", spawn, signal: controller.signal })
  while (calls.length < 2 || !calls[1].child.stdinText) await new Promise((resolve) => setImmediate(resolve))
  controller.abort()
  assert.equal(await pending, 130)
  assert.equal(calls[1].child.killed, true)
})

test("no abort listener stays on the signal after completion", async () => {
  const controller = new AbortController()
  let added = 0
  let removed = 0
  const signal = {
    aborted: false,
    addEventListener: (...args) => {
      added += 1
      controller.signal.addEventListener(...args)
    },
    removeEventListener: (...args) => {
      removed += 1
      controller.signal.removeEventListener(...args)
    },
  }
  assert.equal(await relayCallback({ port: 4096, target: TARGET }, { platform: "linux", ...fakeSpawn(exits(0)), signal }), 0)
  assert.equal(added, 1)
  assert.equal(removed, 1)
  controller.abort()
})

test("timeout kills the tool and returns 124", async () => {
  const { spawn, calls } = fakeSpawn(never)
  assert.equal(await relayCallback({ port: 4096, target: TARGET }, { platform: "linux", spawn, timeoutMs: 20 }), 124)
  assert.equal(calls[0].child.killed, true)
})

test("the timeout bounds the whole sequence including the fallback", async () => {
  const { spawn, calls } = fakeSpawn(
    (child) => setTimeout(() => child.emit("close", 7, null), 30),
    never,
  )
  const started = Date.now()
  assert.equal(await relayCallback({ port: 4096, target: TARGET }, { platform: "linux", spawn, timeoutMs: 80 }), 124)
  assert.ok(Date.now() - started < 1000)
  assert.equal(calls.length, 2)
  assert.equal(calls[1].child.killed, true)
})

test("a tool that ends before the timeout leaves no timer behind", async () => {
  const started = Date.now()
  assert.equal(
    await relayCallback({ port: 4096, target: TARGET }, { platform: "linux", ...fakeSpawn(exits(0)), timeoutMs: 60000 }),
    0,
  )
  assert.ok(Date.now() - started < 1000)
})

test("child errors, stdin errors and event races settle once", async () => {
  const input = { port: 4096, target: TARGET }
  // error, then close: only the error counts, and the fallback runs once.
  const both = fakeSpawn(
    (child) => {
      child.emit("error", new Error("boom"))
      child.emit("close", 0, null)
    },
    exits(0),
  )
  assert.equal(await relayCallback(input, { platform: "linux", spawn: both.spawn }), 0)
  assert.equal(both.calls.length, 2)
  // close twice
  const twice = fakeSpawn((child) => {
    child.emit("close", 3, null)
    child.emit("close", 0, null)
  })
  assert.equal(await relayCallback(input, { platform: "win32", spawn: twice.spawn }), 3)
  // stdin error alone: the exit code decides, the error is swallowed.
  const stdinError = fakeSpawn((child) => {
    child.stdin.emit("error", new Error("EPIPE"))
    child.emit("close", 23, null)
  })
  assert.equal(await relayCallback(input, { platform: "win32", spawn: stdinError.spawn }), 23)
  // stdin.end throws
  const throwing = fakeSpawn(exits(0))
  const spawn = (...args) => {
    const child = throwing.spawn(...args)
    child.stdin.end = () => {
      throw new Error("write after end")
    }
    setImmediate(() => child.emit("close", 5, null))
    return child
  }
  assert.equal(await relayCallback(input, { platform: "win32", spawn }), 5)
  // spawn returns nothing usable
  assert.equal(await relayCallback(input, { platform: "win32", spawn: () => null }), 127)
})

test("errors and results never contain the callback URL", async () => {
  const secret = "SECRETFIXTURE"
  const target = `/callback?code=${secret}`
  const results = [
    await relayCallback({ port: 4096, target }, { platform: "linux", ...fakeSpawn(new Error(`${secret}`), errors("ENOENT")) }),
    await relayCallback({ port: 4096, target }, { platform: "win32", ...fakeSpawn(exits(22)) }),
  ]
  assert.deepEqual(results, [127, 22])
  assert.throws(
    () => relayCallback({ port: 4096, target: `/callback?code=${secret}"` }, { spawn: fakeSpawn().spawn }),
    (error) => !error.message.includes(secret) && error.stack !== undefined && !error.stack.includes(secret),
  )
})

test("real curl.exe delivers the percent encoded query unchanged", { skip: process.platform !== "win32" }, async () => {
  const probe = spawnSync("curl.exe", ["--version"], { windowsHide: true, stdio: "ignore" })
  if (probe.status !== 0) return
  const seen = []
  const server = http.createServer((request, response) => {
    seen.push(request.url)
    response.end("ok")
  })
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  const { port } = server.address()
  const query = "code=Fx%2F%3D%2B%20y~._-&state=a%26b%3Dc&extra=1,2;3:4@5"
  const spawnCalls = []
  const spawn = (command, args, spawnOptions) => {
    spawnCalls.push({ command, args })
    return realSpawn(command, args, spawnOptions)
  }
  try {
    for (const path of ["/callback", "/mcp/oauth/callback"]) {
      assert.equal(await relayCallback({ port, target: `${path}?${query}` }, { platform: "win32", spawn }), 0)
    }
    assert.deepEqual(seen, [`/callback?${query}`, `/mcp/oauth/callback?${query}`])
    assert.equal(spawnCalls.length, 2)
    for (const { command, args } of spawnCalls) {
      assert.equal(command, "curl.exe")
      assert.ok(!args.join(" ").includes("Fx"))
      assert.ok(!args.join(" ").includes("127.0.0.1"))
    }
    // A closed endpoint gives a non zero code.
    server.closeAllConnections?.()
    await new Promise((resolve) => server.close(resolve))
    assert.notEqual(await relayCallback({ port, target: `/callback?${query}` }, { platform: "win32", spawn }), 0)
  } finally {
    if (server.listening) server.close()
  }
})
