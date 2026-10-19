import { useEffect, useRef, useState } from "react";

// A voice call: the page talks with Grok Voice directly, on a short-lived
// pass the site mints, so no audio passes through the host. Grok speaks as
// the assistant with the newest of its memory and no tools; when the call
// ends, what was said goes back to the site and into hippo.

const URL = "wss://api.x.ai/v1/realtime?model=grok-voice-latest";
const RATE = 24000;

// How fast the assistant speaks, on calls and read aloud; kept on this
// device. xAI takes 0.7 to 1.5 on a call.
const SPEEDS = [0.85, 1, 1.15, 1.3];

export function voiceSpeed(): number {
  const s = Number(localStorage.getItem("voiceSpeed"));
  return SPEEDS.includes(s) ? s : 1;
}

/** The voice speed and a step to the next, wrapping round. */
export function useVoiceSpeed(): [number, () => void] {
  const [speed, setSpeed] = useState(voiceSpeed);
  const next = () => {
    const s = SPEEDS[(SPEEDS.indexOf(speed) + 1) % SPEEDS.length];
    if (s === 1) localStorage.removeItem("voiceSpeed");
    else localStorage.setItem("voiceSpeed", String(s));
    setSpeed(s);
  };
  return [speed, next];
}

type State = "connecting" | "listening" | "speaking" | "ended" | { error: string };
type Line = { kind: "user" | "talk"; text: string };

// Hands the microphone's samples to the page in 20 ms frames.
const CAPTURE = `
class Capture extends AudioWorkletProcessor {
  constructor() { super(); this.buf = new Float32Array(${RATE / 50}); this.n = 0; }
  process([input]) {
    const ch = input[0];
    if (ch) for (let i = 0; i < ch.length; i++) {
      this.buf[this.n++] = ch[i];
      if (this.n === this.buf.length) { this.port.postMessage(this.buf.slice()); this.n = 0; }
    }
    return true;
  }
}
registerProcessor("capture", Capture);
`;

function pcm16(f: Float32Array): ArrayBuffer {
  const out = new Int16Array(f.length);
  for (let i = 0; i < f.length; i++) out[i] = Math.max(-1, Math.min(1, f[i])) * 0x7fff;
  return out.buffer;
}

function level(f: Float32Array): number {
  let sum = 0;
  for (const x of f) sum += x * x;
  return Math.min(1, Math.sqrt(sum / f.length) * 6);
}

/** The whole-screen call with `name`; `ended` runs once it is over and saved. */
export function Call({ name, ended }: { name: string; ended: () => void }) {
  const [state, setState] = useState<State>("connecting");
  const [muted, setMuted] = useState(false);
  const [caption, setCaption] = useState("");
  const [loud, setLoud] = useState(0);
  const hangUp = useRef<() => void>(() => {});
  const mute = useRef(false);

  useEffect(() => {
    let ws: WebSocket | undefined;
    let ctx: AudioContext | undefined;
    let mic: MediaStream | undefined;
    // Grok's voice plays through an audio element, not straight to the
    // speakers: with the microphone open Android is in a call, and its
    // volume keys move the call's volume, which only a media stream's
    // playback follows.
    let out: MediaStreamAudioDestinationNode | undefined;
    const speaker = new Audio();
    let over = false;
    const began = Date.now();
    // What was said, in the order it was said: a line is placed when its
    // turn starts, and its words fill in once heard.
    const lines = new Map<string, Line>();
    const early: ArrayBuffer[] = [];
    // Grok's audio, queued back to back; cut off when the person speaks.
    let next = 0;
    const playing = new Set<AudioBufferSourceNode>();
    const silence = () => {
      for (const s of playing) s.stop();
      playing.clear();
      next = 0;
    };
    const play = (data: ArrayBuffer) => {
      if (!ctx || !out) return;
      const pcm = new Int16Array(data);
      const buf = ctx.createBuffer(1, pcm.length, RATE);
      const ch = buf.getChannelData(0);
      for (let i = 0; i < pcm.length; i++) ch[i] = pcm[i] / 0x8000;
      const src = ctx.createBufferSource();
      src.buffer = buf;
      src.connect(out);
      next = Math.max(next, ctx.currentTime + 0.05);
      src.start(next);
      next += buf.duration;
      playing.add(src);
      src.onended = () => {
        playing.delete(src);
        if (!playing.size && !over) setState("listening");
      };
      setState("speaking");
    };

    // Hanging up saves the call and hands back to the chat; leaving the
    // page, or the sheet going away, only saves it.
    const finish = (why?: string, quiet = false) => {
      if (over) return;
      over = true;
      silence();
      ws?.close();
      mic?.getTracks().forEach((t) => t.stop());
      ctx?.close();
      speaker.pause();
      speaker.srcObject = null;
      const said = [...lines.values()].filter((l) => l.text.trim());
      setState(why ? { error: why } : "ended");
      const done = () => (why || quiet ? undefined : ended());
      if (!said.length) return done();
      fetch("/api/call/end", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ lines: said, minutes: Math.max(1, Math.round((Date.now() - began) / 60000)) }),
        // A page closed mid-call still saves it.
        keepalive: true,
      }).finally(done);
    };
    hangUp.current = () => finish();
    const closing = () => finish(undefined, true);
    window.addEventListener("pagehide", closing);

    (async () => {
      // The microphone and the pass together, as xAI advises; the
      // microphone's first words wait for the line to open.
      ctx = new AudioContext({ sampleRate: RATE });
      out = ctx.createMediaStreamDestination();
      speaker.srcObject = out.stream;
      // Within the tap that opened the call, so autoplay allows it.
      speaker.play().catch((e) => console.warn("call speaker:", e));
      const [stream, pass] = await Promise.all([
        navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } }),
        fetch("/api/call", { method: "POST" }).then(async (r) => {
          if (!r.ok) throw new Error(r.status === 404 ? `${name} has no voice.` : `The call failed to start (${r.status}).`);
          return r.json() as Promise<{ secret: string; voice: string; instructions: string }>;
        }),
      ]);
      mic = stream;
      if (over) return stream.getTracks().forEach((t) => t.stop());
      await ctx.audioWorklet.addModule(window.URL.createObjectURL(new Blob([CAPTURE], { type: "text/javascript" })));
      const capture = new AudioWorkletNode(ctx, "capture");
      ctx.createMediaStreamSource(stream).connect(capture);
      capture.port.onmessage = (e: MessageEvent<Float32Array>) => {
        if (mute.current) return setLoud(0);
        setLoud(level(e.data));
        const frame = pcm16(e.data);
        if (ws?.readyState === WebSocket.OPEN) ws.send(frame);
        else if (early.length < 100) early.push(frame);
      };

      ws = new WebSocket(URL, [`xai-client-secret.${pass.secret}`]);
      ws.binaryType = "arraybuffer";
      ws.onopen = () => {
        const audio = { format: { type: "audio/pcm", rate: RATE }, transport: "binary" };
        ws!.send(
          JSON.stringify({
            type: "session.update",
            session: {
              voice: pass.voice,
              instructions: pass.instructions,
              turn_detection: { type: "server_vad" },
              audio: { input: { ...audio, transcription: { model: "grok-transcribe" } }, output: { ...audio, speed: voiceSpeed() } },
            },
          }),
        );
        // It picks up as on the phone.
        ws!.send(JSON.stringify({ type: "response.create" }));
        for (const f of early.splice(0)) ws!.send(f);
        setState("listening");
      };
      ws.onmessage = (e) => {
        if (e.data instanceof ArrayBuffer) return play(e.data);
        const ev = JSON.parse(e.data);
        const line = (id: string, kind: Line["kind"]) => {
          if (!lines.has(id)) lines.set(id, { kind, text: "" });
          return lines.get(id)!;
        };
        switch (ev.type) {
          case "input_audio_buffer.speech_started":
            silence();
            setState("listening");
            break;
          case "input_audio_buffer.committed":
            line(ev.item_id, "user");
            break;
          case "conversation.item.input_audio_transcription.completed":
            line(ev.item_id, "user").text = ev.transcript ?? "";
            break;
          case "response.output_audio_transcript.delta": {
            const l = line(ev.item_id, "talk");
            l.text += ev.delta ?? "";
            setCaption(l.text);
            break;
          }
          case "response.output_audio_transcript.done":
            if (ev.transcript) line(ev.item_id, "talk").text = ev.transcript;
            break;
          case "error":
            console.warn("call:", ev.error ?? ev);
            break;
        }
      };
      ws.onclose = (e) => {
        if (!over) finish(e.code === 1000 ? undefined : `The call dropped (${e.code}${e.reason ? `: ${e.reason}` : ""}).`);
      };
    })().catch((e) => {
      const mics: Record<string, string> = {
        NotAllowedError: "The microphone is blocked for this site.",
        NotFoundError: "No microphone found.",
        NotReadableError: "Another app is using the microphone.",
      };
      finish((e instanceof DOMException && mics[e.name]) || (e instanceof Error ? e.message : String(e)));
    });

    return () => {
      window.removeEventListener("pagehide", closing);
      finish(undefined, true);
    };
    // One call per sheet.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const toggleMute = () => {
    mute.current = !mute.current;
    setMuted(mute.current);
  };
  const failed = typeof state === "object";
  const status = failed ? state.error : { connecting: "Connecting…", listening: muted ? "Muted" : "Listening", speaking: "Speaking", ended: "Saving the call…" }[state];

  return (
    <div className="fixed inset-0 z-50 flex flex-col items-center bg-paper px-6 pt-[max(18vh,env(safe-area-inset-top))] pb-[max(40px,env(safe-area-inset-bottom))] text-ink">
      <h2 className="font-serif text-[28px]">{name}</h2>
      <p className={`mt-1.5 text-sm ${failed ? "text-accent" : "text-mid"}`}>{status}</p>
      <div className="mt-[9vh] flex h-24 items-center gap-2" aria-hidden>
        {[0.55, 0.85, 1, 0.85, 0.55].map((w, i) => (
          <span
            key={i}
            className={`w-2.5 rounded-full bg-ink transition-[height] duration-100 ${state === "speaking" ? "animate-[talk_0.9s_ease-in-out_infinite]" : ""}`}
            style={{ height: state === "speaking" ? undefined : `${12 + w * loud * 84}px`, animationDelay: `${i * 0.12}s` }}
          />
        ))}
      </div>
      <p className="mt-[6vh] line-clamp-4 max-w-[34ch] text-center text-[17px] leading-relaxed text-mid">{caption}</p>
      <div className="mt-auto flex items-center gap-10">
        {failed ? (
          <button type="button" onClick={ended} className="rounded-full border border-frame px-6 py-3 text-ink hover:bg-hover">
            Close
          </button>
        ) : (
          <>
            <button
              type="button"
              onClick={toggleMute}
              aria-label={muted ? "Unmute" : "Mute"}
              title={muted ? "Unmute" : "Mute"}
              className={`grid size-16 place-items-center rounded-full border border-frame ${muted ? "bg-ink text-paper" : "text-ink hover:bg-hover"}`}
            >
              <svg viewBox="0 0 24 24" className="size-6" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
                <rect x="9" y="3" width="6" height="11" rx="3" />
                <path d="M5 11a7 7 0 0 0 14 0M12 18v3" />
                {muted && <path d="M4 4l16 16" />}
              </svg>
            </button>
            <button
              type="button"
              onClick={() => hangUp.current()}
              disabled={state === "ended"}
              aria-label="Hang up"
              title="Hang up"
              className="grid size-16 place-items-center rounded-full bg-[#c4453a] text-white hover:opacity-90 disabled:opacity-50"
            >
              <svg viewBox="0 0 24 24" className="size-7" fill="currentColor">
                <path d="M12 9c-2.4 0-4.6.5-6.6 1.4-.6.3-.9.9-.9 1.5v2.4c0 .7.6 1.2 1.3 1.1l2.6-.5c.6-.1 1-.6 1-1.2v-1.6c1.7-.5 3.5-.5 5.2 0v1.6c0 .6.4 1.1 1 1.2l2.6.5c.7.1 1.3-.4 1.3-1.1v-2.4c0-.6-.3-1.2-.9-1.5C16.6 9.5 14.4 9 12 9z" />
              </svg>
            </button>
          </>
        )}
      </div>
    </div>
  );
}

/** The voice button's mark: bars like a voice's level. */
export const Bars = () => (
  <svg viewBox="0 0 24 24" className="size-5" fill="none" stroke="currentColor" strokeWidth={2.2} strokeLinecap="round">
    <path d="M4.5 10v4M9.5 5v14M14.5 7.5v9M19.5 10v4" />
  </svg>
);
