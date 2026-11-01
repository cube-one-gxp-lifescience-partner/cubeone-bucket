import { Schema } from "effect"
import { Ipc } from "@opencode/plugin/gui"

export const Transcriber = Ipc.define({
  id: "cubeone-stt.transcriber",
  methods: {
    transcribe: {
      input: Schema.Struct({ audio: Schema.String, format: Schema.String }),
      output: Schema.Struct({ text: Schema.String }),
    },
    status: {
      output: Schema.Struct({ configured: Schema.Boolean, model: Schema.String, endpoint: Schema.String }),
    },
  },
})
