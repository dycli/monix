// The conversation as the yeoman keeps it: history from hippo, then what
// the server pushes over SSE, with history again whenever the stream may
// have missed something. The server answers one message at a
// time and says so with `typing`.
import { useCallback, useEffect, useRef, useState } from "react";
import type { AttachmentAdapter } from "@assistant-ui/react";

export type Msg = {
  id: string;
  role: "user" | "assistant" | "system";
  text: string;
  /** Shown word for word: a draft waiting for approval. */
  plain?: boolean;
  /** A picture, as a data URL. */
  picture?: string;
  /** A kept file sent back, saved from /api/file/{name}. */
  file?: string;
  reaction?: string;
  date?: Date;
  /** Files sent with the message; `image` is a local URL to show one by. */
  files?: { name: string; image?: string }[];
  /** The tools the model used on the way to this answer, in order. */
  tools?: Tool[];
  /** Still working: tool calls go here until the answer arrives. */
  live?: boolean;
};

export type Tool = { id: string; name: string; input: unknown; result?: string; error?: boolean };

/** A subagent at work on its own: its name, its task, and its work so
 * far. `stopping` once a stop is asked for. */
export type Task = { name: string; text: string; tools: Tool[]; words: string; stopping?: boolean };

type Agent = { name: string; task: string };

type Step =
  | { type: "call"; id: string; name: string; input: unknown }
  | { type: "result"; id: string; text: string; error: boolean }
  | { type: "text"; text: string };

/** An act waiting for the person's word: today only a mail draft. */
export type Act = { kind: "mail"; account: string | null; to: string; subject: string; body: string };
export type Pending = { id: number; act: Act; event: string | null };
/** A card in the tray: `busy` while a verdict is carried out, `error` when it failed. */
export type Card = Pending & { busy?: boolean; error?: string };

type Said = { i: number; kind: string; text: string; date: string; reaction: string | null };

type Shown =
  | { type: "said"; id: string; text: string; plain: boolean; aside: boolean }
  | { type: "heard"; id: string; text: string }
  | { type: "pending"; pending: Pending }
  | { type: "settled"; id: number; text: string; done: boolean }
  | { type: "react"; to: string; emoji: string }
  | { type: "picture"; image: string; mime: string }
  | { type: "file"; name: string }
  | { type: "typing"; on: boolean }
  | { type: "step"; step: Step; agent: string | null }
  | { type: "agents"; agents: Agent[] }
  | { type: "browser"; open: boolean };

/** The longest message text, in bytes, that /api/send takes (SEND_MAX in site.rs). */
const SEND_MAX = 32 * 1024;

const ROLE: Record<string, Msg["role"]> = { user: "user", talk: "assistant", note: "system" };

// A draft as Matrix shows it (pending.rs `Act::show`), kept in hippo as talk;
// on reload it is framed as it was.
const DRAFT = /^Draft to [^\n]+\nSubject: [\s\S]*\n\n👍 sends it, 👎 drops it\.$/;

export type Chat =
  | { state: "loading" }
  | { state: "signed-out" }
  | { state: "error"; error: string }
  | {
      state: "ready";
      messages: Msg[];
      typing: boolean;
      /** `redo` puts the message in place of the person's last one. */
      send: (text: string, files: File[], redo?: "edit" | "again") => Promise<void>;
      stop: () => Promise<void>;
      cards: Card[];
      decide: (id: number, yes: boolean) => Promise<void>;
      tasks: Task[];
      stopTask: (name: string) => Promise<void>;
      /** The computer's screen, when the yeoman has one. */
      screen?: string;
      /** Its width over its height. */
      shape?: number;
      /** Whether the computer's browser is open; opening and closing it. */
      browser: boolean;
      closeBrowser: () => Promise<void>;
      openBrowser: () => Promise<void>;
      /** Reads the conversation afresh from hippo, as after a call. */
      refresh: () => void;
    };

export function useChat(): Chat {
  const [status, setStatus] = useState<"loading" | "signed-out" | "ready" | string>("loading");
  const [messages, setMessages] = useState<Msg[]>([]);
  const [typing, setTyping] = useState(false);
  const [cards, setCards] = useState<Card[]>([]);
  const [tasks, setTasks] = useState<Task[]>([]);
  const [screen, setScreen] = useState<string>();
  const [shape, setShape] = useState<number>();
  const [browser, setBrowser] = useState(false);
  const resync = useRef<() => void>(() => {});

  useEffect(() => {
    let events: EventSource | undefined;
    let retry: number | undefined;
    let ready = false;
    let gone = false;
    // History from hippo, again on every reconnect and return to the page:
    // what the stream carried while nothing listened is in hippo by then.
    const sync = async (): Promise<boolean> => {
      const [r, w, t] = await Promise.all([fetch("/api/history"), fetch("/api/pending"), fetch("/api/task")]);
      if (r.status === 401) {
        setStatus("signed-out");
        return false;
      }
      if (!r.ok) throw new Error(`History failed: ${r.status}`);
      const said: Said[] = await r.json();
      // The tray is extra: a chat without it still works.
      const waiting: Pending[] = w.ok ? await w.json() : [];
      const now: { agents: Agent[]; screen: string | null; size?: string | null; browser?: boolean; typing?: boolean } | null = t.ok ? await t.json() : null;
      if (gone) return false;
      const turning = !!now?.typing;
      if (now) {
        setScreen(now.screen ?? undefined);
        const [w, h] = (now.size ?? "").split("x").map(Number);
        setShape(w && h ? w / h : undefined);
        setBrowser(!!now.browser);
        // The end of a turn may have gone out while nothing listened.
        setTyping(!!now.typing);
        // The work so far went out over the stream; a page that missed it
        // starts from the task.
        setTasks((ks) => atWork(ks, now.agents));
      }
      setMessages((was) => {
        const now: Msg[] = said.map((m) => ({
          id: `h-${m.i}`,
          role: ROLE[m.kind],
          text: m.text,
          plain: m.kind === "talk" && DRAFT.test(m.text),
          reaction: m.reaction ?? undefined,
          date: new Date(m.date),
        }));
        // hippo keeps no tools and no photos, and a phone resyncs each time
        // the page comes back, so an answer found again by its words keeps
        // the tools (and cards) this page saw, and a message sent with files
        // keeps their thumbnails; hippo logs it as "(sent a photo: …) words".
        for (const m of was) {
          for (let j = now.length - 1; j >= 0; j--) {
            const h = now[j];
            if (m.tools && m.text && h.role === "assistant" && !h.tools && h.text === m.text) {
              h.tools = m.tools;
              break;
            }
            if (m.files?.length && h.role === "user" && !h.files && h.text.startsWith("(sent ") && h.text.endsWith(m.text) && m.files.every((f) => h.text.includes(f.name))) {
              Object.assign(h, { text: m.text, files: m.files });
              break;
            }
          }
        }
        // The turn under way is not all in hippo yet: what this page has
        // past hippo's newest message it knew (a message waiting its turn,
        // the words and tools so far) stays until hippo has it too.
        if (!turning) return now;
        const known = was.map((m) => m.id.startsWith("h-")).lastIndexOf(true);
        const newer = now.slice(now.findIndex((m) => m.id === was[known]?.id) + 1);
        const kept = was.slice(known + 1).filter((m) => {
          const j = newer.findIndex((h) => h.role === m.role && h.text === m.text);
          if (j < 0) return true;
          newer.splice(j, 1);
          return false;
        });
        return [...now, ...kept];
      });
      setCards(waiting);
      setStatus("ready");
      ready = true;
      return true;
    };
    // The browser retries a dropped stream by itself but gives up on an
    // answer that isn't 200, such as nginx's 502 while the yeoman restarts;
    // then the page tries again until the yeoman is back.
    const again = () => {
      retry = window.setTimeout(() => {
        sync().then(
          (ok) => ok && listen(),
          () => again(),
        );
      }, 3000);
    };
    const listen = () => {
      events = new EventSource("/api/events");
      let opened = false;
      events.onopen = () => {
        if (opened) sync().catch(() => {});
        opened = true;
      };
      events.onerror = () => {
        if (events?.readyState === EventSource.CLOSED && !gone) again();
      };
      events.onmessage = (e) => {
        const s: Shown = JSON.parse(e.data);
        switch (s.type) {
          case "said":
            setMessages((ms) => {
              // The answer joins the tools and words that led to it; a
              // draft, or what came from no turn, stands alone.
              const last = ms.at(-1);
              if (!s.plain && !s.aside && last?.live) return [...ms.slice(0, -1), { ...last, id: s.id, text: s.text, live: false }];
              return [...ms, { id: s.id, role: "assistant", text: s.text, plain: s.plain, date: new Date() }];
            });
            break;
          case "heard":
            setMessages((ms) => [...ms, { id: s.id, role: "user", text: s.text, date: new Date() }]);
            break;
          case "pending":
            setCards((cs) => (cs.some((c) => c.id === s.pending.id) ? cs : [...cs, s.pending]));
            break;
          case "settled":
            setCards((cs) => (s.done ? cs.filter((c) => c.id !== s.id) : cs.map((c) => (c.id === s.id ? { ...c, busy: false, error: s.text } : c))));
            // What came of it stays in the talk, as it does in hippo.
            if (s.done) setMessages((ms) => [...ms, { id: crypto.randomUUID(), role: "assistant", text: s.text, date: new Date() }]);
            break;
          case "step":
            if (s.agent !== null) setTasks((ks) => taskStep(ks, s.agent!, s.step));
            else setMessages((ms) => step(ms, s.step));
            break;
          case "agents":
            setTasks((ks) => atWork(ks, s.agents));
            break;
          case "browser":
            setBrowser(s.open);
            break;
          case "react":
            setMessages((ms) => ms.map((m) => (m.id === s.to ? { ...m, reaction: s.emoji } : m)));
            break;
          case "picture":
            setMessages((ms) => [...ms, { id: crypto.randomUUID(), role: "assistant", text: "", picture: `data:${s.mime};base64,${s.image}`, date: new Date() }]);
            break;
          case "file":
            setMessages((ms) => [...ms, { id: crypto.randomUUID(), role: "assistant", text: "", file: s.name, date: new Date() }]);
            break;
          case "typing":
            setTyping(s.on);
            // A turn that ended without an answer leaves its tools standing,
            // and loses the words it never finished.
            if (!s.on) setMessages((ms) => ms.flatMap((m) => (!m.live ? [m] : m.tools ? [{ ...m, text: "", live: false }] : [])));
            break;
        }
      };
    };
    // A phone suspends a page it hides, stream and all.
    const shown = () => {
      if (ready && document.visibilityState === "visible") sync().catch(() => {});
    };
    document.addEventListener("visibilitychange", shown);
    resync.current = () => void sync().catch(() => {});
    // A first load that fails says why and keeps trying.
    sync().then(
      (ok) => ok && listen(),
      (e) => {
        setStatus(`${e instanceof Error ? e.message : e}. Trying again…`);
        again();
      },
    );
    return () => {
      gone = true;
      window.clearTimeout(retry);
      events?.close();
      document.removeEventListener("visibilitychange", shown);
    };
  }, []);

  const send = useCallback(async (text: string, files: File[], redo?: "edit" | "again") => {
    // Words too long for a message go as a text file, read whole, as
    // ChatGPT and Claude take a long paste.
    if (new TextEncoder().encode(text).length > SEND_MAX) {
      files = [...files, new File([text], "pasted.txt", { type: "text/plain" })];
      text = "";
    }
    const local = crypto.randomUUID();
    const shown = files.map((f) => ({ name: f.name, image: f.type.startsWith("image/") ? URL.createObjectURL(f) : undefined }));
    setMessages((ms) => {
      // A redo takes the place of the last exchange, as the history will.
      const at = redo ? ms.map((m) => m.role).lastIndexOf("user") : -1;
      return [...(at < 0 ? ms : ms.slice(0, at)), { id: local, role: "user", text, files: shown, date: new Date() }];
    });
    const body = new FormData();
    body.set("text", text);
    if (redo) body.set("redo", redo);
    for (const f of files) {
      body.append("file", f);
      const view = views.get(f);
      if (view) body.append("view", view);
    }
    const r = await fetch("/api/send", { method: "POST", body }).catch(() => undefined);
    if (r?.status === 401) return setStatus("signed-out");
    if (!r?.ok) {
      setMessages((ms) => ms.map((m) => (m.id === local ? { ...m, reaction: "⚠️" } : m)));
      // A redo refused leaves the history as it was; the page shows that again.
      if (redo) resync.current();
      return;
    }
    // The server's id, so a reaction finds the message.
    const { id } = (await r.json()) as { id: string };
    setMessages((ms) => ms.map((m) => (m.id === local ? { ...m, id } : m)));
  }, []);

  // The turn answers "(Stopped.)" over the stream.
  const stop = useCallback(async () => {
    const r = await fetch("/api/stop", { method: "POST" }).catch(() => undefined);
    if (r?.status === 401) setStatus("signed-out");
  }, []);

  // The agent ends on the yeoman's next tick, within half a minute.
  const stopTask = useCallback(async (name: string) => {
    const stopping = (on: boolean) => setTasks((ks) => ks.map((k) => (k.name === name ? { ...k, stopping: on } : k)));
    stopping(true);
    const r = await fetch(`/api/agent/${encodeURIComponent(name)}/stop`, { method: "POST" }).catch(() => undefined);
    if (r?.status === 401) setStatus("signed-out");
    // Not asked after all: the button comes back to try again.
    else if (!r?.ok) stopping(false);
  }, []);

  // The keeper lets the browser go; the screen leaves with the news of it.
  const openBrowser = useCallback(async () => {
    const r = await fetch("/api/browser/open", { method: "POST" }).catch(() => undefined);
    if (r?.status === 401) setStatus("signed-out");
    else if (r?.ok) setBrowser(true);
  }, []);
  const closeBrowser = useCallback(async () => {
    const r = await fetch("/api/browser/close", { method: "POST" }).catch(() => undefined);
    if (r?.status === 401) setStatus("signed-out");
    else if (r?.ok) setBrowser(false);
  }, []);

  const decide = useCallback(async (id: number, yes: boolean) => {
    setCards((cs) => cs.map((c) => (c.id === id ? { ...c, busy: true, error: undefined } : c)));
    const r = await fetch("/api/decide", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ id, yes }),
    }).catch(() => undefined);
    if (r?.status === 401) return setStatus("signed-out");
    // Gone means decided already, here or in Matrix.
    if (r?.status === 404) return setCards((cs) => cs.filter((c) => c.id !== id));
    // Accepted: `settled` comes over the stream once it is carried out.
    if (!r?.ok) setCards((cs) => cs.map((c) => (c.id === id ? { ...c, busy: false, error: r ? `That failed (${r.status}).` : "The yeoman couldn't be reached." } : c)));
  }, []);

  const refresh = useCallback(() => resync.current(), []);

  if (status === "loading" || status === "signed-out") return { state: status };
  if (status !== "ready") return { state: "error", error: status };
  return { state: "ready", messages, typing, send, stop, cards, decide, tasks, stopTask, screen, shape, browser, closeBrowser, openBrowser, refresh };
}

// The agents at work now, each keeping the work the page has seen of it.
function atWork(ks: Task[], agents: Agent[]): Task[] {
  return agents.map((a) => ks.find((k) => k.name === a.name) ?? { name: a.name, text: a.task, tools: [], words: "" });
}

// An agent's steps before the page heard it started still belong to it.
function taskStep(ks: Task[], name: string, s: Step): Task[] {
  const k = ks.find((k) => k.name === name);
  const t = k ?? { name, text: "", tools: [], words: "" };
  const next =
    s.type === "text"
      ? { ...t, words: t.words + s.text }
      : s.type === "result"
        ? { ...t, tools: t.tools.map((x) => (x.id === s.id ? { ...x, result: s.text, error: s.error } : x)) }
        : { ...t, words: "", tools: [...t.tools, { id: s.id, name: s.name, input: s.input }] };
  return k ? ks.map((x) => (x === k ? next : x)) : [...ks, next];
}

/** Whether these tools drive the computer, so its screen is worth watching. */
export const drives = (tools: Tool[] | undefined) => !!tools?.some((t) => t.name.startsWith("mcp__computer__"));

function step(ms: Msg[], s: Step): Msg[] {
  const last = ms.at(-1);
  if (s.type === "text") {
    if (last?.live) return [...ms.slice(0, -1), { ...last, text: last.text + s.text }];
    return [...ms, { id: crypto.randomUUID(), role: "assistant", text: s.text, live: true, date: new Date() }];
  }
  if (s.type === "result") {
    const done = (t: Tool) => (t.id === s.id ? { ...t, result: s.text, error: s.error } : t);
    return ms.map((m) => (m.tools?.some((t) => t.id === s.id) ? { ...m, tools: m.tools.map(done) } : m));
  }
  const tool = { id: s.id, name: s.name, input: s.input };
  // Words before a call lead into it and are not the answer, which
  // comes whole in `said`.
  if (last?.live) return [...ms.slice(0, -1), { ...last, text: "", tools: [...(last.tools ?? []), tool] }];
  return [...ms, { id: `w-${s.id}`, role: "assistant", text: "", tools: [tool], live: true, date: new Date() }];
}

// The model reads photos up to 3.75 MB (IMAGE_MAX in main.rs) in JPEG, PNG,
// GIF or WebP. A phone photo is often bigger, or HEIC, so the page redraws
// it as a JPEG no longer than 2048 px on its long side, which the model
// downscales to anyway. That copy goes along as the photo's view; the
// original is what the yeoman keeps.
const views = new WeakMap<File, File>();
const PHOTO_MAX = 3_500_000;
const PHOTO_TYPES = ["image/jpeg", "image/png", "image/gif", "image/webp"];

async function fit(file: File): Promise<File | undefined> {
  if (!file.type.startsWith("image/") || (file.size <= PHOTO_MAX && PHOTO_TYPES.includes(file.type))) return;
  // One the browser can't draw (a TIFF, a RAW) is kept unseen.
  const bitmap = await createImageBitmap(file).catch(() => undefined);
  if (!bitmap) return;
  const scale = Math.min(1, 2048 / Math.max(bitmap.width, bitmap.height));
  const canvas = new OffscreenCanvas(Math.round(bitmap.width * scale), Math.round(bitmap.height * scale));
  canvas.getContext("2d")!.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  const blob = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.85 });
  return new File([blob], file.name.replace(/\.[^.]*$/, "") + ".jpg", { type: "image/jpeg" });
}

/** Holds a chosen file in the composer until it goes out with the message. */
export const attachments: AttachmentAdapter = {
  accept: "*",
  async add({ file }) {
    const view = await fit(file);
    if (view) views.set(file, view);
    return {
      id: crypto.randomUUID(),
      type: file.type.startsWith("image/") ? "image" : "document",
      name: file.name,
      contentType: file.type,
      file,
      status: { type: "requires-action", reason: "composer-send" },
    };
  },
  async remove() {},
  async send(a) {
    return { ...a, status: { type: "complete" }, content: [] };
  },
};

/** A message hippo found, cut to the words around the match. */
export type Hit = { i: number; kind: string; date: string; text: string };

/** Messages holding the words in that order, newest last; `more` when hippo kept only the newest. */
export async function search(words: string): Promise<{ hits: Hit[]; more: boolean } | { error: string }> {
  // Plain words, not a regex: each escaped, anything allowed between them.
  const q =
    "(?s)" +
    words
      .trim()
      .split(/\s+/)
      .map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
      .join(".*");
  const r = await fetch(`/api/search?q=${encodeURIComponent(q)}`);
  if (r.ok) return r.json();
  return { error: `Search failed (${r.status}).` };
}

/** One message whole. */
export async function said(i: number): Promise<string | undefined> {
  const r = await fetch(`/api/said/${i}`);
  return r.ok ? r.text() : undefined;
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
