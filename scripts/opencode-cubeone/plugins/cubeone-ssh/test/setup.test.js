import assert from "node:assert/strict"
import { test } from "node:test"
import { createMaintainer, ensureHost, installArgs, parseProbe, probeArgs, tail } from "../setup.js"

test("probeArgs builds a non-interactive, host-key-tolerant ssh call", () => {
  const args = probeArgs("/home/m/.ssh/config", "coding-vm-2")
  assert.deepEqual(args, [
    "-F",
    "/home/m/.ssh/config",
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=8",
    "-o",
    "StrictHostKeyChecking=accept-new",
    "coding-vm-2",
    "command -v opencode >/dev/null 2>&1 && echo __READY__ || echo __MISSING__",
  ])
})

test("installArgs scopes the shared remote installer to one host and skips WSL", () => {
  assert.deepEqual(installArgs("C:/ProgramData/opencode/Install-OpenCodeRemote.ps1", "coding-vm-2"), [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "C:/ProgramData/opencode/Install-OpenCodeRemote.ps1",
    "-OnlyHost",
    "coding-vm-2",
    "-SkipWsl",
  ])
})

test("parseProbe reads the markers and is strict about unexpected output", () => {
  assert.equal(parseProbe("__READY__\n"), "ready")
  assert.equal(parseProbe("__MISSING__\n"), "missing")
  assert.equal(parseProbe("Permission denied\n"), "unknown")
  assert.equal(parseProbe(""), "unknown")
})

test("tail keeps short text whole and only truncates long text from the front", () => {
  assert.equal(tail("  short  "), "short")
  const long = "x".repeat(600) + "END"
  const result = tail(long, 10)
  assert.equal(result, "…" + "x".repeat(7) + "END")
})

test("ensureHost reports ready without touching the installer", async () => {
  const calls = []
  const exec = async (cmd, args) => {
    calls.push([cmd, args])
    return { stdout: "__READY__\n" }
  }
  const result = await ensureHost({ alias: "coding-vm-2", configPath: "cfg", scriptPath: "script.ps1", exec })
  assert.deepEqual(result, { alias: "coding-vm-2", status: "ready" })
  assert.equal(calls.length, 1)
  assert.equal(calls[0][0], "ssh")
})

test("ensureHost installs when ssh succeeds but opencode is missing", async () => {
  const calls = []
  const exec = async (cmd, args) => {
    calls.push(cmd)
    if (cmd === "ssh") return { stdout: "__MISSING__\n" }
    return { stdout: "coding-vm-2: installed /etc/opencode\n" }
  }
  const result = await ensureHost({ alias: "coding-vm-2", configPath: "cfg", scriptPath: "script.ps1", exec })
  assert.equal(result.status, "installed")
  assert.match(result.detail, /installed/)
  assert.deepEqual(calls, ["ssh", "powershell.exe"])
})

test("ensureHost never throws: an unreachable host comes back as a status", async () => {
  const exec = async () => {
    throw new Error("ssh: connect to host coding-vm-1 port 22: Connection timed out")
  }
  const result = await ensureHost({ alias: "coding-vm-1", configPath: "cfg", scriptPath: "script.ps1", exec })
  assert.equal(result.status, "unreachable")
  assert.match(result.detail, /Connection timed out/)
})

test("ensureHost surfaces a failed install, e.g. a CPU too old for Bun, without secrets", async () => {
  const exec = async (cmd) => {
    if (cmd === "ssh") return { stdout: "__MISSING__\n" }
    throw new Error("Command failed: this CPU is missing SSE4.2 support, which Bun requires.")
  }
  const result = await ensureHost({ alias: "coding-vm-5", configPath: "cfg", scriptPath: "script.ps1", exec })
  assert.equal(result.status, "failed")
  assert.match(result.detail, /SSE4\.2/)
})

test("createMaintainer only checks a host again after intervalMs and never runs two rounds at once", async () => {
  let inFlight = 0
  let maxInFlight = 0
  const exec = async () => {
    inFlight++
    maxInFlight = Math.max(maxInFlight, inFlight)
    await new Promise((resolve) => setTimeout(resolve, 5))
    inFlight--
    return { stdout: "__READY__\n" }
  }
  const maintain = createMaintainer({ configPath: "cfg", scriptPath: "script.ps1", exec, intervalMs: 50 })
  const hosts = [{ alias: "a" }, { alias: "b" }]

  const first = await maintain(hosts)
  assert.equal(first.length, 2)
  assert.equal(maxInFlight, 1, "hosts are probed one at a time")

  const second = await maintain(hosts)
  assert.equal(second.length, 0, "neither host is due again yet")

  await new Promise((resolve) => setTimeout(resolve, 60))
  const third = await maintain(hosts)
  assert.equal(third.length, 2, "both hosts are due again after intervalMs")
})

test("createMaintainer drops a concurrent call instead of queuing it", async () => {
  let release
  const gate = new Promise((resolve) => (release = resolve))
  const exec = async () => {
    await gate
    return { stdout: "__READY__\n" }
  }
  const maintain = createMaintainer({ configPath: "cfg", scriptPath: "script.ps1", exec, intervalMs: 50 })
  const hosts = [{ alias: "a" }]

  const slow = maintain(hosts)
  const overlapping = await maintain(hosts)
  assert.deepEqual(overlapping, [])
  release()
  const result = await slow
  assert.equal(result.length, 1)
})
