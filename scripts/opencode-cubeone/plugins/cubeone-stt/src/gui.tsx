import { createSignal } from "solid-js"
import { ComposerPill, Plugin, type ComposerPillView } from "@opencode/plugin/gui"
import { Transcriber } from "./contract"
import { main } from "./main"

const MAX_RECORDING_MS = 5 * 60 * 1000
const MIN_RECORDING_MS = 400
const SILENCE_MS = 3000
const SPEECH_LEVEL = 0.02

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

function speechLevel(analyser: AnalyserNode, samples: Uint8Array<ArrayBuffer>) {
  analyser.getByteTimeDomainData(samples)
  let sum = 0
  for (let index = 0; index < samples.length; index++) {
    const sample = ((samples[index] ?? 128) - 128) / 128
    sum += sample * sample
  }
  return Math.sqrt(sum / samples.length)
}

export default Plugin.define({
  os: ["windows", "macos", "linux"],
  i18n: {
    en: {
      dictate: "Dictate",
      listening: "Listening…",
      transcribing: "Transcribing…",
      "error.microphone": "Microphone not available",
      "error.microphone.hint": "Allow microphone access for desktop apps in the Windows privacy settings.",
      "error.transcription": "Transcription failed",
      "error.empty": "No speech recognized",
      "error.send": "Transcript is in the chat box. Press Enter to send it.",
      limit: "Recording stopped after five minutes",
      copied: "Transcript copied to the clipboard",
    },
    de: {
      dictate: "Diktieren",
      listening: "Hört zu …",
      transcribing: "Wird transkribiert …",
      "error.microphone": "Mikrofon nicht verfügbar",
      "error.microphone.hint": "Unter Windows-Einstellungen > Datenschutz > Mikrofon den Zugriff für Desktop-Apps erlauben.",
      "error.transcription": "Transkription fehlgeschlagen",
      "error.empty": "Keine Sprache erkannt",
      "error.send": "Das Transkript steht im Eingabefeld. Mit Enter geht es in den Chat.",
      limit: "Aufnahme nach fünf Minuten beendet",
      copied: "Transkript in die Zwischenablage kopiert",
    },
  },
  setup(ctx) {
    const transcriber = ctx.main(Transcriber)
    const [phase, setPhase] = createSignal<Phase>("idle")
    let recorder: MediaRecorder | undefined
    let stream: MediaStream | undefined
    let limitTimer: ReturnType<typeof setTimeout> | undefined
    let silenceTimer: ReturnType<typeof setInterval> | undefined
    let audio: AudioContext | undefined
    let startedAt = 0
    let quietSince = 0
    let heardSpeech = false

    const release = () => {
      if (limitTimer) clearTimeout(limitTimer)
      if (silenceTimer) clearInterval(silenceTimer)
      limitTimer = undefined
      silenceTimer = undefined
      void audio?.close()
      audio = undefined
      stream?.getTracks().forEach((track) => track.stop())
      stream = undefined
      recorder = undefined
    }

    const deliver = async (blob: Blob, mimeType: string) => {
      setPhase("transcribing")
      try {
        const encoded = toBase64(await blob.arrayBuffer())
        const { text } = await transcriber.transcribe({ audio: encoded, format: formatOf(mimeType) }, { signal: ctx.signal })
        if (!text) {
          ctx.toast.show({ variant: "default", title: ctx.t("error.empty") })
          return
        }
        const composer = ctx.screen.current()?.composer
        if (!composer) {
          await ctx.system.copy(text)
          ctx.toast.show({ variant: "success", title: ctx.t("copied") })
          return
        }
        const before = composer.text()
        composer.setText(before && !/\s$/.test(before) ? `${before} ${text}` : `${before}${text}`)
        composer.focus()
        // The draft write is applied before the next turn. The app's own submit command then sends it.
        window.setTimeout(() => {
          if (!ctx.commands.run("prompt.submit")) {
            ctx.toast.show({ variant: "default", title: ctx.t("error.send") })
          }
        }, 50)
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

    const watchSilence = (media: MediaStream) => {
      const context = new AudioContext()
      audio = context
      const source = context.createMediaStreamSource(media)
      const analyser = context.createAnalyser()
      analyser.fftSize = 2048
      source.connect(analyser)
      const samples = new Uint8Array(analyser.fftSize)
      quietSince = Date.now()
      silenceTimer = setInterval(() => {
        if (recorder?.state !== "recording") return
        if (speechLevel(analyser, samples) >= SPEECH_LEVEL) {
          heardSpeech = true
          quietSince = Date.now()
          return
        }
        if (Date.now() - quietSince >= SILENCE_MS) stop()
      }, 100)
    }

    const start = async () => {
      heardSpeech = false
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
        const spoke = heardSpeech
        const type = active.mimeType || mimeType || "audio/webm"
        release()
        if (!spoke || duration < MIN_RECORDING_MS || chunks.length === 0) {
          setPhase("idle")
          return
        }
        void deliver(new Blob(chunks, { type }), type)
      }
      recorder = active
      startedAt = Date.now()
      active.start()
      watchSilence(stream)
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

    ctx.add(ComposerPill, {
      id: "dictate",
      show: (): ComposerPillView => ({
        label: phase() === "recording" ? ctx.t("listening") : phase() === "transcribing" ? ctx.t("transcribing") : ctx.t("dictate"),
        icon: phase() === "recording" ? "stop" : "outline-audio",
        tone: phase() === "recording" ? "danger" : undefined,
        title: ctx.t("dictate"),
        run: toggle,
      }),
    })

    return () => {
      stop()
      release()
    }
  },
  main,
})
