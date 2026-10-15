// The conversation as the yeoman keeps it: history from hippo once, then
// what the server pushes over SSE. The server answers one message at a
// time and says so with `typing`.
import { useCallback, useEffect, useState } from "react";
import type { AttachmentAdapter } from "@assistant-ui/react";

export type Msg = {
  id: string;
  role: "user" | "assistant" | "system";
  text: string;
  /** Shown word for word: a draft waiting for approval. */
  plain?: boolean;
  /** A PNG, base64. */
  png?: string;
  reaction?: string;
  date?: Date;
  /** A file sent with the message; `image` is a local URL to show it by. */
  file?: { name: string; image?: string };
  /** The tools the model used on the way to this answer, in order. */
  tools?: Tool[];
  /** Still working: tool calls go here until the answer arrives. */
  live?: boolean;
};

export type Tool = { id: string; name: string; input: unknown; result?: string; error?: boolean };

type Step =
  | { type: "call"; id: string; name: string; input: unknown }
  | { type: "result"; id: string; text: string; error: boolean };

type Said = { i: number; kind: string; text: string; date: string };

type Shown =
  | { type: "said"; id: string; text: string; plain: boolean }
  | { type: "react"; to: string; emoji: string }
  | { type: "picture"; png: string }
  | { type: "typing"; on: boolean }
  | { type: "step"; step: Step };

const ROLE: Record<string, Msg["role"]> = { user: "user", talk: "assistant", note: "system" };

export type Chat =
  | { state: "loading" }
  | { state: "signed-out" }
  | { state: "error"; error: string }
  | { state: "ready"; messages: Msg[]; typing: boolean; send: (text: string, file?: File) => Promise<void> };

export function useChat(): Chat {
  const [status, setStatus] = useState<"loading" | "signed-out" | "ready" | string>("loading");
  const [messages, setMessages] = useState<Msg[]>([]);
  const [typing, setTyping] = useState(false);

  useEffect(() => {
    let events: EventSource | undefined;
    let gone = false;
    const load = async () => {
      const r = await fetch("/api/history");
      if (r.status === 401) return setStatus("signed-out");
      if (!r.ok) return setStatus(`History failed: ${r.status}`);
      const said: Said[] = await r.json();
      if (gone) return;
      setMessages(
        said.map((m) => ({
          id: `h-${m.i}`,
          role: ROLE[m.kind],
          text: m.text,
          date: new Date(m.date),
        })),
      );
      setStatus("ready");
      events = new EventSource("/api/events");
      events.onmessage = (e) => {
        const s: Shown = JSON.parse(e.data);
        switch (s.type) {
          case "said":
            setMessages((ms) => {
              // The answer joins the tools that led to it; a draft stands alone.
              const last = ms.at(-1);
              if (!s.plain && last?.live) return [...ms.slice(0, -1), { ...last, id: s.id, text: s.text, live: false }];
              return [...ms, { id: s.id, role: "assistant", text: s.text, plain: s.plain, date: new Date() }];
            });
            break;
          case "step":
            setMessages((ms) => step(ms, s.step));
            break;
          case "react":
            setMessages((ms) => ms.map((m) => (m.id === s.to ? { ...m, reaction: s.emoji } : m)));
            break;
          case "picture":
            setMessages((ms) => [...ms, { id: crypto.randomUUID(), role: "assistant", text: "", png: s.png, date: new Date() }]);
            break;
          case "typing":
            setTyping(s.on);
            // A turn that ended without an answer leaves its tools standing.
            if (!s.on) setMessages((ms) => ms.map((m) => (m.live ? { ...m, live: false } : m)));
            break;
        }
      };
    };
    load().catch((e) => setStatus(String(e)));
    return () => {
      gone = true;
      events?.close();
    };
  }, []);

  const send = useCallback(async (text: string, file?: File) => {
    const local = crypto.randomUUID();
    const shown = file && { name: file.name, image: file.type.startsWith("image/") ? URL.createObjectURL(file) : undefined };
    setMessages((ms) => [...ms, { id: local, role: "user", text, file: shown, date: new Date() }]);
    const body = new FormData();
    body.set("text", text);
    if (file) body.set("file", file);
    const r = await fetch("/api/send", { method: "POST", body });
    if (r.status === 401) return setStatus("signed-out");
    if (!r.ok) {
      setMessages((ms) => ms.map((m) => (m.id === local ? { ...m, reaction: "⚠️" } : m)));
      return;
    }
    // The server's id, so a reaction finds the message.
    const { id } = (await r.json()) as { id: string };
    setMessages((ms) => ms.map((m) => (m.id === local ? { ...m, id } : m)));
  }, []);

  if (status === "loading" || status === "signed-out") return { state: status };
  if (status !== "ready") return { state: "error", error: status };
  return { state: "ready", messages, typing, send };
}

function step(ms: Msg[], s: Step): Msg[] {
  if (s.type === "result") {
    const done = (t: Tool) => (t.id === s.id ? { ...t, result: s.text, error: s.error } : t);
    return ms.map((m) => (m.tools?.some((t) => t.id === s.id) ? { ...m, tools: m.tools.map(done) } : m));
  }
  const tool = { id: s.id, name: s.name, input: s.input };
  const last = ms.at(-1);
  if (last?.live) return [...ms.slice(0, -1), { ...last, tools: [...(last.tools ?? []), tool] }];
  return [...ms, { id: `w-${s.id}`, role: "assistant", text: "", tools: [tool], live: true, date: new Date() }];
}

// The model reads photos up to 3.75 MB (IMAGE_MAX in main.rs) in JPEG, PNG,
// GIF or WebP. A phone photo is often bigger, or HEIC, so the page redraws
// it as a JPEG no longer than 2048 px on its long side, which the model
// downscales to anyway.
const PHOTO_MAX = 3_500_000;
const PHOTO_TYPES = ["image/jpeg", "image/png", "image/gif", "image/webp"];

async function fit(file: File): Promise<File> {
  if (!file.type.startsWith("image/") || (file.size <= PHOTO_MAX && PHOTO_TYPES.includes(file.type))) return file;
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, 2048 / Math.max(bitmap.width, bitmap.height));
  const canvas = new OffscreenCanvas(Math.round(bitmap.width * scale), Math.round(bitmap.height * scale));
  canvas.getContext("2d")!.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  const blob = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.85 });
  return new File([blob], file.name.replace(/\.[^.]*$/, "") + ".jpg", { type: "image/jpeg" });
}

/** Holds a chosen file in the composer until it goes out with the message. */
export const attachments: AttachmentAdapter = {
  accept: "image/*,application/pdf,text/*",
  async add({ file }) {
    const fitted = await fit(file);
    return {
      id: crypto.randomUUID(),
      type: fitted.type.startsWith("image/") ? "image" : "document",
      name: fitted.name,
      contentType: fitted.type,
      file: fitted,
      status: { type: "requires-action", reason: "composer-send" },
    };
  },
  async remove() {},
  async send(a) {
    return { ...a, status: { type: "complete" }, content: [] };
  },
};

/** Asks to be let in; the yeoman posts the code to Matrix for a 👍. */
export async function askToSignIn(): Promise<{ code: string; secret: string } | { error: string }> {
  const r = await fetch("/api/ask", { method: "POST" });
  if (r.ok) return r.json();
  if (r.status === 429) return { error: "A request went out less than a minute ago. Check Matrix, or try again shortly." };
  return { error: `That failed (${r.status}).` };
}

/** Waits for the answer: true once signed in, false when refused or too old. */
export async function waitToSignIn(secret: string): Promise<boolean> {
  for (;;) {
    const r = await fetch("/api/wait", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ secret }),
    });
    if (r.status !== 202) return r.ok;
    await new Promise((done) => setTimeout(done, 2000));
  }
}
