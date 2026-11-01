import { createSignal, Show } from "solid-js"
import { ComposerPill, Plugin, Slot, type ComposerPillView, type MountedSession } from "@opencode/plugin/gui"
import { Transcriber } from "./contract"
import { main } from "./main"

const MAX_RECORDING_MS = 5 * 60 * 1000
const MIN_RECORDING_MS = 400
const SILENCE_MS = 3000
const SPEECH_LEVEL = 0.02

const ORCHESTRATOR = "orchestrator"

type Phase = "idle" | "recording" | "transcribing"

type Requirements = { goal: string; requirements: string; acceptance: string; constraints: string }

const REQUIREMENTS_CSS = `
.cubeone-req { display: flex; flex-direction: column; gap: 14px; }
.cubeone-req label { display: flex; flex-direction: column; gap: 6px; }
.cubeone-req label > span { font-weight: 600; line-height: 1.25; }
.cubeone-req textarea {
  font: inherit; line-height: 1.5; color: inherit; background: transparent; resize: vertical;
  min-height: 40px; padding: 8px 10px; border-radius: 10px; border: 1px solid var(--border-base, rgba(127,127,127,0.35)); outline: none;
}
.cubeone-req textarea:focus { border-color: #F47A27; box-shadow: 0 0 0 2px rgba(244, 122, 39, 0.1); }
.cubeone-req textarea[aria-invalid="true"] { border-color: #C0392B; }
`

function Field(props: { label: string; placeholder: string; rows: number; value: string; invalid?: boolean; onInput: (value: string) => void }) {
  return (
    <label>
      <span>{props.label}</span>
      <textarea
        rows={props.rows}
        placeholder={props.placeholder}
        value={props.value}
        aria-invalid={props.invalid ? "true" : undefined}
        onInput={(event) => props.onInput(event.currentTarget.value)}
      />
    </label>
  )
}

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
      routed: "Model selected by Auto",
      "req.pill": "Requirements",
      "req.title": "Project requirements",
      "req.description": "The orchestrator turns them into a plan. You review and approve the plan before any file is written.",
      "req.goal": "Goal",
      "req.goal.placeholder": "What should exist at the end?",
      "req.requirements": "Requirements",
      "req.requirements.placeholder": "One requirement per line: features, users, data, interfaces",
      "req.acceptance": "Acceptance criteria",
      "req.acceptance.placeholder": "How do we know it is done? Tests, behaviour, performance",
      "req.constraints": "Constraints",
      "req.constraints.placeholder": "Stack, conventions, deadlines, explicit non-goals",
      "req.cancel": "Cancel",
      "req.submit": "Start orchestrator",
      "req.missing": "Enter at least the requirements",
      "req.copied": "No session is open. The requirements are in the clipboard.",
      "req.failed": "Orchestrator could not be started",
      "req.intro": "Plan this project as orchestrator. Present the plan for approval before any file is changed.",
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
      routed: "Von Auto gewähltes Modell",
      "req.pill": "Anforderungen",
      "req.title": "Projektanforderungen",
      "req.description": "Der Orchestrator macht daraus einen Plan. Du prüfst und genehmigst ihn, bevor eine Datei geschrieben wird.",
      "req.goal": "Ziel",
      "req.goal.placeholder": "Was soll am Ende stehen?",
      "req.requirements": "Anforderungen",
      "req.requirements.placeholder": "Eine Anforderung pro Zeile: Funktionen, Nutzer, Daten, Schnittstellen",
      "req.acceptance": "Akzeptanzkriterien",
      "req.acceptance.placeholder": "Woran erkennen wir, dass es fertig ist? Tests, Verhalten, Leistung",
      "req.constraints": "Rahmenbedingungen",
      "req.constraints.placeholder": "Stack, Konventionen, Termine, ausdrückliche Nicht-Ziele",
      "req.cancel": "Abbrechen",
      "req.submit": "Orchestrator starten",
      "req.missing": "Bitte mindestens die Anforderungen eintragen",
      "req.copied": "Es ist keine Sitzung offen. Die Anforderungen liegen in der Zwischenablage.",
      "req.failed": "Orchestrator konnte nicht starten",
      "req.intro": "Plane dieses Projekt als Orchestrator. Lege den Plan zur Genehmigung vor, bevor eine Datei geändert wird.",
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

    const routedLabel = (session: MountedSession) => {
      const info = session.server.data.session.get(session.id)
      if (!info || info.model?.id !== "openrouter/auto") return ""
      const routed = info.metadata?.routedModel
      if (typeof routed !== "string" || !routed.includes("/")) return ""
      const known = session.server.data.location.model.list(session.location)?.find((item) => item.modelID === routed)
      return known?.name || routed
    }

    function RoutedModel(props: { session: () => MountedSession }) {
      const label = () => routedLabel(props.session())
      return (
        <Show when={label()}>
          {(model) => (
            <span title={ctx.t("routed")} style={{ opacity: "0.72", "font-size": "12px", "line-height": "1.25", "white-space": "nowrap" }}>
              {model()}
            </span>
          )}
        </Show>
      )
    }

    const requirementsPrompt = (fields: Requirements) => {
      const section = (key: string, value: string) => (value.trim() ? `### ${ctx.t(key)}\n\n${value.trim()}` : "")
      return [
        ctx.t("req.intro"),
        section("req.goal", fields.goal),
        section("req.requirements", fields.requirements),
        section("req.acceptance", fields.acceptance),
        section("req.constraints", fields.constraints),
      ]
        .filter(Boolean)
        .join("\n\n")
    }

    const startOrchestrator = async (text: string) => {
      const session = ctx.sessions.current()
      const composer = ctx.screen.current()?.composer
      if (!session || !composer) {
        await ctx.system.copy(text)
        ctx.toast.show({ variant: "default", title: ctx.t("req.copied") })
        return
      }
      await session.server.client.session.switchAgent({ sessionID: session.id, agent: ORCHESTRATOR })
      composer.setText(text)
      window.setTimeout(() => {
        if (!ctx.commands.run("prompt.submit")) composer.focus()
      }, 50)
    }

    const openRequirements = () => {
      const [fields, setFields] = createSignal<Requirements>({ goal: "", requirements: "", acceptance: "", constraints: "" })
      const [busy, setBusy] = createSignal(false)
      const [invalid, setInvalid] = createSignal(false)
      const set = (key: keyof Requirements) => (value: string) => {
        setFields({ ...fields(), [key]: value })
        if (key === "requirements" && value.trim()) setInvalid(false)
      }

      ctx.dialogs.open((dialog) => {
        const submit = async () => {
          if (!fields().requirements.trim()) {
            setInvalid(true)
            ctx.toast.show({ variant: "default", title: ctx.t("req.missing") })
            return
          }
          setBusy(true)
          try {
            await startOrchestrator(requirementsPrompt(fields()))
            dialog.close()
          } catch (error) {
            ctx.toast.show({
              variant: "error",
              title: ctx.t("req.failed"),
              description: error instanceof Error ? error.message : String(error),
            })
          } finally {
            setBusy(false)
          }
        }

        return (
          <ctx.ui.Dialog
            title={ctx.t("req.title")}
            description={ctx.t("req.description")}
            size="x-large"
            footer={
              <>
                <ctx.ui.Button variant="neutral" onClick={dialog.close}>
                  {ctx.t("req.cancel")}
                </ctx.ui.Button>
                <ctx.ui.Button variant="contrast" icon="checklist" busy={busy()} onClick={() => void submit()}>
                  {ctx.t("req.submit")}
                </ctx.ui.Button>
              </>
            }
          >
            <style>{REQUIREMENTS_CSS}</style>
            <div class="cubeone-req">
              <label>
                <span>{ctx.t("req.goal")}</span>
                <ctx.ui.TextInput
                  size="large"
                  autofocus
                  label={ctx.t("req.goal")}
                  placeholder={ctx.t("req.goal.placeholder")}
                  value={fields().goal}
                  onInput={set("goal")}
                />
              </label>
              <Field label={ctx.t("req.requirements")} placeholder={ctx.t("req.requirements.placeholder")} rows={7} invalid={invalid()} value={fields().requirements} onInput={set("requirements")} />
              <Field label={ctx.t("req.acceptance")} placeholder={ctx.t("req.acceptance.placeholder")} rows={4} value={fields().acceptance} onInput={set("acceptance")} />
              <Field label={ctx.t("req.constraints")} placeholder={ctx.t("req.constraints.placeholder")} rows={3} value={fields().constraints} onInput={set("constraints")} />
            </div>
          </ctx.ui.Dialog>
        )
      })
    }

    ctx.add(ComposerPill, {
      id: "requirements",
      show: (): ComposerPillView => ({
        label: ctx.t("req.pill"),
        icon: "checklist",
        title: ctx.t("req.title"),
        run: openRequirements,
      }),
    })

    ctx.add(Slot, {
      at: "session.header",
      order: 10,
      render: (input) => <RoutedModel session={() => input.session} />,
    })

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
