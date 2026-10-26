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
  /** A picture the yeoman sent, as a URL. */
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
  /** The model's thinking since its last call, summarized, as it streams. */
  thinking?: string;
};

/** A tool call: `before` holds the words the model said on its way to it,
 * which the page shows above it, as a terminal does. */
export type Tool = { id: string; name: string; input: unknown; result?: string; error?: boolean; before?: string; thought?: string; agent?: string; report?: string; told?: string };

/** A subagent on its own: its name, its task, and its work so far, words
 * and calls in order. One the seat's Agent call started goes by the call's
 * id, with `title` its description; nothing outside the CLI can stop it.
 * `stopping` once a stop is asked for; `done` once it has left the list. */
export type Task = { name: string; text: string; tools: Tool[]; words: string; title?: string; stopping?: boolean; done?: boolean };

type Agent = { name: string; task: string; title?: string };

type Step =
  | { type: "call"; id: string; name: string; input: unknown }
  | { type: "result"; id: string; text: string; error: boolean }
  | { type: "text"; text: string }
  | { type: "thinking"; text: string }
  | { type: "jobs"; names: string[] }
  | { type: "done"; id: string; report: string };

/** An act waiting for the person's word: today only a mail draft. */
export type Act = { kind: "mail"; account: string | null; to: string; subject: string; body: string };
export type Pending = { id: number; act: Act; event: string | null };
/** A card in the tray: `busy` while a verdict is carried out, `error` when it failed. */
export type Card = Pending & { busy?: boolean; error?: string };

/** One of AskUserQuestion's questions. */
export type Question = { question: string; header?: string; options: { label: string; description?: string }[]; multiSelect?: boolean };
/** What the seat asks mid-turn, as Claude Code would in a terminal: may `tool` run, or AskUserQuestion's questions. */
export type Ask = { id: string; tool: string; input: Record<string, unknown>; about: string | null; busy?: boolean };
/** Each question's answer, by its text; several picks joined by ", ". */
export type Answers = Record<string, string>;

type Said = { i: number; kind: string; text: string; date: string; reaction: string | null };

/** A line of the yeoman's view of its past: messages `id` to `id+n`, folded into one summary. */
export type Part = { id: number; n: number; text: string };

type Shown =
  | { type: "said"; id: string; text: string; plain: boolean; aside: boolean }
  | { type: "heard"; id: string; text: string; from?: string }
  | { type: "pending"; pending: Pending }
  | { type: "settled"; id: number; text: string; done: boolean }
  | { type: "react"; to: string; emoji: string }
  | { type: "picture"; name: string }
  | { type: "file"; name: string }
  | { type: "typing"; on: boolean }
  | { type: "step"; step: Step; agent: string | null }
  | { type: "agents"; agents: Agent[] }
  | { type: "browser"; open: boolean }
  | { type: "ask"; ask: Ask }
  | { type: "asked"; id: string }
  | { type: "forgot" };

/** The slash commands the page answers itself; `/` opens them as a menu. */
export const COMMANDS: { name: string; arg?: string; does: string }[] = [
  { name: "model", arg: "[name]", does: "show or switch the model for the next turns" },
  { name: "effort", arg: "[level]", does: "show or switch the thinking effort for the next turns" },
  { name: "stop", does: "stop the turn running now" },
  { name: "help", does: "list these commands" },
  { name: "clear", does: "start afresh (every turn already does)" },
  { name: "new", does: "the same as /clear" },
  { name: "compact", does: "the same as /clear" },
];

/** The longest message text, in bytes, that /api/send takes (SEND_MAX in site.rs). */
export const SEND_MAX = 32 * 1024;

const ROLE: Record<string, Msg["role"]> = { user: "user", talk: "assistant", note: "system" };

// A draft as Matrix shows it (pending.rs `Act::show`), kept in hippo as talk;
// on reload it is framed as it was.
const DRAFT = /^Draft to [^\n]+\nSubject: [\s\S]*\n\n👍 sends it, 👎 drops it\.$/;
/** How hippo logs a picture or file the yeoman sent (`send_outbox`). */
const SENT = /^\(sent a (picture|file): (.+)\)$/;
// Whole, since assistant-ui shows a picture only from an https: (or data:
// or blob:) URL.
const fileUrl = (name: string) => new URL(`api/file/${encodeURIComponent(name)}`, location.href).href;

export type Chat =
  | { state: "loading" }
  | { state: "signed-out" }
  | { state: "error"; error: string }
  | {
      state: "ready";
      messages: Msg[];
      typing: boolean;
      /** The turn's background jobs still running, by description. */
      jobs: string[];
      /** `redo` puts the message in place of the person's last one. */
      send: (text: string, files: File[], redo?: "edit" | "again") => Promise<void>;
      stop: () => Promise<void>;
      cards: Card[];
      decide: (id: number, yes: boolean) => Promise<void>;
      asks: Ask[];
      /** Lets the tool run (with answers, for questions) or refuses it. */
      reply: (id: string, yes: boolean, answers?: Answers) => Promise<void>;
      tasks: Task[];
      stopTask: (name: string) => Promise<void>;
      /** Tells a subagent the person's words, as tell_agent would; false if it couldn't. */
      tellTask: (name: string, text: string) => Promise<boolean>;
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
      /** What came before the history, folded as the yeoman sees it; empty while it loads. */
      past: Part[];
    };

export function useChat(): Chat {
  const [status, setStatus] = useState<"loading" | "signed-out" | "ready" | string>("loading");
  const [messages, setMessages] = useState<Msg[]>([]);
  const [typing, setTyping] = useState(false);
  const [jobs, setJobs] = useState<string[]>([]);
  const [cards, setCards] = useState<Card[]>([]);
  const [asks, setAsks] = useState<Ask[]>([]);
  const [tasks, setTasks] = useState<Task[]>([]);
  const [screen, setScreen] = useState<string>();
  const [shape, setShape] = useState<number>();
  const [browser, setBrowser] = useState(false);
  const [past, setPast] = useState<Part[]>([]);
  const resync = useRef<() => void>(() => {});

  useEffect(() => {
    let events: EventSource | undefined;
    let retry: number | undefined;
    let ready = false;
    let gone = false;
    // Where the past was last asked to end: it changes only as the history moves on.
    let before: number | undefined;
    // History from hippo, again on every reconnect and return to the page:
    // what the stream carried while nothing listened is in hippo by then.
    const sync = async (): Promise<boolean> => {
      const [r, w, t, a] = await Promise.all([fetch("api/history"), fetch("api/pending"), fetch("api/task"), fetch("api/asks")]);
      if (r.status === 401) {
        setStatus("signed-out");
        return false;
      }
      if (!r.ok) throw new Error(`History failed: ${r.status}`);
      const said: Said[] = await r.json();
      // Apart, since hippo may first wait for its summaries to settle.
      const start = said[0]?.i ?? 0;
      if (start !== before) {
        before = start;
        if (start === 0) setPast([]);
        else
          fetch(`api/past?before=${start}`)
            .then((r) => (r.ok ? r.json() : Promise.reject()))
            .then((p: Part[]) => !gone && start === before && setPast(p))
            // Asked again on the next sync.
            .catch(() => {
              if (start === before) before = undefined;
            });
      }
      // The tray is extra: a chat without it still works.
      const waiting: Pending[] = w.ok ? await w.json() : [];
      const asked: Ask[] = a.ok ? await a.json() : [];
      const now: { agents: Agent[]; screen: string | null; size?: string | null; browser?: boolean; typing?: boolean; turn?: { start: number; shown: Shown[] } } | null = t.ok
        ? await t.json()
        : null;
      if (gone) return false;
      const turning = !!now?.typing;
      const turnRecord = now?.turn;
      if (now) {
        setScreen(now.screen ?? undefined);
        const [w, h] = (now.size ?? "").split("x").map(Number);
        setShape(w && h ? w / h : undefined);
        setBrowser(!!now.browser);
        // The end of a turn may have gone out while nothing listened.
        setTyping(!!now.typing);
        setJobs(turning ? jobsOf(now.turn?.shown ?? []) : []);
        // The work so far went out over the stream; a page that missed it
        // starts from the task.
        setTasks((ks) => atWork(ks, now.agents));
      }
      setMessages((was) => {
        const now = fromHistory(said);
        // A yeoman's hippo keeps no tools, and a phone resyncs each time
        // the page comes back, so an answer found again by its words keeps
        // the tools (and cards) this page saw.
        for (const m of was) {
          for (let j = now.length - 1; j >= 0; j--) {
            const h = now[j];
            if (m.tools && m.text && h.role === "assistant" && !h.tools && h.text === m.text) {
              h.tools = m.tools;
              break;
            }
          }
        }
        // The last turn as the yeoman showed it, for when hippo hasn't got
        // it: a seat's turn reaches hippo only once it ends, so a page
        // loaded meanwhile would lose the person's words and the calls.
        // hippo has it once it holds the turn's prompt: the person's words,
        // or the note a routine's or a report's turn begins with.
        const record = turnRecord;
        if (record?.shown.length) {
          const newer = now.filter((m) => (m.date?.getTime() ?? 0) >= record.start - 1000);
          if (!turning && newer.some((m) => m.role === "user" || m.role === "system")) return now;
          let shown = record.shown.reduce(onto, [] as Msg[]);
          if (!turning) shown = shown.flatMap((m) => (!m.live ? [m] : m.tools ? [{ ...m, text: "", live: false }] : []));
          const kept = shown.filter((m) => {
            const j = newer.findIndex((h) => h.role === m.role && (h.text === m.text || (m.role === "user" && h.text.endsWith(m.text))));
            if (j < 0) return true;
            newer.splice(j, 1);
            return false;
          });
          // This page's own copy keeps what the record has not: thumbnails.
          for (const m of kept) {
            const mine = was.find((w) => w.id === m.id);
            if (mine?.files) m.files = mine.files;
          }
          return [...now, ...kept];
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
        // A seat's turn under way is in hippo in part, tools and all: the
        // live one takes over hippo's, keeping what each has.
        const live = kept.findIndex((m) => m.live);
        const last = now.at(-1);
        if (live >= 0 && !kept.slice(0, live).some((m) => m.role === "user") && last?.role === "assistant" && last.tools && kept[live].tools) {
          return [...now.slice(0, -1), ...kept.slice(0, live), joinTurn(last, kept[live]), ...kept.slice(live + 1)];
        }
        return [...now, ...kept];
      });
      setCards(waiting);
      setAsks(asked);
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
      events = new EventSource("api/events");
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
          case "heard":
          case "picture":
          case "file":
            setMessages((ms) => onto(ms, s));
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
            if (s.step.type === "jobs") {
              if (s.agent === null) setJobs(s.step.names);
            } else if (s.agent !== null) setTasks((ks) => taskStep(ks, s.agent!, s.step));
            else setMessages((ms) => onto(ms, s));
            break;
          case "agents":
            setTasks((ks) => atWork(ks, s.agents));
            break;
          case "ask":
            setAsks((as) => (as.some((a) => a.id === s.ask.id) ? as : [...as, s.ask]));
            break;
          case "asked":
            setAsks((as) => as.filter((a) => a.id !== s.id));
            break;
          case "browser":
            setBrowser(s.open);
            break;
          case "forgot":
            // The oldest went and the rest were numbered again: all of it
            // is read afresh, the folds above too.
            before = undefined;
            sync().catch(() => {});
            break;
          case "react":
            setMessages((ms) => ms.map((m) => (m.id === s.to ? { ...m, reaction: s.emoji } : m)));
            break;
          case "typing":
            setTyping(s.on);
            if (!s.on) setJobs([]);
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

  // A slash command the page knows is done here, answered with a note, as
  // Claude Code and Codex answer theirs in place; any other goes on as
  // words, so the agent's own commands and skills still reach it.
  const command = useCallback(async (text: string) => {
    const [, name, arg] = /^\/(\w+)\s*(.*)$/s.exec(text.trim()) ?? [];
    const c = COMMANDS.find((c) => c.name === name?.toLowerCase());
    if (!c) return false;
    const note = (said: string) => setMessages((ms) => [...ms, { id: crypto.randomUUID(), role: "system", text: said, date: new Date() }]);
    if (c.name === "stop") {
      const r = await fetch("api/stop", { method: "POST" }).catch(() => undefined);
      if (r?.status === 401) setStatus("signed-out");
    } else if (c.name === "model" || c.name === "effort") {
      const [what, list] = c.name === "model" ? ["model", "models"] as const : ["effort", "efforts"] as const;
      const [now, me] = await Promise.all([
        fetch(`api/${what}`).then((r) => r.json() as Promise<Record<string, string>>).catch(() => undefined),
        fetch("api/me").then((r) => r.json() as Promise<Record<string, string[]>>).catch(() => undefined),
      ]);
      const current = now?.[what];
      const choices = me?.[list] ?? [];
      const want = arg.trim().toLowerCase();
      const running = what === "model" ? `Running on ${current || "the default model"}.` : `Thinking at ${current || "the default effort"}.`;
      if (!want) note(`${running}${choices.length ? ` /${what} ${choices.join(`, /${what} `)} switches.` : ""}`);
      else if (want === current) note(`Already on ${want}.`);
      else {
        const r = await fetch(`api/${what}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ [what]: want }) }).catch(() => undefined);
        if (r?.status === 401) return setStatus("signed-out"), true;
        note(r?.ok ? `Switched to ${want}, from the next turn on.` : `No ${what} ${want}.${choices.length ? ` The choices are ${choices.join(", ")}.` : ""}`);
      }
    } else if (c.name === "help") {
      note(COMMANDS.map((c) => `/${c.name}${c.arg ? ` ${c.arg}` : ""}: ${c.does}`).join("\n"));
    } else {
      // clear, new, compact: a turn here is never long-lived.
      note("Nothing to clear: every turn starts fresh, and what came before lives in memory, not in a running context.");
    }
    return true;
  }, []);

  const send = useCallback(async (text: string, files: File[], redo?: "edit" | "again") => {
    if (!redo && !files.length && text.startsWith("/") && (await command(text))) return;
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
    body.set("local", local);
    if (redo) body.set("redo", redo);
    for (const f of files) {
      body.append("file", f);
      const view = views.get(f);
      if (view) body.append("view", view);
    }
    const r = await fetch("api/send", { method: "POST", body }).catch(() => undefined);
    if (r?.status === 401) return setStatus("signed-out");
    if (!r?.ok) {
      setMessages((ms) => ms.map((m) => (m.id === local ? { ...m, reaction: "⚠️" } : m)));
      // A redo refused leaves the history as it was; the page shows that again.
      if (redo) resync.current();
      return;
    }
    // The server's id, so a reaction finds the message.
    const { id } = (await r.json()) as { id: string };
    setMessages((ms) => (ms.some((m) => m.id === id) ? ms : ms.map((m) => (m.id === local ? { ...m, id } : m))));
  }, []);

  // The turn answers "(Stopped.)" over the stream.
  const stop = useCallback(async () => {
    const r = await fetch("api/stop", { method: "POST" }).catch(() => undefined);
    if (r?.status === 401) setStatus("signed-out");
  }, []);

  // The agent ends on the yeoman's next tick, within half a minute.
  const stopTask = useCallback(async (name: string) => {
    const stopping = (on: boolean) => setTasks((ks) => ks.map((k) => (k.name === name ? { ...k, stopping: on } : k)));
    stopping(true);
    const r = await fetch(`api/agent/${encodeURIComponent(name)}/stop`, { method: "POST" }).catch(() => undefined);
    if (r?.status === 401) setStatus("signed-out");
    // Not asked after all: the button comes back to try again.
    else if (!r?.ok) stopping(false);
  }, []);

  // The words join its work where they fall, as the person said them; a
  // done agent goes on from its log and comes back to the list at work.
  const tellTask = useCallback(async (name: string, text: string) => {
    const r = await fetch(`api/agent/${encodeURIComponent(name)}/tell`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ text }) }).catch(() => undefined);
    if (r?.status === 401) setStatus("signed-out");
    if (!r?.ok) return false;
    setTasks((ks) => ks.map((k) => (k.name === name ? { ...k, words: "", tools: [...k.tools, { id: `told-${Date.now()}`, name: "", input: null, told: text, before: k.words.trim() || undefined }] } : k)));
    return true;
  }, []);

  // The keeper lets the browser go; the screen leaves with the news of it.
  const openBrowser = useCallback(async () => {
    const r = await fetch("api/browser/open", { method: "POST" }).catch(() => undefined);
    if (r?.status === 401) setStatus("signed-out");
    else if (r?.ok) setBrowser(true);
  }, []);
  const closeBrowser = useCallback(async () => {
    const r = await fetch("api/browser/close", { method: "POST" }).catch(() => undefined);
    if (r?.status === 401) setStatus("signed-out");
    else if (r?.ok) setBrowser(false);
  }, []);

  const decide = useCallback(async (id: number, yes: boolean) => {
    setCards((cs) => cs.map((c) => (c.id === id ? { ...c, busy: true, error: undefined } : c)));
    const r = await fetch("api/decide", {
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

  const reply = useCallback(async (id: string, yes: boolean, answers?: Answers) => {
    setAsks((as) => as.map((a) => (a.id === id ? { ...a, busy: true } : a)));
    const r = await fetch("api/answer", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ id, yes, answers }),
    }).catch(() => undefined);
    if (r?.status === 401) return setStatus("signed-out");
    // Answered: `asked` comes over the stream. Gone: the turn took it back.
    if (r?.status === 404) return setAsks((as) => as.filter((a) => a.id !== id));
    if (!r?.ok) setAsks((as) => as.map((a) => (a.id === id ? { ...a, busy: false } : a)));
  }, []);

  const refresh = useCallback(() => resync.current(), []);

  if (status === "loading" || status === "signed-out") return { state: status };
  if (status !== "ready") return { state: "error", error: status };
  return { state: "ready", messages, typing, jobs, send, stop, cards, decide, asks, reply, tasks, stopTask, tellTask, screen, shape, browser, closeBrowser, openBrowser, refresh, past };
}

// The agents at work now, each keeping the work the page has seen of it;
// those gone from the list are done, and their pages stay to be read.
function atWork(ks: Task[], agents: Agent[]): Task[] {
  const now = agents.map((a) => ({ ...(ks.find((k) => k.name === a.name) ?? { tools: [], words: "" }), name: a.name, text: a.task, title: a.title, done: false }));
  const gone = ks.filter((k) => !agents.some((a) => a.name === k.name)).map((k) => ({ ...k, done: true }));
  return [...gone, ...now];
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
        : s.type === "call" && s.name === "SubagentHandback"
          ? { ...t, words: handback(t.words, s.input) }
          : s.type === "call"
          ? { ...t, words: "", tools: [...t.tools, { id: s.id, name: s.name, input: s.input, before: t.words.trim() || undefined }] }
          : t;
  return k ? ks.map((x) => (x === k ? next : x)) : [...ks, next];
}

// A subagent's id, which its Agent call's result names and hippo keeps its
// chat by; and Claude Code's news of a task done, with its report.
const agentOf = (result: string) => /^agentId: (\w+)/m.exec(result)?.[1];
// What Claude Code says in place of a report it handed back on its own.
export const POINTER = /^This agent's report was delivered to you/;
const NEWS = /^<task-notification>[\s\S]*?<task-id>(\w+)<\/task-id>[\s\S]*?(?:<result>([\s\S]*?)<\/result>|$)/;

// A subagent hands its report back in a call; its page shows it as its
// last words.
const handback = (words: string, input: unknown) => {
  const report = (input as { message?: unknown } | undefined)?.message;
  return typeof report === "string" ? (words.trim() ? `${words}\n\n${report}` : report) : words;
};

/** A subagent's whole chat as hippo zooms it, `{i}|{kind}: {text}` per
 * message, read as its page shows one: the task, then words and calls. */
export function fromAgentChat(text: string): Pick<Task, "text" | "tools" | "words"> {
  const t: Pick<Task, "text" | "tools" | "words"> = { text: "", tools: [], words: "" };
  for (const m of text.split(/\n(?=\d+\|)/)) {
    const [, i, kind, body] = /^(\d+)\|(\w+)(?: \[[^\]]*\])?: ([\s\S]*)$/.exec(m.trim()) ?? [];
    if (!kind) continue;
    if (kind === "user" && !t.text) t.text = body;
    else if (kind === "tool") {
      const [, name, rest] = /^(\S+)\s?([\s\S]*)$/.exec(body) ?? [, body, ""];
      if (name === "SubagentHandback") {
        t.words = handback(t.words, parse(rest));
        continue;
      }
      t.tools.push({ id: `a-${i}`, name, input: parse(rest), before: t.words.trim() || undefined });
      t.words = "";
    } else if (kind === "echo") {
      const open = t.tools.find((x) => x.result === undefined);
      if (open) open.result = body;
    } else if (kind === "talk") t.words += (t.words ? "\n\n" : "") + body;
  }
  return t;
}

/** Whether these tools drive the computer, so its screen is worth watching. */
export const drives = (tools: Tool[] | undefined) => !!tools?.some((t) => t.name.startsWith("mcp__computer__"));

/** What one shown thing does to the talk: the person's words, a call or
 * its result, words on the way, the answer, a picture or a file. */
// The background jobs a turn's record last counted.
function jobsOf(shown: Shown[]): string[] {
  for (let i = shown.length - 1; i >= 0; i--) {
    const s = shown[i];
    if (s.type === "step" && s.agent === null && s.step.type === "jobs") return s.step.names;
  }
  return [];
}

function onto(ms: Msg[], s: Shown): Msg[] {
  switch (s.type) {
    case "said": {
      // The answer joins the tools and words that led to it; a draft, or
      // what came from no turn, stands alone.
      const last = ms.at(-1);
      if (!s.plain && !s.aside && last?.live) return [...ms.slice(0, -1), { ...last, id: s.id, text: s.text, live: false }];
      return [...ms, { id: s.id, role: "assistant", text: s.text, plain: s.plain, date: new Date() }];
    }
    case "heard":
      // This page's own words take the server's id, so a reaction finds
      // them; another page's join the talk.
      if (s.from && ms.some((m) => m.id === s.from)) return ms.map((m) => (m.id === s.from ? { ...m, id: s.id } : m));
      if (ms.some((m) => m.id === s.id)) return ms;
      return [...ms, { id: s.id, role: "user", text: s.text, date: new Date() }];
    case "step":
      return s.step.type === "jobs" ? ms : step(ms, s.step);
    case "picture":
      return [...ms, { id: crypto.randomUUID(), role: "assistant", text: "", picture: fileUrl(s.name), date: new Date() }];
    case "file":
      return [...ms, { id: crypto.randomUUID(), role: "assistant", text: "", file: s.name, date: new Date() }];
    default:
      return ms;
  }
}

function step(ms: Msg[], s: Step): Msg[] {
  const last = ms.at(-1);
  if (s.type === "text") {
    if (last?.live) return [...ms.slice(0, -1), { ...last, text: last.text + s.text }];
    return [...ms, { id: crypto.randomUUID(), role: "assistant", text: s.text, live: true, date: new Date() }];
  }
  if (s.type === "thinking") {
    if (last?.live) return [...ms.slice(0, -1), { ...last, thinking: (last.thinking ?? "") + s.text }];
    return [...ms, { id: crypto.randomUUID(), role: "assistant", text: "", thinking: s.text, live: true, date: new Date() }];
  }
  if (s.type === "result" || s.type === "done") {
    const done = (t: Tool) =>
      t.id !== s.id ? t : s.type === "done" ? (!s.report || POINTER.test(s.report) ? t : { ...t, report: s.report }) : { ...t, result: s.text, error: s.error, agent: agentOf(s.text) ?? t.agent };
    return ms.map((m) => (m.tools?.some((t) => t.id === s.id) ? { ...m, tools: m.tools.map(done) } : m));
  }
  if (s.type === "jobs") return ms;
  const tool: Tool = { id: s.id, name: s.name, input: s.input };
  // Words before a call lead into it and are not the answer, which
  // comes whole in `said`; they stay above the call.
  if (last?.live) {
    if (last.text.trim()) tool.before = last.text;
    if (last.thinking?.trim()) tool.thought = last.thinking;
    return [...ms.slice(0, -1), { ...last, text: "", thinking: undefined, tools: [...(last.tools ?? []), tool] }];
  }
  return [...ms, { id: `w-${s.id}`, role: "assistant", text: "", tools: [tool], live: true, date: new Date() }];
}

// The conversation as hippo keeps it. A seat's history holds its work too,
// a `tool` line per call (`Name {input}`) and an `echo` per result, in the
// order they came: they gather into the answer they led to, as in a live
// turn, with the words between them kept above the call they led into.
// The yeoman marks words sent mid-turn for the model, and hippo logs them so;
// the page shows them as the person wrote them, and so knows them again.
const STEERED = /^\(sent while you were working\) /;

// A seat answers a background job's news that tells the person nothing new
// with this alone (OpenClaw's convention); the yeoman never sends it, and
// the page hides it, and while it streams in, its start.
const QUIET = "NO_REPLY";
export const quiet = (text: string, live = false) => (live ? QUIET.startsWith(text.trim()) : text.trim() === QUIET);

// What a seat is told by its routines, watches, alerts and messages comes
// as words from the person, framed by the yeoman (main.rs, `who`); the page
// shows each as the note the yeoman logged for it.
const FRAMED: [RegExp, string][] = [
  [/^Routine \S+ set, due now: ([\s\S]*)$/, "routine"],
  [/^Watch \S+ set, fired now [\s\S]*?answer only [^:]*: ([\s\S]*)$/, "watch"],
  [/^Alerts from the hosts' sensors[\s\S]*?say so in one line: ([\s\S]*)$/, "alert"],
  [/^Passed on from the household[\s\S]*?through you: ([\s\S]*)$/, "message"],
  [/^From Bridge, the ship's engineer[\s\S]*?what you did: ([\s\S]*)$/, "seat"],
];
const framed = (text: string) => {
  for (const [re, kind] of FRAMED) {
    const m = re.exec(text);
    if (m) return `(${kind}) ${m[1]}`;
  }
};

function fromHistory(said: Said[]): Msg[] {
  const out: Msg[] = [];
  for (const m of said) {
    const last = out.at(-1);
    const turn = last?.role === "assistant" && !last.plain && !last.picture && !last.file ? last : undefined;
    if (m.kind === "tool") {
      const [, name, rest] = /^(\S+)\s?([\s\S]*)$/.exec(m.text) ?? [, m.text, ""];
      const tool: Tool = { id: `h-${m.i}`, name, input: parse(rest) };
      if (!turn) {
        out.push({ id: `h-${m.i}`, role: "assistant", text: "", tools: [tool], date: new Date(m.date) });
        continue;
      }
      if (turn.text.trim()) tool.before = turn.text;
      turn.text = "";
      turn.tools = [...(turn.tools ?? []), tool];
      turn.date = new Date(m.date);
      continue;
    }
    if (m.kind === "work") {
      // A subagent's report as hippo keeps it, `[id]\n{report}\n\nFull chat: …`.
      // A yeoman agent's (`[Ada] report\n…`) has no call to join: the
      // model passes it on in its own words.
      const [, id, report] = /^\[(\w+)\]\n([\s\S]*?)(?:\n\nFull chat: hippo zoom \w+)?$/.exec(m.text) ?? [];
      const call = id && out.flatMap((o) => o.tools ?? []).reverse().find((t) => t.agent === id);
      if (call) call.report = report.trim();
      continue;
    }
    if (m.kind === "echo") {
      // A subagent's report finds the Agent call that started it, by the
      // agent's id; other news of Claude Code's own isn't the model's.
      const news = NEWS.exec(m.text);
      if (news) {
        const call = out.flatMap((o) => o.tools ?? []).reverse().find((t) => t.agent === news[1]);
        if (call && news[2] !== undefined && !POINTER.test(news[2])) call.report = news[2].trim();
        continue;
      }
      // Results come in the order of their calls.
      const open = turn?.tools?.find((t) => t.result === undefined);
      if (open) Object.assign(open, { result: m.text, agent: agentOf(m.text) });
      continue;
    }
    if (m.kind === "talk" && quiet(m.text)) continue;
    // The answer after the calls, once.
    if (m.kind === "talk" && turn?.tools && !turn.text && !SENT.test(m.text) && !DRAFT.test(m.text)) {
      Object.assign(turn, { text: m.text, date: new Date(m.date) });
      continue;
    }
    // What the yeoman sent is kept, and hippo logs it by name.
    const note = m.kind === "user" ? framed(m.text) : undefined;
    if (note) {
      out.push({ id: `h-${m.i}`, role: "system", text: note, date: new Date(m.date) });
      continue;
    }
    const sent = m.kind === "talk" ? SENT.exec(m.text) : null;
    out.push({
      id: `h-${m.i}`,
      role: ROLE[m.kind],
      ...(m.kind === "user" ? theirs(m.text) : { text: sent ? "" : m.text }),
      plain: m.kind === "talk" && DRAFT.test(m.text),
      picture: sent?.[1] === "picture" ? fileUrl(sent[2]) : undefined,
      file: sent?.[1] === "file" ? sent[2] : undefined,
      reaction: m.reaction ?? undefined,
      date: new Date(m.date),
    });
  }
  return out;
}

// The person's words as hippo has them, "[image]\n(sent while you were
// working) (sent a photo: a.png; a file: b.txt) words", as the page shows
// them: the words, under the files kept in the library.
function theirs(text: string): Pick<Msg, "text" | "files"> {
  text = text.replace(/^(\[(image|document)\]\n)+/, "").replace(STEERED, "");
  const sent = /^\(sent ((?:a (?:photo|file): [^;]+?(?:, kept unseen)?(?:; )?)+)\) ?([\s\S]*)$/.exec(text);
  if (!sent) return { text };
  const files = sent[1].split("; ").map((f) => {
    const [, kind, name] = /^a (photo|file): (.+?)(?:, kept unseen)?$/.exec(f) ?? [, "file", f];
    return { name, image: kind === "photo" ? fileUrl(name) : undefined };
  });
  return { text: sent[2], files };
}

// A call's input as the model wrote it; one cut short in hippo stays words.
function parse(input: string): unknown {
  if (!input) return {};
  try {
    return JSON.parse(input);
  } catch {
    return input;
  }
}

// A turn under way, as hippo has it so far and as this page saw it: each
// call the page saw takes its place in hippo's (by its name and input, in
// order) with the id the stream's results will name it by; the rest follow.
function joinTurn(kept: Msg, live: Msg): Msg {
  const tools = [...(kept.tools ?? [])];
  const extra: Tool[] = [];
  let from = 0;
  for (const t of live.tools ?? []) {
    const same = JSON.stringify(t.input);
    const k = tools.findIndex((h, x) => x >= from && h.name === t.name && JSON.stringify(h.input) === same);
    if (k < 0) {
      extra.push(t);
      continue;
    }
    tools[k] = { ...tools[k], id: t.id, result: t.result ?? tools[k].result, error: t.error, before: tools[k].before ?? t.before };
    from = k + 1;
  }
  return { ...kept, id: live.id, tools: [...tools, ...extra], text: live.text || kept.text, live: true };
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
  const r = await fetch(`api/search?q=${encodeURIComponent(q)}`);
  if (r.ok) return r.json();
  return { error: `Search failed (${r.status}).` };
}

/** One message whole. */
export async function said(i: number): Promise<string | undefined> {
  const r = await fetch(`api/said/${i}`);
  return r.ok ? r.text() : undefined;
}

/** A line of the past opened: its two halves, or for one message the message whole and who said it. */
export async function zoom(id: number, n: number): Promise<{ parts: Part[] } | { kind: string; text: string } | undefined> {
  const r = await fetch(`api/zoom/${id}/${n}`);
  return r.ok ? r.json() : undefined;
}

/** Asks to be let in; the yeoman posts the code to Matrix for a 👍. */
export async function askToSignIn(): Promise<{ code: string; secret: string } | { error: string }> {
  const r = await fetch("api/ask", { method: "POST" });
  if (r.ok) return r.json();
  if (r.status === 429) return { error: "A request went out less than a minute ago. Check Matrix, or try again shortly." };
  return { error: `That failed (${r.status}).` };
}

/** Waits for the answer: true once signed in, false when refused or too old. */
export async function waitToSignIn(secret: string): Promise<boolean> {
  for (;;) {
    const r = await fetch("api/wait", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ secret }),
    });
    if (r.status !== 202) return r.ok;
    await new Promise((done) => setTimeout(done, 2000));
  }
}
