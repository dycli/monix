// The conversation as the yeoman keeps it: history from hippo once, then
// what the server pushes over SSE. The server answers one message at a
// time and says so with `typing`.
import { useCallback, useEffect, useState } from "react";

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
};

type Said = { i: number; kind: string; text: string; date: string };

type Shown =
  | { type: "said"; id: string; text: string; plain: boolean }
  | { type: "react"; to: string; emoji: string }
  | { type: "picture"; png: string }
  | { type: "typing"; on: boolean };

const ROLE: Record<string, Msg["role"]> = { user: "user", talk: "assistant", note: "system" };

export type Chat =
  | { state: "loading" }
  | { state: "signed-out" }
  | { state: "error"; error: string }
  | { state: "ready"; messages: Msg[]; typing: boolean; send: (text: string) => Promise<void> };

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
            setMessages((ms) => [...ms, { id: s.id, role: "assistant", text: s.text, plain: s.plain, date: new Date() }]);
            break;
          case "react":
            setMessages((ms) => ms.map((m) => (m.id === s.to ? { ...m, reaction: s.emoji } : m)));
            break;
          case "picture":
            setMessages((ms) => [...ms, { id: crypto.randomUUID(), role: "assistant", text: "", png: s.png, date: new Date() }]);
            break;
          case "typing":
            setTyping(s.on);
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

  const send = useCallback(async (text: string) => {
    const local = crypto.randomUUID();
    setMessages((ms) => [...ms, { id: local, role: "user", text, date: new Date() }]);
    const r = await fetch("/api/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
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
