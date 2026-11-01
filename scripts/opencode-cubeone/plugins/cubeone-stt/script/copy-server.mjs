import { copyFileSync } from "node:fs"

copyFileSync(new URL("../src/server.js", import.meta.url), new URL("../dist/server.js", import.meta.url))
