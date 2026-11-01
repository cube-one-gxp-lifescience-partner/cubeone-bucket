import { createSignal } from "solid-js"
import { Command, ComposerPill, Plugin, TitlebarItem, type ComposerPillView } from "@opencode/plugin/gui"
import { Transcriber } from "./contract"
import { main } from "./main"

const MAX_RECORDING_MS = 5 * 60 * 1000
const MIN_RECORDING_MS = 400

type Phase = "idle" | "recording" | "transcribing"

function toBase64(buffer: ArrayBuffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ""
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000))
  }
  return btoa(binary)
}

function formatOf(mimeType: string) {
  if (mimeType.includes("ogg")) return "ogg"
  if (mimeType.includes("mp4")) return "m4a"
  return "webm"
}

export default Plugin.define({
  os: ["windows", "macos", "linux"],
  i18n: {
    en: {
      dictate: "Dictate",
      stop: "Stop recording",
      transcribing: "Transcribing…",
      "command.toggle": "Start or stop dictation",
      "command.group": "Dictation",
      "error.microphone": "Microphone not available",
      "error.microphone.hint": "Allow microphone access for desktop apps in the Windows privacy settings.",
      "error.transcription": "Transcription failed",
      "error.empty": "No speech recognized",
      "limit": "Recording stopped after five minutes",
      "copied": "Transcript copied to the clipboard",
    },
    de: {
      dictate: "Diktieren",
      stop: "Aufnahme beenden",
      transcribing: "Wird transkribiert …",
      "command.toggle": "Diktat starten oder beenden",
      "command.group": "Diktat",
      "error.microphone": "Mikrofon nicht verfügbar",
      "error.microphone.hint": "Unter Windows-Einstellungen > Datenschutz > Mikrofon den Zugriff für Desktop-Apps erlauben.",
      "error.transcription": "Transkription fehlgeschlagen",
      "error.empty": "Keine Sprache erkannt",
      "limit": "Aufnahme nach fünf Minuten beendet",
      "copied": "Transkript in die Zwischenablage kopiert",
    },
  },
  setup(ctx) {
    const transcriber = ctx.main(Transcriber)
    const [phase, setPhase] = createSignal<Phase>("idle")
    let recorder: MediaRecorder | undefined
    let stream: MediaStream | undefined
    let limitTimer: ReturnType<typeof setTimeout> | undefined
    let startedAt = 0

    const release = () => {
      if (limitTimer) clearTimeout(limitTimer)
      limitTimer = undefined
      stream?.getTracks().forEach((track) => track.stop())
      stream = undefined
      recorder = undefined
    }

    const deliver = async (blob: Blob, mimeType: string) => {
      setPhase("transcribing")
      try {
        const audio = toBase64(await blob.arrayBuffer())
        const { text } = await transcriber.transcribe({ audio, format: formatOf(mimeType) }, { signal: ctx.signal })
        if (!text) {
          ctx.toast.show({ variant: "default", title: ctx.t("error.empty") })
          return
        }
        const composer = ctx.screen.current()?.composer
        if (composer) {
          const before = composer.text()
          composer.insert(before && !/\s$/.test(before) ? ` ${text}` : text)
          composer.focus()
        } else {
          await ctx.system.copy(text)
          ctx.toast.show({ variant: "success", title: ctx.t("copied") })
        }
      } catch (error) {
        ctx.toast.show({
          variant: "error",
          title: ctx.t("error.transcription"),
          description: error instanceof Error ? error.message : String(error),
        })
      } finally {
        setPhase("idle")
      }
    }

    const start = async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true },
        })
      } catch (error) {
        release()
        ctx.toast.show({
          variant: "error",
          title: ctx.t("error.microphone"),
          description: `${error instanceof Error ? error.message : String(error)} ${ctx.t("error.microphone.hint")}`,
        })
        return
      }
      const preferred = ["audio/webm;codecs=opus", "audio/ogg;codecs=opus", "audio/webm"]
      const mimeType = preferred.find((type) => MediaRecorder.isTypeSupported(type)) ?? ""
      const chunks: Blob[] = []
      const active = new MediaRecorder(stream, mimeType ? { mimeType } : undefined)
      active.ondataavailable = (event) => {
        if (event.data.size > 0) chunks.push(event.data)
      }
      active.onstop = () => {
        const duration = Date.now() - startedAt
        const type = active.mimeType || mimeType || "audio/webm"
        release()
        if (duration < MIN_RECORDING_MS || chunks.length === 0) {
          setPhase("idle")
          return
        }
        void deliver(new Blob(chunks, { type }), type)
      }
      recorder = active
      startedAt = Date.now()
      active.start()
      setPhase("recording")
      limitTimer = setTimeout(() => {
        ctx.toast.show({ variant: "default", title: ctx.t("limit") })
        stop()
      }, MAX_RECORDING_MS)
    }

    const stop = () => {
      if (recorder?.state === "recording") recorder.stop()
    }

    const toggle = () => {
      if (phase() === "recording") return stop()
      if (phase() === "idle") void start()
    }

    ctx.add(TitlebarItem, (): TitlebarItem => ({
      id: "dictate",
      label: phase() === "recording" ? ctx.t("stop") : phase() === "transcribing" ? ctx.t("transcribing") : ctx.t("dictate"),
      icon: phase() === "recording" ? "stop" : "outline-audio",
      pressed: phase() === "recording",
      busy: phase() === "transcribing",
      run: toggle,
    }))

    ctx.add(ComposerPill, {
      id: "dictate",
      show: (): ComposerPillView => ({
        label: phase() === "recording" ? ctx.t("stop") : phase() === "transcribing" ? ctx.t("transcribing") : ctx.t("dictate"),
        icon: phase() === "recording" ? "stop" : phase() === "transcribing" ? "waveform" : "outline-audio",
        tone: phase() === "recording" ? "danger" : undefined,
        run: toggle,
      }),
    })

    ctx.add(Command, (): Command => ({
      id: "toggle",
      title: ctx.t("command.toggle"),
      group: ctx.t("command.group"),
      keywords: "stt speech diktat sprache mikrofon voice transcribe",
      section: "prompt",
      bind: "mod+alt+m",
      editable: true,
      featured: true,
      slash: { name: "diktat" },
      enabled: phase() !== "transcribing",
      run: () => toggle(),
    }))

    return () => {
      stop()
      release()
    }
  },
  main,
})
