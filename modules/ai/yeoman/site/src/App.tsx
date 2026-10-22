import { createContext, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState, type PointerEvent, type ReactNode } from "react";
import {
  ActionBarPrimitive,
  AssistantRuntimeProvider,
  AttachmentPrimitive,
  ComposerPrimitive,
  MessagePartPrimitive,
  MessagePrimitive,
  ThreadPrimitive,
  useAuiState,
  useExternalStoreRuntime,
  type AppendMessage,
  type Attachment,
  type ThreadMessageLike,
  type ToolCallMessagePartProps,
} from "@assistant-ui/react";
import { StreamdownTextPrimitive } from "@assistant-ui/react-streamdown";
import { Streamdown } from "streamdown";
import { usePinchText } from "./pinch";
import { askToSignIn, attachments, drives, fromAgentChat, POINTER, said, search, useChat, waitToSignIn, zoom, type Answers, type Ask, type Card, type Chat, type Hit, type Msg, type Part, type Question, type Task } from "./chat";
import { useTheme } from "./theme";
import { usePush } from "./push";
import { Bars, Call, SPEED, useVoiceChoice, useVoiceSpeed, voiceChoice, voiceSpeed } from "./call";

type Args = ToolCallMessagePartProps["args"];

// A card the model drew, read from its tool's result. A tool may draw
// several: each list is a card of its own. `key` is the tool call's id (with
// `#n` for the nth of several), which holds from the first step to the answer.
type Kind = "weather" | "calendar" | "list" | "inbox" | "mail" | "transactions" | "markets";
type Face =
  | { key: string; kind: "weather"; data: Forecast }
  | { key: string; kind: "calendar"; data: Event[] }
  | { key: string; kind: "list"; data: List | null }
  | { key: string; kind: "inbox"; data: Mail[] }
  | { key: string; kind: "mail"; data: Mail }
  | { key: string; kind: "transactions"; data: Ledger }
  | { key: string; kind: "markets"; data: Markets };

// The cards of one answer make a deck that slides up from behind the
// composer; closing it leaves each card's one-line summary in the talk.
// `open` brings a deck back at a card; `redraw` resends the question that
// led to an answer. Cards are never stored: by nature they go stale, so a
// redraw is a fresh call.
/** `typing`: a turn is running, so the last exchange can't be redone yet. */
type Cards = { open: (key: string) => void; redraw: (msgId: string) => void; typing: boolean };
const CardCtx = createContext<Cards>({ open() {}, redraw() {}, typing: false });
const useCards = () => useContext(CardCtx);

// Subagents, as Victor shows them: each at work is a dot above the
// composer, and its Agent call in the talk is a frame with its report. Both
// open its own page. `open` takes the call's id, and hippo's id for the
// agent, which finds its chat once the page no longer holds it.
type Agents = { tasks: Task[]; open: (call: string, agent?: string, title?: string) => void };
const AgentCtx = createContext<Agents>({ tasks: [], open() {} });
const isAgent = (name: string) => name === "Agent" || name === "Task";

// Which tool draws a card, by its name whichever server carries it.
function cardKind(name: string): Kind | undefined {
  if (name.endsWith("__weather")) return "weather";
  if (name.endsWith("__events")) return "calendar";
  if (/__(lists|list_add|list_remove|share_list)$/.test(name)) return "list";
  if (name.endsWith("__mail_search")) return "inbox";
  if (name.endsWith("__mail_read")) return "mail";
  if (name.endsWith("__transactions")) return "transactions";
  if (name.endsWith("__markets")) return "markets";
}

const convert = (m: Msg): ThreadMessageLike => ({
  id: m.id,
  role: m.role,
  content: [
    // Each call after the words that led to it, in the order they came.
    ...(m.tools ?? []).flatMap((t) => [
      ...(t.before ? [{ type: "text" as const, text: t.before }] : []),
      {
        type: "tool-call" as const,
        toolCallId: t.id,
        toolName: t.name,
        args: (t.input ?? {}) as Args,
        result: t.result,
        isError: t.error,
        artifact: t.agent || t.report ? { agent: t.agent, report: t.report } : undefined,
      },
    ]),
    ...(m.text ? [{ type: "text" as const, text: m.text }] : []),
    ...(m.picture ? [{ type: "image" as const, image: m.picture }] : []),
    ...(m.file ? [{ type: "file" as const, data: `/api/file/${encodeURIComponent(m.file)}`, mimeType: "", filename: m.file }] : []),
  ],
  attachments: m.files?.map((f, n) => ({
    id: `${m.id}-file-${n}`,
    type: f.image ? "image" : "document",
    name: f.name,
    status: { type: "complete" },
    content: f.image ? [{ type: "image", image: f.image }] : [],
  })),
  createdAt: m.date,
  metadata: { custom: { plain: m.plain ?? false, reaction: m.reaction ?? null, live: m.live ?? false } },
});

// Several assistants may share one host, so the server names the site
// in the title and who answers in a meta tag.
const APP = document.title || "Chat";
const NAME = document.querySelector<HTMLMetaElement>('meta[name="persona"]')?.content || APP;

export function App() {
  const chat = useChat();
  if (chat.state === "loading") return <Solo><Dots /></Solo>;
  if (chat.state === "signed-out") return <SignIn />;
  if (chat.state === "error") return <Solo><p className="text-mid">{chat.error}</p></Solo>;
  return <Thread {...chat} />;
}

/** A page with one thing on it, centred high, as UniiChat's sign-in. */
function Solo({ children }: { children: React.ReactNode }) {
  return (
    <>
      <ThemeButton className="fixed top-2.5 right-3" />
      <main className="mx-auto mt-[18vh] w-[min(420px,100%-48px)] text-center">{children}</main>
    </>
  );
}

/** Switches light and dark, showing where a press takes you. */
function ThemeButton({ className = "" }: { className?: string }) {
  const [theme, toggle] = useTheme();
  const dark = theme === "dark";
  return (
    <button
      onClick={toggle}
      aria-label={dark ? "Light mode" : "Dark mode"}
      title={dark ? "Light mode" : "Dark mode"}
      className={`grid size-9 place-items-center rounded-full text-mid hover:bg-hover hover:text-ink ${className}`}
    >
      <svg viewBox="0 0 24 24" className="size-[18px]" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
        {dark ? (
          <>
            <circle cx="12" cy="12" r="4" />
            <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" />
          </>
        ) : (
          <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
        )}
      </svg>
    </button>
  );
}

type Persona = { unit: string; name: string };
type Me = { name: string; personas: Persona[]; voice: string | null; models: string[]; forgets: number[] };

// Who answers here, asked once for the switcher and the speak buttons.
const ME: Promise<Me> = fetch("/api/me")
  .then((r) => (r.ok ? r.json() : Promise.reject()))
  .catch(() => ({ name: "", personas: [], voice: null, models: [], forgets: [] }));

function useMe() {
  const [me, setMe] = useState<Me | null>(null);
  useEffect(() => {
    ME.then(setMe);
  }, []);
  return me;
}

/** The assistant's name; where others share the host, a press lists them
 * and picking one sets the cookie the proxy routes by and reloads. */
function Switcher() {
  const personas = useMe()?.personas ?? [];
  const [open, setOpen] = useState(false);
  const name = <span className="font-serif text-[22px] tracking-[-0.01em]">{NAME}</span>;
  if (personas.length < 2) return name;
  const pick = (p: Persona) => {
    document.cookie = `persona=${p.unit}; Path=/; Max-Age=31536000; Secure; SameSite=Lax`;
    location.reload();
  };
  return (
    <div className="relative">
      <button type="button" onClick={() => setOpen(!open)} aria-haspopup="menu" aria-expanded={open} className="-ml-2 flex items-center gap-1 rounded-full px-2 hover:bg-hover">
        {name}
        <svg viewBox="0 0 24 24" className="size-4 text-mid" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
          <path d="m6 9 6 6 6-6" />
        </svg>
      </button>
      {open && (
        <>
          <div className="fixed inset-0" onClick={() => setOpen(false)} />
          <div role="menu" className="absolute top-full left-0 mt-1 min-w-40 overflow-hidden rounded-[14px] border-[1.25px] border-edge bg-lift py-1 shadow-lift">
            {personas.map((p) => (
              <button
                key={p.unit}
                type="button"
                role="menuitem"
                onClick={() => (p.name === NAME ? setOpen(false) : pick(p))}
                className={`block w-full px-4 py-2 text-left font-serif text-[18px] hover:bg-hover ${p.name === NAME ? "text-ink" : "text-mid"}`}
              >
                {p.name}
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
}

/** A round icon button for the header; `children` are the icon's paths. */
function HeaderButton({ label, onClick, children }: { label: string; onClick: () => void; children: React.ReactNode }) {
  return (
    <button type="button" onClick={onClick} aria-label={label} title={label} className="grid size-9 place-items-center rounded-full text-mid hover:bg-hover hover:text-ink">
      <svg viewBox="0 0 24 24" className="size-[18px]" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
        {children}
      </svg>
    </button>
  );
}

const WHO: Record<string, string> = { user: "You", talk: NAME, note: "Note", work: "Agent" };

// Search over everything hippo keeps, not only the messages on the page: a
// sheet over the chat with the hits newest first; a hit opens to the whole
// message.
function Search({ close }: { close: () => void }) {
  const [words, setWords] = useState("");
  const [found, setFound] = useState<{ hits: Hit[]; more: boolean } | { error: string }>();
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState<{ i: number; text?: string }>();
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && close();
    addEventListener("keydown", esc);
    return () => removeEventListener("keydown", esc);
  }, [close]);
  const find = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!words.trim()) return;
    setBusy(true);
    setOpen(undefined);
    setFound(await search(words));
    setBusy(false);
  };
  const show = async (i: number) => {
    if (open?.i === i) return setOpen(undefined);
    setOpen({ i });
    const text = await said(i);
    setOpen((o) => (o?.i === i ? { i, text: text ?? "(Couldn't open it.)" } : o));
  };
  return (
    <div className="fixed inset-0 z-20 flex flex-col bg-paper/95 backdrop-blur-sm" role="dialog" aria-label="Search">
      <form onSubmit={find} className="mx-auto flex w-[min(740px,100%-40px)] items-center gap-2 pt-3 max-sm:w-[calc(100%-28px)]">
        <input
          autoFocus
          value={words}
          onChange={(e) => setWords(e.target.value)}
          placeholder="Search everything said"
          className="h-11 flex-1 rounded-full border border-frame bg-lift px-4 text-base outline-none focus:border-soft"
        />
        <HeaderButton label="Close search" onClick={close}>
          <path d="M18 6 6 18M6 6l12 12" />
        </HeaderButton>
      </form>
      <div className="flex-1 overflow-y-auto">
        <div className="mx-auto flex w-[min(740px,100%-40px)] flex-col gap-1 py-4 max-sm:w-[calc(100%-28px)]">
          {busy && <Dots />}
          {!busy && found && "error" in found && <p className="text-mid">{found.error}</p>}
          {!busy && found && "hits" in found && found.hits.length === 0 && <p className="text-mid">Nothing found.</p>}
          {!busy && found && "hits" in found && found.more && <p className="pb-2 text-[13px] text-soft">Only the newest matches; add words to find older ones.</p>}
          {!busy &&
            found &&
            "hits" in found &&
            [...found.hits].reverse().map((h) => (
              <button key={h.i} onClick={() => void show(h.i)} className="rounded-xl px-3 py-2.5 text-left hover:bg-hover">
                <div className="flex gap-2 text-xs text-soft">
                  <span className="font-semibold text-mid">{WHO[h.kind] ?? h.kind}</span>
                  <span>{h.date}</span>
                </div>
                <div className="mt-0.5 text-[14.5px] whitespace-pre-wrap [overflow-wrap:anywhere]">
                  {open?.i === h.i ? (open.text ?? <Dots />) : h.text.replace(/\*\*|`/g, "")}
                </div>
              </button>
            ))}
        </div>
      </div>
    </div>
  );
}

// What came before the history, as the yeoman itself sees it: hippo's view,
// drawn as UniiChat draws it. Each line folds many messages into one
// summary and opens into the two lines it was made from, down to a message
// whole.
function Past({ parts }: { parts: Part[] }) {
  return (
    <section aria-label="Earlier" className="flex flex-col gap-0.5 border-b border-hair pb-3">
      <p className="px-3 pb-1 text-[12.5px] text-soft">Earlier, as {NAME} remembers it</p>
      {parts.map((p) => (
        <Fold key={`${p.id}+${p.n}`} part={p} />
      ))}
    </section>
  );
}

type Opened = Awaited<ReturnType<typeof zoom>> | "failed";

/** One line of the past: shut, its summary; open, its halves or its message. */
function Fold({ part }: { part: Part }) {
  const [open, setOpen] = useState(false);
  // Kept once read: a summary never changes, but one not made yet is asked again.
  const [inside, setInside] = useState<Opened>();
  const toggle = async () => {
    if (open) return setOpen(false);
    setOpen(true);
    if (inside && inside !== "failed" && !("parts" in inside && inside.parts.some((p) => p.text.startsWith("(not summarized")))) return;
    setInside((await zoom(part.id, part.n)) ?? "failed");
  };
  // On a phone the size runs into the line's first row, so the text keeps the width.
  const size = <span className="shrink-0 pt-px font-mono text-[11.5px] text-soft max-sm:mr-2">{part.n}x</span>;
  if (!open) {
    return (
      <button type="button" onClick={() => void toggle()} aria-expanded={false} className="flex gap-2.5 rounded-xl px-3 py-1.5 text-left hover:bg-hover max-sm:block max-sm:px-2.5 max-sm:text-[14px] max-sm:leading-snug">
        {size}
        <span className="text-[14px] leading-snug text-mid [overflow-wrap:anywhere]">{part.text.replace(/\*\*|`/g, "")}</span>
      </button>
    );
  }
  // As Unii draws it: the halves inside a thin frame, so each level costs a
  // few pixels, and its fold bar held at the top while it scrolls past.
  return (
    <div className="flex flex-col gap-0.5 rounded-xl border border-frame px-1.5 pb-1.5">
      <button type="button" onClick={() => void toggle()} aria-expanded className="sticky top-0 z-10 -mx-1.5 flex gap-2.5 rounded-t-xl border-b border-hair bg-paper px-3 py-1.5 text-left text-[12.5px] text-soft hover:text-mid">
        <span className="font-mono">▾ {part.n}x</span>
        <span>fold</span>
      </button>
      {!inside ? (
        <div className="px-3">
          <Dots />
        </div>
      ) : inside === "failed" ? (
        <p className="px-3 py-1.5 text-[14px] text-mid">Couldn't open it.</p>
      ) : "parts" in inside ? (
        inside.parts.map((p) => <Fold key={`${p.id}+${p.n}`} part={p} />)
      ) : (
        <div className="px-3 py-1.5">
          <div className="text-xs font-semibold text-mid">{WHO[inside.kind] ?? inside.kind}</div>
          <div className="mt-0.5 text-[14.5px] whitespace-pre-wrap [overflow-wrap:anywhere]">{inside.text}</div>
        </div>
      )}
    </div>
  );
}

// The build the page runs, named by its hashed script; a deploy changes it.
const BUILD = document.querySelector<HTMLScriptElement>('script[type="module"][src]')?.getAttribute("src");

/** True once the server has a newer build than this page: checked when the
 * app comes back to the front, at most once a minute. An installed app
 * lives on in the background, so it would otherwise run an old build until
 * its process died. */
function useUpdate() {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    let last = 0;
    const check = async () => {
      if (document.visibilityState !== "visible" || Date.now() - last < 60_000) return;
      last = Date.now();
      try {
        const html = await (await fetch("/", { cache: "no-store" })).text();
        const now = /<script type="module"[^>]*src="([^"]+)"/.exec(html)?.[1];
        if (BUILD && now && now !== BUILD) setReady(true);
      } catch {
        // Offline: try again next time.
      }
    };
    check();
    document.addEventListener("visibilitychange", check);
    return () => document.removeEventListener("visibilitychange", check);
  }, []);
  return ready;
}

/** Reloads the app on the newest build: the worker first, so notifications
 * run the new sw.js too. */
async function reload() {
  try {
    await (await navigator.serviceWorker?.getRegistration())?.update();
  } catch {
    // An old worker only delays its own update; the page still reloads.
  }
  location.reload();
}

/** The gear in the header: theme, notifications and reload in one menu. A
 * dot on it says a newer build is waiting. */
function Settings() {
  const [open, setOpen] = useState(false);
  const [theme, toggleTheme] = useTheme();
  // Mounted with the header, not the menu, so the worker registers and
  // the bell's state is known before the menu first opens.
  const [bell, toggleBell] = usePush();
  const update = useUpdate();
  const me = useMe();
  const voice = me?.voice;
  const [choice, setChoice] = useVoiceChoice();
  const [speed, setSpeed] = useVoiceSpeed();
  const voices = useVoices(open && !!voice);
  const [model, pickModel] = useModel(open && !!me?.models.length);
  const [forget, pickForget] = useForget(open && !!me?.forgets?.length);
  const [hearing, setHearing] = useState(false);
  const picked = choice ?? voice;
  const hear = () => {
    if (hearing) return stop();
    if (!picked) return;
    setHearing(true);
    play(`Hi, I'm ${me?.name}. This is how I sound.`, picked, () => setHearing(false));
  };
  const row = "flex w-full items-center justify-between gap-6 px-4 py-2.5 text-left text-[15px] hover:bg-hover disabled:opacity-40 disabled:hover:bg-transparent";
  const note = "text-[13px] text-mid";
  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        aria-label="Settings"
        title="Settings"
        aria-haspopup="menu"
        aria-expanded={open}
        className="relative grid size-9 place-items-center rounded-full text-mid hover:bg-hover hover:text-ink"
      >
        <svg viewBox="0 0 24 24" className="size-[18px]" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
          <path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z" />
          <circle cx="12" cy="12" r="3" />
        </svg>
        {update && <span className="absolute top-1.5 right-1.5 size-2 rounded-full bg-accent" />}
      </button>
      {open && (
        <>
          <div className="fixed inset-0" onClick={() => setOpen(false)} />
          <div role="menu" className="absolute top-full right-0 mt-1 min-w-60 overflow-hidden rounded-[14px] border-[1.25px] border-edge bg-lift py-1 shadow-lift">
            <button type="button" role="menuitem" onClick={toggleTheme} className={row}>
              Theme
              <span className={note}>{theme === "dark" ? "Dark" : "Light"}</span>
            </button>
            {bell !== "unsupported" && (
              <button
                type="button"
                role="menuitem"
                onClick={toggleBell}
                disabled={bell === "denied"}
                title={bell === "denied" ? "Blocked in the browser's settings" : undefined}
                className={row}
              >
                Notifications
                <span className={note}>{{ on: "On", off: "Off", denied: "Blocked" }[bell]}</span>
              </button>
            )}
            {voice && (
              <div className="flex w-full items-center justify-between gap-3 px-4 py-2.5 text-[15px]">
                <label htmlFor="voice">Voice</label>
                <span className="flex items-center gap-1">
                  <select
                    id="voice"
                    value={picked ?? ""}
                    onChange={(e) => {
                      stop();
                      setChoice(e.target.value);
                    }}
                    className="max-w-36 bg-transparent text-right text-[13px] text-mid capitalize outline-none"
                  >
                    {/* The shown voice stays listed while xAI's list loads, or if it fails. */}
                    {[...new Set([...voices.map((v) => v.id), ...(picked ? [picked] : [])])].map((id) => (
                      <option key={id} value={id}>
                        {voices.find((v) => v.id === id)?.name ?? id}
                      </option>
                    ))}
                  </select>
                  <button
                    type="button"
                    onClick={hear}
                    aria-label={hearing ? "Stop the sample" : "Hear this voice"}
                    title={hearing ? "Stop the sample" : "Hear this voice"}
                    className="grid size-7 place-items-center rounded-md text-mid hover:bg-hover hover:text-ink"
                  >
                    <svg viewBox="0 0 24 24" className={`size-[15px] ${hearing ? "animate-pulse" : ""}`} fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
                      {hearing ? <rect x="6" y="6" width="12" height="12" rx="1.5" /> : <path d="m7 4 12 8-12 8z" />}
                    </svg>
                  </button>
                </span>
              </div>
            )}
            {voice && (
              <label className="block px-4 py-2.5 text-[15px]">
                <span className="flex justify-between gap-6">
                  Voice speed
                  <span className={note}>{speed.toFixed(1)}×</span>
                </span>
                <input
                  type="range"
                  min={SPEED.min}
                  max={SPEED.max}
                  step={SPEED.step}
                  value={speed}
                  onChange={(e) => setSpeed(Number(e.target.value))}
                  className="mt-2 w-full accent-ink"
                />
              </label>
            )}
            {!!me?.models.length && (
              <div className="flex w-full items-center justify-between gap-3 px-4 py-2.5 text-[15px]">
                <label htmlFor="model">Model</label>
                <select
                  id="model"
                  value={model ?? ""}
                  onChange={(e) => pickModel(e.target.value)}
                  className="max-w-36 bg-transparent text-right text-[13px] text-mid capitalize outline-none"
                >
                  {/* The running model stays listed even when it isn't a choice. */}
                  {[...new Set([...me.models, ...(model ? [model] : [])])].map((m) => (
                    <option key={m} value={m}>
                      {m}
                    </option>
                  ))}
                </select>
              </div>
            )}
            {!!me?.forgets?.length && (
              <div className="flex w-full items-center justify-between gap-3 px-4 py-2.5 text-[15px]">
                <label htmlFor="forget">Forget after</label>
                <select
                  id="forget"
                  value={forget ?? ""}
                  onChange={(e) => pickForget(Number(e.target.value))}
                  className="max-w-36 bg-transparent text-right text-[13px] text-mid outline-none"
                >
                  {me.forgets.map((m) => (
                    <option key={m} value={m}>
                      {forgetLabel(m)}
                    </option>
                  ))}
                </select>
              </div>
            )}
            <button type="button" role="menuitem" onClick={reload} className={row}>
              Reload
              <span className={update ? "text-[13px] text-accent" : note}>{update ? "Update ready" : "Up to date"}</span>
            </button>
          </div>
        </>
      )}
    </div>
  );
}

function Dots() {
  return (
    <div className="flex h-6 items-center gap-1" aria-label="Typing">
      {[0, 150, 300].map((d) => (
        <span key={d} className="size-1.5 animate-bounce rounded-full bg-soft" style={{ animationDelay: `${d}ms` }} />
      ))}
    </div>
  );
}

const button = "h-10 rounded-full bg-ink px-6 text-[15px] font-medium text-paper hover:opacity-85 disabled:opacity-40";

function SignIn() {
  const [code, setCode] = useState<string>();
  const [said, setSaid] = useState<string>();
  const [busy, setBusy] = useState(false);
  const start = async () => {
    setBusy(true);
    setSaid(undefined);
    const asked = await askToSignIn();
    if ("error" in asked) {
      setSaid(asked.error);
      return setBusy(false);
    }
    setCode(asked.code);
    if (await waitToSignIn(asked.secret)) return location.reload();
    setCode(undefined);
    setSaid("Not let in. Ask again if that was a mistake.");
    setBusy(false);
  };
  return (
    <Solo>
      <h1 className="font-serif text-[46px] leading-[1.05] tracking-[-0.015em]">{APP}</h1>
      <p className="mt-[18px] text-[14.5px] text-mid">
        {code ? "React 👍 in Matrix to the message showing this code." : "Sign in by approving a code in Matrix."}
      </p>
      <div className="mt-8 flex flex-col items-center gap-4">
        {code ? (
          <>
            <span className="rounded-xl bg-block px-5 py-3 font-mono text-3xl tracking-[0.2em]">{code}</span>
            <span className="flex items-center gap-2 text-[13px] text-mid">
              <Dots /> Waiting for approval
            </span>
          </>
        ) : (
          <button className={button} disabled={busy} onClick={start}>
            Sign in
          </button>
        )}
        {said && <p className="text-[14.5px] text-mid">{said}</p>}
      </div>
    </Solo>
  );
}

const Arrow = ({ down = false }: { down?: boolean }) => (
  <svg viewBox="0 0 24 24" className={`size-5 ${down ? "rotate-180" : ""}`} fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 19V5M5 12l7-7 7 7" />
  </svg>
);

const Plus = () => (
  <svg viewBox="0 0 24 24" className="size-5" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round">
    <path d="M12 5v14M5 12h14" />
  </svg>
);

/** A local URL for a photo's thumbnail, let go when the chip goes. */
function usePicture(a: Attachment): string | undefined {
  const [url, setUrl] = useState<string>();
  useEffect(() => {
    if (!a.file || !a.file.type.startsWith("image/")) return;
    const u = URL.createObjectURL(a.file);
    setUrl(u);
    return () => URL.revokeObjectURL(u);
  }, [a.file]);
  const shown = a.content?.find((p) => p.type === "image");
  return shown?.type === "image" ? shown.image : url;
}

// A file in the composer or on a sent message: the photo itself, or a
// card with the file's name.
function Chip({ attachment: a, removable = false }: { attachment: Attachment; removable?: boolean }) {
  const picture = usePicture(a);
  return (
    <AttachmentPrimitive.Root className="relative w-fit">
      {picture ? (
        <img src={picture} alt={a.name} className={`rounded-xl border border-hair object-cover ${removable ? "size-16" : "max-h-72 max-w-full"}`} />
      ) : (
        <div className="flex max-w-60 items-center gap-2 rounded-xl border border-hair bg-paper px-3 py-2 text-sm">
          <span className="rounded-md bg-hair px-1.5 py-0.5 text-xs font-semibold text-mid uppercase">{a.name.split(".").pop()?.slice(0, 4)}</span>
          <span className="truncate">{a.name}</span>
        </div>
      )}
      {removable && (
        <AttachmentPrimitive.Remove
          aria-label="Remove"
          className="absolute -top-1.5 -right-1.5 grid size-5 place-items-center rounded-full bg-ink text-xs leading-none text-paper"
        >
          ×
        </AttachmentPrimitive.Remove>
      )}
    </AttachmentPrimitive.Root>
  );
}

/** A file the yeoman sent back: its card saves it. */
function Download() {
  const part = useAuiState((s) => (s.part.type === "file" ? s.part : null));
  if (!part) return null;
  const name = part.filename ?? "file";
  return (
    <a
      href={part.data}
      download={name}
      className="my-1 flex w-fit max-w-full items-center gap-2.5 rounded-xl border border-hair bg-paper px-3 py-2 text-sm no-underline hover:bg-hover"
    >
      <span className="rounded-md bg-hair px-1.5 py-0.5 text-xs font-semibold text-mid uppercase">{name.includes(".") ? name.split(".").pop()?.slice(0, 4) : "file"}</span>
      <span className="truncate text-ink">{name}</span>
      <svg viewBox="0 0 24 24" className="size-4 shrink-0 text-mid" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
        <path d="M12 4v12m0 0-5-5m5 5 5-5M5 20h14" />
      </svg>
    </a>
  );
}

type Send = Extract<Chat, { state: "ready" }>["send"];
type Decide = (id: number, yes: boolean) => Promise<void>;
type Reply = (id: string, yes: boolean, answers?: Answers) => Promise<void>;

type ThreadProps = {
  messages: Msg[];
  typing: boolean;
  send: Send;
  stop: () => Promise<void>;
  cards: Card[];
  decide: Decide;
  asks: Ask[];
  reply: Reply;
  tasks: Task[];
  stopTask: (name: string) => Promise<void>;
  screen?: string;
  shape?: number;
  browser: boolean;
  closeBrowser: () => Promise<void>;
  openBrowser: () => Promise<void>;
  refresh: () => void;
  past: Part[];
};

function Thread({ messages, typing, send, stop, cards, decide, asks, reply, tasks, stopTask, screen, shape, browser, closeBrowser, openBrowser, refresh, past }: ThreadProps) {
  usePinchText();
  const [finding, setFinding] = useState(false);
  const [calling, setCalling] = useState(false);
  const voice = useMe()?.voice;
  // The deck on screen, by the card it opened at, and whether it is on its
  // way down so the talk fades back in rather than snapping.
  const [open, setOpen] = useState<string>();
  const [leaving, setLeaving] = useState<Way | false>(false);
  const [agent, setAgent] = useState<{ call: string; agent?: string; title?: string }>();
  const agents = useMemo<Agents>(() => ({ tasks, open: (call, agent, title) => setAgent({ call, agent, title }) }), [tasks]);
  const leave = useRef<number>(undefined);
  // The dots stand for work not yet shown; once words or tools arrive, they show it.
  const working = typing && !messages.at(-1)?.live;
  // The screen shows while the browser is open: from the moment the turn or
  // an agent drives it until the yeoman or the person closes it. On a wide
  // screen it takes the right side, at a size worth reading.
  const last = messages.at(-1);
  const driving = (!!last?.live && drives(last.tools)) || tasks.some((t) => drives(t.tools));
  const watching = !!screen && (browser || driving);
  const wide = useWide();

  // The deck fills the screen down to the top of what sits on the composer,
  // so it rises from behind it; measured, as the composer grows with text,
  // files and the tray.
  // When the dock grows (the screen, a task, a card), the talk scrolls up
  // by as much, so the dock pushes it up rather than covering it.
  const dock = useRef<HTMLDivElement>(null);
  const viewport = useRef<HTMLDivElement>(null);
  const [edge, setEdge] = useState(0);
  const measure = () => dock.current && setEdge(dock.current.getBoundingClientRect().top);
  useEffect(() => {
    const el = dock.current;
    if (!el) return;
    measure();
    let height = el.offsetHeight;
    const o = new ResizeObserver(() => {
      const grew = el.offsetHeight - height;
      height = el.offsetHeight;
      if (grew > 0) viewport.current?.scrollBy({ top: grew, behavior: "instant" });
      measure();
    });
    o.observe(el);
    addEventListener("resize", measure);
    return () => {
      o.disconnect();
      removeEventListener("resize", measure);
    };
  }, []);

  const holder = (key: string | undefined) => {
    const id = key?.split("#")[0];
    return id ? messages.find((m) => m.tools?.some((t) => t.id === id)) : undefined;
  };
  const shown = holder(open);
  const deck = shown ? deckOf(shown) : [];

  const show = (key: string) => {
    measure();
    window.clearTimeout(leave.current);
    setLeaving(false);
    setOpen(key);
  };
  const close = (way: Way = "down") => {
    setLeaving(way);
    leave.current = window.setTimeout(() => {
      setOpen(undefined);
      setLeaving(false);
    }, 280);
  };

  // A deck comes up by itself once, as its first card lands; cards already
  // on the page when it loads stay folded.
  const seen = useRef<Set<string>>(null);
  seen.current ??= new Set(messages.flatMap(deckOf).map((f) => f.key));
  useEffect(() => {
    const fresh = messages.flatMap(deckOf).filter((f) => !seen.current!.has(f.key));
    if (!fresh.length) return;
    for (const f of fresh) seen.current!.add(f.key);
    // A card landing in the deck already up joins it, a swipe away.
    if (!shown || leaving || holder(fresh[0].key) !== shown) show(fresh[0].key);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [messages]);

  // Read when a redraw is pressed, so the cards needn't all redraw on every
  // word that streams in.
  const now = useRef(messages);
  now.current = messages;
  const api = useMemo<Cards>(
    () => ({
      open: show,
      redraw(msgId) {
        // Resend the question that led here — the person's last words before
        // this answer — so the card is drawn afresh from current data. The
        // last answer is replaced, as ChatGPT regenerates; an older one is
        // asked again below, since replacing it would drop all that followed.
        const messages = now.current;
        const i = messages.findIndex((m) => m.id === msgId);
        const last = !typing && !messages.slice(i + 1).some((m) => m.role === "user");
        for (let j = i - 1; j >= 0; j--) if (messages[j].role === "user") return void send(messages[j].text, [], last ? "again" : undefined);
      },
      typing,
    }),
    // `show` only sets state, so the first one serves.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [send, typing],
  );

  const runtime = useExternalStoreRuntime({
    messages,
    convertMessage: convert,
    isRunning: false,
    adapters: { attachments },
    onNew: async (m: AppendMessage) => {
      const text = m.content.flatMap((p) => (p.type === "text" ? [p.text] : [])).join("\n");
      const files = (m.attachments ?? []).flatMap((a) => (a.file ? [a.file] : []));
      if (text.trim() || files.length) {
        if (open) close();
        await send(text, files);
      }
    },
    // Only the person's last message offers Edit (UserMessage).
    onEdit: async (m: AppendMessage) => {
      const text = m.content.flatMap((p) => (p.type === "text" ? [p.text] : [])).join("\n");
      if (text.trim()) await send(text, [], "edit");
    },
  });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
     <CardCtx.Provider value={api}>
     <AgentCtx.Provider value={agents}>
      <ThreadPrimitive.Root className="flex h-full flex-col">
        <header className="relative z-20 flex h-[57px] shrink-0 items-center justify-between border-b border-hair bg-paper px-[max(20px,env(safe-area-inset-left))] max-sm:h-[51px] max-sm:px-3.5">
          <Switcher />
          <div className="-mr-2 flex">
            <HeaderButton label="Search the conversation" onClick={() => setFinding(true)}>
              <circle cx="11" cy="11" r="7" />
              <path d="m20 20-3.5-3.5" />
            </HeaderButton>
            {screen && (
              <HeaderButton label="Open the computer" onClick={() => void openBrowser()}>
                <rect x="3" y="4" width="18" height="12" rx="2" />
                <path d="M8 20h8M12 16v4" />
              </HeaderButton>
            )}
            <Settings />
          </div>
        </header>
        {finding && <Search close={() => setFinding(false)} />}
        <div className="flex min-h-0 flex-1">
        <ThreadPrimitive.Viewport ref={viewport} className="flex min-w-0 flex-1 flex-col overflow-y-auto">
          <main style={{ zoom: "var(--talk, 1)" }} className={`mx-auto flex w-[min(740px,100%-40px)] flex-col gap-3.5 pt-6 pb-10 max-sm:w-[calc(100%-28px)] fades ${deck.length && !leaving ? "faded" : ""}`}>
            {past.length > 0 && <Past parts={past} />}
            <ThreadPrimitive.Messages>
              {({ message }) =>
                message.role === "user" ? <UserMessage /> : message.role === "assistant" ? <AssistantMessage /> : <Note />
              }
            </ThreadPrimitive.Messages>
            {working && <Dots />}
          </main>
          <ThreadPrimitive.ViewportFooter className="sticky bottom-0 z-20 mt-auto bg-[linear-gradient(transparent,var(--paper)_14px)] px-5 pt-[18px] pb-[max(14px,env(safe-area-inset-bottom))] max-sm:px-3.5 max-sm:pt-3 max-sm:pb-[max(8px,env(safe-area-inset-bottom))]">
            <div ref={dock} className="relative mx-auto w-[min(740px,100%)]">
              {/* What waits or works above the composer scrolls as one, so the talk stays in view. */}
              <div className="max-h-[min(66vh,720px)] overflow-y-auto pt-2.5 empty:hidden">
                {screen && !wide && <Screen url={screen} shape={shape} on={watching} driving={driving} close={closeBrowser} />}
                {asks.map((a) => (
                  <AskCard key={a.id} ask={a} reply={reply} />
                ))}
                <Tray cards={cards} decide={decide} />
              </div>
              <AgentDots tasks={tasks} open={(name) => setAgent({ call: name })} />
              <ThreadPrimitive.ScrollToBottom className="absolute -top-12 left-1/2 z-10 grid size-9 -translate-x-1/2 place-items-center rounded-full border border-frame bg-lift text-mid shadow-lift hover:text-ink disabled:invisible">
                <Arrow down />
              </ThreadPrimitive.ScrollToBottom>
              <ComposerPrimitive.Root className="rounded-3xl border border-frame bg-lift py-[7px] pr-[7px] pl-2 shadow-dock focus-within:border-soft max-sm:py-[5px] max-sm:pr-[5px] max-sm:pl-1.5">
                <ComposerPrimitive.AttachmentDropzone className="flex flex-col">
                <div className="flex flex-wrap gap-2 px-3 empty:hidden [&:not(:empty)]:pt-2 [&:not(:empty)]:pb-1">
                  <ComposerPrimitive.Attachments>{({ attachment }) => <Chip attachment={attachment} removable />}</ComposerPrimitive.Attachments>
                </div>
                <div className="flex items-end gap-1.5">
                <ComposerPrimitive.AddAttachment
                  aria-label="Attach files"
                  className="grid size-[38px] shrink-0 place-items-center rounded-full text-mid hover:text-ink disabled:invisible"
                >
                  <Plus />
                </ComposerPrimitive.AddAttachment>
                <ComposerPrimitive.Input
                  autoFocus
                  placeholder={`Message ${NAME}`}
                  className="max-h-[40vh] flex-1 resize-none bg-transparent py-[7px] text-base leading-normal outline-none placeholder:text-soft"
                />
                <Trailing typing={typing} stop={stop} cardOpen={!!deck.length && !leaving} close={close} call={voice ? () => setCalling(true) : undefined} />
                </div>
                </ComposerPrimitive.AttachmentDropzone>
              </ComposerPrimitive.Root>
            </div>
          </ThreadPrimitive.ViewportFooter>
        </ThreadPrimitive.Viewport>
        {screen && wide && <Screen url={screen} shape={shape} on={watching} driving={driving} close={closeBrowser} pane />}
        </div>
        {calling && (
          <Call
            name={NAME}
            ended={() => {
              setCalling(false);
              refresh();
            }}
          />
        )}
        {agent && <AgentPage {...agent} tasks={tasks} stop={stopTask} close={() => setAgent(undefined)} />}
        {deck.length > 0 && <Deck key={deck[0].key} faces={deck} start={open!} leaving={leaving} edge={edge} close={close} />}
      </ThreadPrimitive.Root>
     </AgentCtx.Provider>
     </CardCtx.Provider>
    </AssistantRuntimeProvider>
  );
}

// The one button after the composer: Stop while the yeoman is answering;
// else, with a card up and nothing typed, a down arrow to close it; else,
// with nothing typed and a voice to call, a call; else Send, which the
// primitive greys when there is nothing to send. One button, never two
// half-lit ones.
function Trailing({ typing, stop, cardOpen, close, call }: { typing: boolean; stop: () => Promise<void>; cardOpen: boolean; close: () => void; call?: () => void }) {
  const text = useAuiState((s) => s.composer.text);
  const round = "grid size-[38px] shrink-0 place-items-center rounded-full";
  // Words typed while a turn runs join it, so Send stands in for Stop.
  if (typing && !text.trim())
    return (
      <button type="button" onClick={() => void stop()} aria-label="Stop" title="Stop" className={`${round} border border-frame text-ink hover:bg-hover`}>
        <span className="size-3 rounded-[2px] bg-current" />
      </button>
    );
  if (cardOpen && !text.trim())
    return (
      <button type="button" onClick={() => close()} aria-label="Close the card" title="Close the card" className={`${round} bg-ink text-paper hover:opacity-85`}>
        <Arrow down />
      </button>
    );
  if (call && !text.trim())
    return (
      <button type="button" onClick={call} aria-label={`Call ${NAME}`} title={`Call ${NAME}`} className={`${round} bg-ink text-paper hover:opacity-85`}>
        <Bars />
      </button>
    );
  return (
    <ComposerPrimitive.Send aria-label="Send" className={`${round} bg-ink text-paper disabled:bg-hair disabled:text-soft`}>
      <Arrow />
    </ComposerPrimitive.Send>
  );
}

function useCustom() {
  return useAuiState((s) => s.message.metadata.custom) as { plain: boolean; reaction: string | null; live: boolean };
}

function Reaction() {
  const { reaction } = useCustom();
  return reaction ? (
    <span className="absolute -bottom-3 right-3 rounded-full border border-hair bg-lift px-1.5 py-0.5 text-sm leading-none">{reaction}</span>
  ) : null;
}

/** The time, shown when the pointer rests on a message. */
function Time({ className = "" }: { className?: string }) {
  const at = useAuiState((s) => s.message.createdAt);
  if (!at) return null;
  const today = at.toDateString() === new Date().toDateString();
  const when = at.toLocaleString(undefined, today ? { timeStyle: "short" } : { dateStyle: "medium", timeStyle: "short" });
  return <div className={`text-xs text-soft opacity-0 transition-opacity group-hover:opacity-100 ${className}`}>{when}</div>;
}

// A person's words: framed at the right, as wide as the text. A pasted log
// breaks anywhere rather than running off the page. Their last message, once
// answered, can be edited in place; the new one replaces it and its answer.
function UserMessage() {
  const editing = useAuiState((s) => s.message.composer.isEditing);
  if (editing) return <EditMessage />;
  return (
    <MessagePrimitive.Root className="rise group flex flex-col items-end gap-1.5">
      <div className="flex max-w-[min(82%,560px)] flex-wrap justify-end gap-1.5 empty:hidden">
        <MessagePrimitive.Attachments>{({ attachment }) => <Chip attachment={attachment} />}</MessagePrimitive.Attachments>
      </div>
      <MessagePrimitive.If hasContent>
      <div className="relative w-fit max-w-[min(82%,560px)] rounded-[20px_20px_6px_20px] border-[1.25px] border-edge px-[17px] py-2.5 whitespace-pre-wrap [overflow-wrap:anywhere]">
        <MessagePrimitive.Parts />
        <Reaction />
      </div>
      </MessagePrimitive.If>
      <div className="mt-1 mr-1 flex items-center gap-2">
        <Time />
        <Edit />
      </div>
    </MessagePrimitive.Root>
  );
}

/** Pencil under the person's last message, while no turn runs. Files don't
 * come along, so a message that brought some is asked about anew instead. */
function Edit() {
  const { typing } = useCards();
  const editable = useAuiState((s) => {
    const ms = s.thread.messages;
    let last = ms.length - 1;
    while (last >= 0 && ms[last].role !== "user") last--;
    return last === s.message.index && !s.message.attachments?.length;
  });
  if (typing || !editable) return null;
  return (
    <ActionBarPrimitive.Root>
      <ActionBarPrimitive.Edit
        aria-label="Edit"
        title="Edit"
        className="grid size-7 place-items-center rounded-md text-soft opacity-0 transition-opacity group-hover:opacity-100 hover:bg-hover hover:text-ink max-sm:opacity-100"
      >
        <svg viewBox="0 0 24 24" className="size-[15px]" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
          <path d="M12 20h9" />
          <path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />
        </svg>
      </ActionBarPrimitive.Edit>
    </ActionBarPrimitive.Root>
  );
}

// The message being edited, framed as the composer is; Enter sends, Escape
// cancels.
function EditMessage() {
  return (
    <MessagePrimitive.Root className="flex justify-end">
      <ComposerPrimitive.Root className="flex w-[min(82%,560px)] flex-col gap-2 rounded-[20px] border border-frame bg-lift p-3 shadow-dock focus-within:border-soft">
        <ComposerPrimitive.Input autoFocus className="max-h-[40vh] min-h-12 resize-none bg-transparent px-1.5 text-ink outline-none" />
        <div className="flex justify-end gap-2">
          <ComposerPrimitive.Cancel className="rounded-full px-3.5 py-1.5 text-sm text-mid hover:bg-hover hover:text-ink">Cancel</ComposerPrimitive.Cancel>
          <ComposerPrimitive.Send className="rounded-full bg-ink px-3.5 py-1.5 text-sm text-paper disabled:opacity-40">Send</ComposerPrimitive.Send>
        </div>
      </ComposerPrimitive.Root>
    </MessagePrimitive.Root>
  );
}

type Plugins = Pick<typeof import("./plugins"), "code" | "math">;
let plugins: Plugins | undefined;
let loading: Promise<Plugins> | undefined;
// A code fence, or what may open math.
const NEEDS = /```|\$|\\[([]/;

/** The code and math plugins once loaded, which the first text needing them starts. */
function usePlugins(text: string) {
  const [, loaded] = useState<Plugins>();
  const needed = !plugins && NEEDS.test(text);
  useEffect(() => {
    if (!needed) return;
    loading ??= import("./plugins").then(({ code, math }) => (plugins = { code, math }));
    loading.then(loaded, () => (loading = undefined));
  }, [needed]);
  return plugins;
}

// A live answer is parsed as it streams, its unfinished markdown closed
// for it, and shows a caret until the whole answer replaces it.
function Text() {
  const { live } = useCustom();
  const plugins = usePlugins(useAuiState((s) => s.message.content.map((p) => (p.type === "text" ? p.text : "")).join("")));
  // Only the words still being written carry the caret, not those a call
  // has since followed.
  const end = useAuiState((s) => s.message.parts.at(-1)?.type === "text" && s.message.parts.at(-1) === s.part);
  return (
    <StreamdownTextPrimitive
      plugins={plugins}
      mode={live ? "streaming" : "static"}
      containerClassName={live && end ? "writing" : undefined}
      lineNumbers={false}
      controls={{ code: true, table: false }}
      linkSafety={{ enabled: false }}
    />
  );
}

function AssistantMessage() {
  const { plain } = useCustom();
  return (
    <MessagePrimitive.Root className="rise group relative">
      {plain ? (
        // A draft waiting for approval: framed and named on its frame, as
        // UniiChat frames a report.
        <div className="relative mt-2 rounded-[14px] border-[1.25px] border-edge px-5 py-3.5 whitespace-pre-wrap [overflow-wrap:anywhere]">
          <span className="absolute -top-[0.75em] left-3.5 bg-paper px-1.5 text-xs font-semibold tracking-wide text-mid uppercase">Draft</span>
          <MessagePrimitive.Parts />
        </div>
      ) : (
        <div className="md">
          <MessagePrimitive.GroupedParts groupBy={byRun} indicator="never">
            {({ part }) => {
              switch (part.type) {
                case "group-tools":
                  return <ToolStack indices={part.indices} />;
                case "text":
                  return <Text />;
                case "tool-call":
                  return <Tool {...(part as unknown as ToolCallMessagePartProps)} />;
                case "image":
                  return <MessagePartPrimitive.Image className="max-h-80 max-w-full rounded-lg border border-hair" />;
                case "file":
                  return <Download />;
                default:
                  return null;
              }
            }}
          </MessagePrimitive.GroupedParts>
        </div>
      )}
      <Reaction />
      <div className="mt-1 flex items-center gap-2">
        <Copy />
        <Speak />
        <Redraw />
        <Time />
      </div>
    </MessagePrimitive.Root>
  );
}

// One player for the page, so starting a reply stops the last; `stopping`
// resets the button that was playing. The site streams speech as xAI makes
// it, so the player starts on the first piece; its address is kept by text.
const player = new Audio();
const spoken = new Map<string, Promise<string>>();
let stopping: (() => void) | null = null;

function stop() {
  player.pause();
  stopping?.();
}

const speechId = (text: string, voice: string | null) => `${voice}\n${text}`;

function speech(text: string, voice: string | null) {
  const id = speechId(text, voice);
  let url = spoken.get(id);
  if (!url) {
    url = fetch("/api/speak", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(voice ? { text, voice } : { text }),
    })
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then(({ key }: { key: string }) => `/api/speak/${key}`);
    spoken.set(id, url);
    url.catch(() => spoken.delete(id));
  }
  return url;
}

/** Plays `text` in `voice` alone, calling `done` when it ends, fails or is
 * stopped: the sample in Settings. */
async function play(text: string, voice: string, done: () => void) {
  stop();
  const end = () => {
    if (stopping === end) stopping = null;
    done();
  };
  stopping = end;
  try {
    const src = await speech(text, voice);
    if (stopping !== end) return;
    player.src = src;
    player.playbackRate = voiceSpeed();
    player.onended = end;
    player.onerror = () => {
      spoken.delete(speechId(text, voice));
      end();
    };
    await player.play();
  } catch {
    if (stopping === end) end();
  }
}

/** The model the next turn runs on, asked once `want` turns true, and a
 * way to switch it; the turn under way keeps its own. */
function useModel(want: boolean): [string | null, (m: string) => void] {
  const [model, setModel] = useState<string | null>(null);
  useEffect(() => {
    if (!want) return;
    fetch("/api/model")
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((v: { model: string }) => setModel(v.model), () => {});
  }, [want]);
  const pick = (m: string) => {
    const was = model;
    setModel(m);
    fetch("/api/model", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ model: m }) })
      .then((r) => r.ok || Promise.reject(r.status))
      .catch(() => setModel(was));
  };
  return [model, pick];
}

/** How long the chat remembers, in minutes, asked once `want` turns true,
 * and a way to change it: older messages and files go, oldest first. */
function useForget(want: boolean): [number | null, (m: number) => void] {
  const [minutes, setMinutes] = useState<number | null>(null);
  useEffect(() => {
    if (!want) return;
    fetch("/api/forget")
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((v: { minutes: number }) => setMinutes(v.minutes), () => {});
  }, [want]);
  const pick = (m: number) => {
    const was = minutes;
    setMinutes(m);
    fetch("/api/forget", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ minutes: m }) })
      .then((r) => r.ok || Promise.reject(r.status))
      .catch(() => setMinutes(was));
  };
  return [minutes, pick];
}

/** Minutes as the menu says them: "10 minutes", "3 hours", "1 week". */
function forgetLabel(m: number) {
  const [n, unit] = m % 10080 === 0 ? [m / 10080, "week"] : m % 1440 === 0 ? [m / 1440, "day"] : m % 60 === 0 ? [m / 60, "hour"] : [m, "minute"];
  return `${n} ${unit}${n === 1 ? "" : "s"}`;
}

type Voice = { id: string; name: string };
let voiceList: Promise<Voice[]> | null = null;

/** xAI's voices, asked once `want` turns true; empty until then or if it fails. */
function useVoices(want: boolean) {
  const [voices, setVoices] = useState<Voice[]>([]);
  useEffect(() => {
    if (!want) return;
    voiceList ??= fetch("/api/voices").then((r) => (r.ok ? r.json() : Promise.reject(r.status)));
    voiceList.then(setVoices, () => {
      voiceList = null;
    });
  }, [want]);
  return voices;
}

/** Reads the answer aloud in the assistant's voice; pressed again, stops.
 * Absent where the assistant has no voice. */
function Speak() {
  const { live } = useCustom();
  const voice = useMe()?.voice;
  // The answer: the words after the last call, not those on the way.
  const text = useAuiState((s) => {
    const parts = s.message.content as readonly { type: string; text?: string }[];
    const from = parts.map((p) => p.type).lastIndexOf("tool-call") + 1;
    return parts
      .slice(from)
      .map((p) => (p.type === "text" ? (p.text ?? "") : ""))
      .join("");
  });
  const [state, setState] = useState<"idle" | "loading" | "playing">("idle");
  if (live || !voice || !text.trim()) return null;
  const press = async () => {
    if (state !== "idle") return stop();
    stop();
    const done = () => {
      setState("idle");
      if (stopping === done) stopping = null;
    };
    stopping = done;
    setState("loading");
    const picked = voiceChoice();
    try {
      const src = await speech(text, picked);
      if (stopping !== done) return;
      player.src = src;
      player.playbackRate = voiceSpeed();
      player.onended = done;
      // A reading cut off mid-play is not kept; the next press makes it afresh.
      player.onerror = () => {
        spoken.delete(speechId(text, picked));
        done();
      };
      await player.play();
      // Stopped while it started: the stop has set the button already.
      if (stopping === done) setState("playing");
    } catch {
      // A play cut short by Stop, or by another reading, is no failure.
      if (stopping !== done) return;
      spoken.delete(speechId(text, picked));
      done();
    }
  };
  const label = state === "idle" ? "Read aloud" : "Stop reading";
  return (
    <button
      type="button"
      onClick={press}
      aria-label={label}
      title={label}
      className={`grid size-7 place-items-center rounded-md transition-opacity hover:bg-hover hover:text-ink max-sm:opacity-100 ${state === "idle" ? "text-soft opacity-0 group-hover:opacity-100" : "text-ink opacity-100"}`}
    >
      <svg viewBox="0 0 24 24" className={`size-[15px] ${state === "loading" ? "animate-pulse" : ""}`} fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
        {state === "playing" ? (
          <rect x="6" y="6" width="12" height="12" rx="1.5" />
        ) : (
          <>
            <path d="M11 5 6 9H2v6h4l5 4V5z" />
            <path d="M15.54 8.46a5 5 0 0 1 0 7.07M19.07 4.93a10 10 0 0 1 0 14.14" />
          </>
        )}
      </svg>
    </button>
  );
}

// Circle-arrows beside Copy: redraw this answer's card full screen, or, when
// it has none, resend the question that led to it.
function Redraw() {
  const { live } = useCustom();
  const id = useAuiState((s) => s.message.id);
  const cards = useCards();
  if (live) return null;
  return (
    <button
      type="button"
      onClick={() => cards.redraw(id)}
      aria-label="Redraw"
      title="Redraw"
      className="grid size-7 place-items-center rounded-md text-soft opacity-0 transition-opacity group-hover:opacity-100 hover:bg-hover hover:text-ink max-sm:opacity-100"
    >
      <svg viewBox="0 0 24 24" className="size-[15px]" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
        <path d="M21 2v6h-6M3 22v-6h6" />
        <path d="M3.5 9a9 9 0 0 1 14.85-3.36L21 8M21 15a9 9 0 0 1-14.85 3.36L3 16" />
      </svg>
    </button>
  );
}

/** Copies the answer's words, shown with the time on hover; on a phone, always. */
function Copy() {
  const { live } = useCustom();
  if (live) return null;
  return (
    <ActionBarPrimitive.Root>
      <ActionBarPrimitive.Copy
        aria-label="Copy"
        title="Copy"
        className="group/copy grid size-7 place-items-center rounded-md text-soft opacity-0 transition-opacity group-hover:opacity-100 hover:bg-hover hover:text-ink max-sm:opacity-100"
      >
        <svg viewBox="0 0 24 24" className="size-[15px] group-data-[copied]/copy:hidden" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
          <rect x="9" y="9" width="12" height="12" rx="2" />
          <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
        </svg>
        <svg viewBox="0 0 24 24" className="hidden size-[15px] group-data-[copied]/copy:block" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
          <path d="M20 6 9 17l-5-5" />
        </svg>
      </ActionBarPrimitive.Copy>
    </ActionBarPrimitive.Root>
  );
}

// `mcp__calendar__events` reads as "calendar · events"; Claude's own tools
// (Read, WebSearch) keep their names.
function toolName(name: string) {
  const mcp = /^mcp__(.+?)__(.+)$/.exec(name);
  return mcp ? `${mcp[1]} · ${mcp[2].replaceAll("_", " ")}` : name;
}

// The first short string among the arguments says what a call was about:
// a query, a path, a URL.
function gist(args: Args | string | undefined) {
  if (typeof args === "string") return args.split("\n")[0];
  const first = Object.values(args ?? {}).find((v) => typeof v === "string" && v.trim());
  return typeof first === "string" ? first.split("\n")[0] : "";
}

// Claude Code's tools as a person would name them, each with its glyph.
const TOOLS: Record<string, [string, Glyph]> = {
  Bash: ["Shell", "shell"],
  BashOutput: ["Shell output", "shell"],
  KillShell: ["Stop shell", "shell"],
  Read: ["Read", "file"],
  Edit: ["Edit", "pen"],
  MultiEdit: ["Edit", "pen"],
  NotebookEdit: ["Edit", "pen"],
  Write: ["Write", "pen"],
  Grep: ["Search", "find"],
  Glob: ["Find files", "find"],
  WebFetch: ["Fetch", "web"],
  WebSearch: ["Web search", "web"],
  Agent: ["Agent", "agent"],
  Task: ["Agent", "agent"],
  TodoWrite: ["Todos", "list"],
  ToolSearch: ["Tool search", "find"],
  Skill: ["Skill", "agent"],
  AskUserQuestion: ["Question", "ask"],
};

type Glyph = "shell" | "file" | "pen" | "find" | "web" | "agent" | "list" | "ask" | "plug";

const GLYPHS: Record<Glyph, ReactNode> = {
  shell: <path d="m4 17 6-6-6-6M12 19h8" />,
  file: (
    <>
      <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
      <path d="M14 2v6h6" />
    </>
  ),
  pen: <path d="M12 20h9M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z" />,
  find: (
    <>
      <circle cx="11" cy="11" r="7" />
      <path d="m21 21-4.3-4.3" />
    </>
  ),
  web: (
    <>
      <circle cx="12" cy="12" r="10" />
      <path d="M2 12h20M12 2a15.3 15.3 0 0 1 0 20 15.3 15.3 0 0 1 0-20" />
    </>
  ),
  agent: <path d="m12 3 1.9 5.8L20 10.5l-6.1 1.7L12 18l-1.9-5.8L4 10.5l6.1-1.7z" />,
  list: <path d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01" />,
  ask: (
    <>
      <circle cx="12" cy="12" r="10" />
      <path d="M9.1 9a3 3 0 0 1 5.8 1c0 2-3 3-3 3M12 17h.01" />
    </>
  ),
  plug: <path d="M12 22v-5M9 8V2M15 8V2M18 8v5a6 6 0 0 1-12 0V8z" />,
};

const home = (path: string) => path.replace(/^\/home\/[^/]+/, "~");

// What a call was about, in a few words: the command, the file, the query.
function about(name: string, args: Args | string | undefined): string {
  if (typeof args !== "object" || args === null) return gist(args);
  const a = args as Record<string, unknown>;
  const str = (k: string) => (typeof a[k] === "string" ? (a[k] as string) : "");
  switch (name) {
    case "Bash":
      // A leading `cd somewhere &&` says nothing about what ran.
      return str("command").split("\n")[0].replace(/^cd\s+\S+\s*&&\s*/, "");
    case "Read":
    case "Edit":
    case "MultiEdit":
    case "Write":
      return home(str("file_path"));
    case "NotebookEdit":
      return home(str("notebook_path"));
    case "Grep":
      return str("pattern") + (str("path") ? `  in ${home(str("path"))}` : "");
    case "WebFetch":
      return str("url").replace(/^https?:\/\//, "");
    case "Agent":
    case "Task":
      return str("description");
    case "TodoWrite":
      return Array.isArray(a.todos) ? `${a.todos.length} items` : "";
  }
  return gist(args);
}

// One quiet line per tool the model used, with the words it said on the
// way above it; a spinner until the result is back, and a click opens what
// went in and came out, drawn for the tool it was.
function ToolLine({ toolName: name, args, result, isError }: ToolCallMessagePartProps) {
  const { live } = useCustom();
  return <ToolRow name={name} args={args} result={result} isError={isError} live={live} />;
}

type Row = { name: string; args: Args | string | undefined; result: unknown; isError?: boolean; live?: boolean };

// Calls that come back to back, with no words between them, gather into one
// stack; a card stands on its own.
// An Agent call stands on its own too, as the frame of its report.
const byRun = (part: { type: string; toolName?: string }) =>
  part.type === "tool-call" && !cardKind(part.toolName ?? "") && !isAgent(part.toolName ?? "") ? (["group-tools"] as const) : null;

type Call = { type: string; toolCallId: string; toolName: string; args: Args | string | undefined; result?: unknown; isError?: boolean };

// What a stack did, in words: "Ran 4 commands, read 2 files".
const DID: Record<string, [string, string, string]> = {
  Bash: ["ran", "command", "commands"],
  BashOutput: ["ran", "command", "commands"],
  KillShell: ["ran", "command", "commands"],
  Read: ["read", "file", "files"],
  Edit: ["edited", "file", "files"],
  MultiEdit: ["edited", "file", "files"],
  NotebookEdit: ["edited", "file", "files"],
  Write: ["wrote", "file", "files"],
  Grep: ["ran", "search", "searches"],
  Glob: ["ran", "search", "searches"],
  ToolSearch: ["ran", "search", "searches"],
  WebFetch: ["fetched", "page", "pages"],
  WebSearch: ["searched the web", "time", "times"],
  Agent: ["sent", "agent", "agents"],
  Task: ["sent", "agent", "agents"],
};

function did(calls: Call[]): string {
  const tally = new Map<string, [string, string, string, number]>();
  for (const c of calls) {
    const [verb, one, many] = DID[c.toolName] ?? ["used", "tool", "tools"];
    const key = `${verb} ${many}`;
    const t = tally.get(key) ?? [verb, one, many, 0];
    t[3]++;
    tally.set(key, t);
  }
  const said = [...tally.values()].map(([verb, one, many, n]) => `${verb} ${n} ${n === 1 ? one : many}`).join(", ");
  return said.charAt(0).toUpperCase() + said.slice(1);
}

// A run of calls as one line that opens into their rows, each of which
// opens in turn. While the run goes on, the call under way shows below the
// line with its spinner, and each one done folds up into the line.
function ToolStack({ indices }: { indices: readonly number[] }) {
  const { live } = useCustom();
  const parts = useAuiState((s) => s.message.parts) as readonly Call[];
  const [open, setOpen] = useState(false);
  const calls = indices.map((i) => parts[i]).filter((c) => c?.type === "tool-call");
  const row = (c: Call, running: boolean) => <ToolRow key={c.toolCallId} name={c.toolName} args={c.args} result={c.result} isError={c.isError} live={running} />;
  if (calls.length === 1) return row(calls[0], live);
  const busy = calls.filter((c) => live && c.result === undefined);
  const done = calls.filter((c) => !busy.includes(c));
  const failed = done.filter((c) => c.isError).length;
  const glyphs = [...new Set(done.map((c) => (TOOLS[c.toolName] ?? ["", "plug"])[1]))].slice(0, 3);
  return (
    <div className="not-prose my-2.5 text-[13.5px]">
      {done.length > 0 && (
        <button
          type="button"
          onClick={() => setOpen(!open)}
          aria-expanded={open}
          className="group/stack -mx-1.5 flex w-[calc(100%+0.75rem)] items-center gap-2.5 rounded-lg px-1.5 py-1 text-left hover:bg-hover/50"
        >
          <span className="flex shrink-0">
            {glyphs.map((g, k) => (
              <span key={g} className={`grid size-[22px] place-items-center rounded-full border border-hair bg-lift ${k ? "-ml-2" : ""}`} style={{ zIndex: 3 - k }}>
                <svg viewBox="0 0 24 24" className="size-3 text-mid" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
                  {GLYPHS[g]}
                </svg>
              </span>
            ))}
          </span>
          <span key={done.length} className={`${live ? "absorb " : ""}min-w-0 truncate font-medium text-ink/80`}>
            {did(done)}
          </span>
          {failed > 0 && <span className="shrink-0 text-xs text-accent">{failed} failed</span>}
          <svg viewBox="0 0 24 24" className="ml-auto size-3.5 shrink-0 text-soft transition group-aria-expanded/stack:rotate-90" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
            <path d="m9 18 6-6-6-6" />
          </svg>
        </button>
      )}
      {open && <div className="rise mt-1 ml-[10px] border-l border-hair pl-3.5">{done.map((c) => row(c, false))}</div>}
      {busy.length > 0 && <div className={done.length ? "mt-1 ml-[10px] border-l border-hair pl-3.5" : ""}>{busy.map((c) => <div key={c.toolCallId} className="rise">{row(c, true)}</div>)}</div>}
    </div>
  );
}

function ToolRow({ name, args, result, isError, live }: Row) {
  const done = result !== undefined;
  const [label, glyph] = TOOLS[name] ?? [toolName(name), "plug"];
  return (
    <details className="group/tool not-prose text-[13.5px] [:not(details)+&]:mt-2 [&:has(+:not(details))]:mb-3 [&:last-child]:mb-3">
      <summary className="-mx-1.5 flex cursor-pointer list-none items-center gap-2 rounded-md px-1.5 py-[3px] marker:hidden hover:bg-hover/50 [&::-webkit-details-marker]:hidden">
        {!done && live ? (
          <span className="size-3.5 shrink-0 animate-spin rounded-full border-[1.5px] border-hair border-t-accent" />
        ) : (
          <svg viewBox="0 0 24 24" className={`size-3.5 shrink-0 ${isError ? "text-accent" : "text-soft"}`} fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
            {GLYPHS[glyph]}
          </svg>
        )}
        <span className={`shrink-0 font-medium ${isError ? "text-accent" : "text-ink/80"}`}>{label}</span>
        <span className="min-w-0 truncate font-mono text-[12.5px] text-soft [font-variant-ligatures:none]">{about(name, args)}</span>
        <svg viewBox="0 0 24 24" className="ml-auto size-3.5 shrink-0 text-soft opacity-0 transition group-open/tool:rotate-90 group-hover/tool:opacity-100 group-open/tool:opacity-100" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
          <path d="m9 18 6-6-6-6" />
        </svg>
      </summary>
      <div className="mt-1 mb-2.5 ml-[6px] flex flex-col gap-2 border-l border-hair pl-4">
        <ToolBody name={name} args={args} />
        {done ? <Output text={String(result)} error={isError} /> : <span className="text-xs text-soft">{live ? "Running…" : "No result."}</span>}
      </div>
    </details>
  );
}

// No ligatures: code shows `--` and `===` as typed.
const BLOCK = "max-h-72 overflow-auto rounded-lg border border-hair bg-lift px-3 py-2 font-mono text-[12px] leading-relaxed [font-variant-ligatures:none] whitespace-pre-wrap [overflow-wrap:anywhere]";

// What went in: a command as typed, an edit as a diff, a file as written.
function ToolBody({ name, args }: { name: string; args: Args | string | undefined }) {
  if (typeof args !== "object" || args === null) return args ? <pre className={BLOCK}>{args}</pre> : null;
  const a = args as Record<string, unknown>;
  const str = (k: string) => (typeof a[k] === "string" ? (a[k] as string) : "");
  const path = <div className="font-mono text-[12px] text-mid [overflow-wrap:anywhere]">{home(str("file_path"))}</div>;
  switch (name) {
    case "Bash":
      return (
        <>
          {str("description") && <div className="text-xs text-soft">{str("description")}</div>}
          <pre className={BLOCK}>
            <span className="text-soft select-none">$ </span>
            {str("command")}
          </pre>
        </>
      );
    case "Edit":
      return (
        <>
          {path}
          <Diff old={str("old_string")} next={str("new_string")} />
        </>
      );
    case "MultiEdit":
      return (
        <>
          {path}
          {(Array.isArray(a.edits) ? (a.edits as { old_string?: string; new_string?: string }[]) : []).map((e, k) => (
            <Diff key={k} old={e.old_string ?? ""} next={e.new_string ?? ""} />
          ))}
        </>
      );
    case "Write":
      return (
        <>
          {path}
          <pre className={BLOCK}>{str("content")}</pre>
        </>
      );
    case "Read":
      return a.offset || a.limit ? (
        <div className="font-mono text-[12px] text-mid">
          {home(str("file_path"))}
          {a.offset ? ` from line ${String(a.offset)}` : ""}
          {a.limit ? `, ${String(a.limit)} lines` : ""}
        </div>
      ) : null;
  }
  if (Object.keys(a).length === 0) return null;
  return <pre className={BLOCK}>{JSON.stringify(a, null, 2)}</pre>;
}

// An edit's lines out and in, as a diff reads.
function Diff({ old, next }: { old: string; next: string }) {
  const line = (sign: string, tint: string) => (l: string, k: number) => (
    <div key={sign + k} className={`px-3 ${tint}`}>
      <span className="text-soft select-none">{sign} </span>
      {l}
    </div>
  );
  return (
    <pre className="max-h-72 overflow-auto rounded-lg border border-hair bg-lift py-2 font-mono text-[12px] leading-relaxed whitespace-pre-wrap [overflow-wrap:anywhere]">
      {old && old.split("\n").map(line("−", "bg-red-500/10"))}
      {next && next.split("\n").map(line("+", "bg-emerald-500/12"))}
    </pre>
  );
}

// What came out, cut by the server to what a page can hold.
function Output({ text, error }: { text: string; error?: boolean }) {
  if (!text.trim()) return <span className="text-xs text-soft">No output.</span>;
  return <pre className={`${BLOCK} ${error ? "border-accent/40 text-accent" : "text-mid"}`}>{text}</pre>;
}

// Tools with a card of their own show as a one-line summary in the talk and
// come up as a deck; the rest draw as a ToolLine. Keyed by the tool's own
// name, whichever server carries it.
function Tool(props: ToolCallMessagePartProps) {
  const kind = cardKind(props.toolName);
  if (kind) return <CardInline {...props} kind={kind} />;
  if (isAgent(props.toolName)) return <AgentFrame {...props} />;
  return <ToolLine {...props} />;
}

// A tool's result read into a card's shape, if it parses; undefined while it
// runs, when it failed, or when a long result was cut short on the way here.
function parseCard(kind: Kind, result: unknown): Forecast | Event[] | List[] | Mail[] | Mail | Ledger | Markets | undefined {
  switch (kind) {
    case "weather":
      return parsed<Forecast>(result, isForecast);
    case "calendar":
      return events(result);
    case "list":
      return lists(result);
    case "inbox":
      return parsed<Mail[]>(result, (v) => Array.isArray(v) && v.every(isMail));
    case "mail":
      return parsed<Mail>(result, isMail);
    case "transactions":
      return parsed<Ledger>(result, (v) => typeof v?.spent === "number" && Array.isArray(v.rows) && Array.isArray(v.categories));
    case "markets":
      return parsed<Markets>(result, (v) => typeof v?.value === "number" && Array.isArray(v.accounts) && Array.isArray(v.history));
  }
}

// The cards one tool call drew: none while it runs or if it failed, one per
// list, else one.
function facesOf(t: { id: string; name: string; result?: unknown; error?: boolean }): Face[] {
  const kind = cardKind(t.name);
  if (!kind || t.error) return [];
  const data = parseCard(kind, t.result);
  if (data === undefined) return [];
  if (kind === "list") {
    const ls = data as List[];
    return ls.length ? ls.map((l, n) => ({ key: `${t.id}#${n}`, kind, data: l })) : [{ key: t.id, kind, data: null }];
  }
  return [{ key: t.id, kind, data } as Face];
}

/** An answer's cards, in the order its tools ran. */
const deckOf = (m: Msg) => (m.tools ?? []).flatMap(facesOf);

// In the talk, a card is one quiet line: an icon and a word or two; a tap
// brings its deck back. While the call runs or if its result won't parse it
// stays a ToolLine.
function CardInline(props: ToolCallMessagePartProps & { kind: Kind }) {
  const faces = facesOf({ id: props.toolCallId, name: props.toolName, result: props.result, error: props.isError });
  const cards = useCards();
  if (!faces.length) return <ToolLine {...props} />;
  const data = parseCard(props.kind, props.result)!;
  const [icon, label] = cardSummary(props.kind, data);
  return (
    <button
      type="button"
      onClick={() => cards.open(faces[0].key)}
      className="not-prose group/card my-1 flex max-w-full items-center gap-2 rounded-full border border-frame bg-lift py-1.5 pr-3.5 pl-2.5 text-[13.5px] text-mid last-of-type:mb-3 hover:bg-hover hover:text-ink"
    >
      <span className="text-[15px] leading-none">{icon}</span>
      <span className="truncate font-medium text-ink/80">{label}</span>
      <span className="shrink-0 text-soft transition-opacity group-hover/card:opacity-100 sm:opacity-0">Open</span>
    </button>
  );
}

// The one line a card folds to: an icon and the gist of what it holds.
function cardSummary(kind: Kind, data: unknown): [string, string] {
  switch (kind) {
    case "weather": {
      const w = data as Forecast;
      const [icon, word] = sky(w.now.code, w.now.day);
      return [icon, `${deg(w.now.temp)} · ${word}`];
    }
    case "calendar": {
      const es = data as Event[];
      return ["📅", es.length === 0 ? "Nothing on the calendar" : es.length === 1 ? es[0].summary : `${es.length} on the calendar`];
    }
    case "list": {
      const ls = data as List[];
      return ["🗂️", ls.length === 0 ? "No lists" : ls.map((l) => l.list).join(", ")];
    }
    case "inbox": {
      const ms = data as Mail[];
      const unread = ms.filter((m) => m.unread).length;
      return ["✉️", ms.length === 0 ? "No mail" : unread ? `${unread} unread of ${ms.length}` : `${ms.length} messages`];
    }
    case "mail": {
      const m = data as Mail;
      return ["✉️", m.subject || "(no subject)"];
    }
    case "transactions": {
      const l = data as Ledger;
      return ["💳", `${usd(l.spent)} spent · ${span(l.from, l.to)}`];
    }
    case "markets": {
      const m = data as Markets;
      return ["📈", `${usd(m.value)} invested`];
    }
  }
}

// An answer's cards as a deck: it slides up from behind the composer and
// fills the screen above it, the talk faded behind. Several cards sit side by
// side, a swipe apart, the next peeking in at the edge, as a phone's card
// carousels do; dots, arrows and the arrow keys move between them. A tap
// beside the cards, Escape, or the composer's ▼ puts it away.
// The way a deck leaves: down behind the composer, or flicked off the top.
type Way = "up" | "down";

function Deck({ faces, start, leaving, edge, close }: { faces: Face[]; start: string; leaving: Way | false; edge: number; close: (way?: Way) => void }) {
  const track = useRef<HTMLDivElement>(null);
  const [at, setAt] = useState(() => Math.max(0, faces.findIndex((f) => f.key === start)));
  const many = faces.length > 1;

  const go = (n: number, smooth = true) => {
    const el = track.current;
    const card = el?.children[n] as HTMLElement | undefined;
    if (!el || !card) return;
    el.scrollTo({ left: card.offsetLeft - (el.clientWidth - card.offsetWidth) / 2, behavior: smooth ? "smooth" : "instant" });
  };
  useLayoutEffect(() => go(at, false), []);
  const step = () => {
    const el = track.current;
    if (!el) return;
    const mid = el.scrollLeft + el.clientWidth / 2;
    const n = [...el.children].findIndex((c) => {
      const h = c as HTMLElement;
      return mid >= h.offsetLeft - 8 && mid <= h.offsetLeft + h.offsetWidth + 8;
    });
    if (n >= 0) setAt(n);
  };
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
      // Arrows move between cards unless the person is typing.
      if (document.activeElement instanceof HTMLTextAreaElement && document.activeElement.value) return;
      if (e.key === "ArrowRight" && at < faces.length - 1) go(at + 1);
      if (e.key === "ArrowLeft" && at > 0) go(at - 1);
    };
    addEventListener("keydown", key);
    return () => removeEventListener("keydown", key);
  });

  // Swipe up or down to close, the deck following the finger: let go past a
  // quarter of its height, or with a flick, and it leaves that way; short of
  // that it springs back. A card body that can still scroll that way scrolls
  // first, as phone sheets do. The gesture is decided on the first move,
  // since once the browser starts scrolling it ignores preventDefault.
  const sheet = useRef<HTMLDivElement>(null);
  const shut = useRef(close);
  shut.current = close;
  useEffect(() => {
    const el = sheet.current;
    if (!el) return;
    let mode: "wait" | "drag" | "pass" = "pass";
    let target: EventTarget | null = null;
    let x0 = 0, y0 = 0, dy = 0, last = 0, at = 0, speed = 0;
    // Whether anything under the finger can still scroll the way it pulls.
    const free = (down: boolean) => {
      for (let n = target as HTMLElement | null; n && n !== el; n = n.parentElement)
        if (down ? n.scrollTop > 0 : n.scrollTop + n.clientHeight < n.scrollHeight - 1) return false;
      return true;
    };
    const back = () => {
      el.style.transition = "transform 0.3s cubic-bezier(0.2, 0.8, 0.2, 1)";
      el.style.transform = "";
    };
    const start = (e: TouchEvent) => {
      mode = e.touches.length === 1 ? "wait" : "pass";
      target = e.target;
      x0 = e.touches[0].clientX;
      y0 = last = e.touches[0].clientY;
      at = e.timeStamp;
      dy = speed = 0;
    };
    const move = (e: TouchEvent) => {
      const { clientX: x, clientY: y } = e.touches[0];
      if (mode === "wait") mode = Math.abs(y - y0) > Math.abs(x - x0) && free(y > y0) ? "drag" : "pass";
      if (mode !== "drag") return;
      e.preventDefault();
      if (e.timeStamp > at) speed = (y - last) / (e.timeStamp - at);
      last = y;
      at = e.timeStamp;
      dy = y - y0;
      el.style.transition = "none";
      el.style.transform = `translateY(${dy}px)`;
    };
    const end = () => {
      if (mode !== "drag") return;
      mode = "pass";
      // A pull flicked back the other way at the end springs back.
      const undone = speed * dy < 0 && Math.abs(speed) > 0.3;
      if (!undone && (Math.abs(dy) > el.clientHeight / 4 || Math.abs(speed) > 0.5)) shut.current(dy < 0 ? "up" : "down");
      else back();
    };
    const cancel = () => {
      if (mode === "drag") back();
      mode = "pass";
    };
    el.addEventListener("touchstart", start, { passive: true });
    el.addEventListener("touchmove", move, { passive: false });
    el.addEventListener("touchend", end);
    el.addEventListener("touchcancel", cancel);
    return () => {
      el.removeEventListener("touchstart", start);
      el.removeEventListener("touchmove", move);
      el.removeEventListener("touchend", end);
      el.removeEventListener("touchcancel", cancel);
    };
  }, []);

  const arrow = "absolute top-1/2 z-10 grid size-10 -translate-y-1/2 place-items-center rounded-full border border-frame bg-lift text-mid shadow-lift hover:text-ink disabled:invisible max-sm:hidden";
  return (
    <div className="fixed inset-x-0 top-0 z-10 overflow-hidden" style={{ height: edge || "100dvh" }} onClick={() => close()} aria-label="Cards" role="region">
      <div className={`h-full ${leaving === "up" ? "deck-off" : leaving ? "deck-down" : "deck-up"}`}>
        <div ref={sheet} className="flex h-full flex-col pt-[72px] max-sm:pt-[63px]">
        <div
          ref={track}
          onScroll={step}
          className="deck flex min-h-0 flex-1 snap-x snap-mandatory gap-3 overflow-x-auto overscroll-x-contain px-[max(20px,calc((100%-680px)/2))] max-sm:gap-2.5"
        >
          {faces.map((f, n) => (
            <div
              key={f.key}
              className={`h-full w-[min(680px,100vw-40px)] shrink-0 snap-center snap-always transition-opacity duration-300 ${n === at ? "" : "opacity-45"}`}
              onClick={(e) => e.stopPropagation()}
            >
              <CardFace face={f} />
            </div>
          ))}
        </div>
        <div className={`flex shrink-0 items-center justify-center gap-1.5 ${many ? "h-9" : "h-3"}`}>
          {many &&
            faces.map((f, n) => (
              <button
                key={f.key}
                type="button"
                aria-label={`Card ${n + 1} of ${faces.length}`}
                onClick={(e) => {
                  e.stopPropagation();
                  go(n);
                }}
                className={`h-1.5 rounded-full transition-all ${n === at ? "w-5 bg-ink/70" : "w-1.5 bg-ink/20"}`}
              />
            ))}
        </div>
        </div>
      </div>
      {many && (
        <>
          <button type="button" aria-label="Previous card" disabled={at === 0} onClick={(e) => (e.stopPropagation(), go(at - 1))} className={`${arrow} left-[max(12px,calc((100%-680px)/2-56px))]`}>
            <Chevron left />
          </button>
          <button type="button" aria-label="Next card" disabled={at === faces.length - 1} onClick={(e) => (e.stopPropagation(), go(at + 1))} className={`${arrow} right-[max(12px,calc((100%-680px)/2-56px))]`}>
            <Chevron />
          </button>
        </>
      )}
    </div>
  );
}

const Chevron = ({ left = false }: { left?: boolean }) => (
  <svg viewBox="0 0 24 24" className="size-[18px]" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
    <path d={left ? "m15 18-6-6 6-6" : "m9 18 6-6-6-6"} />
  </svg>
);

function CardFace({ face: f }: { face: Face }) {
  switch (f.kind) {
    case "weather":
      return <WeatherCard w={f.data} />;
    case "calendar":
      return <CalendarCard list={f.data} />;
    case "list":
      return <ListCard list={f.data} />;
    case "inbox":
      return <InboxCard list={f.data} />;
    case "mail":
      return <MailCard m={f.data} />;
    case "transactions":
      return <TransactionsCard l={f.data} />;
    case "markets":
      return <MarketsCard m={f.data} />;
  }
}

// The frame every card shares: a sheet lifted off the page, filling the
// height the deck gives it.
const SHEET = "not-prose flex h-full min-h-0 flex-col overflow-hidden rounded-[16px] border-[1.25px] border-edge bg-lift shadow-lift";

// A list-like card: a titled header with its icon, and a body that fills the
// rest and scrolls on its own.
function BigCard({ icon, title, tag, children, bodyClass }: { icon: string; title: string; tag?: string; children: ReactNode; bodyClass?: string }) {
  return (
    <div className={SHEET}>
      <header className="flex shrink-0 items-center gap-2.5 border-b border-hair px-5 py-3.5">
        <span className="text-[22px] leading-none">{icon}</span>
        <h3 className="min-w-0 flex-1 truncate font-serif text-[20px] text-ink">{title}</h3>
        {tag && <span className="shrink-0 text-[11px] font-semibold tracking-wide text-soft uppercase">{tag}</span>}
      </header>
      <div className={`min-h-0 flex-1 overflow-y-auto ${bodyClass ?? ""}`}>{children}</div>
    </div>
  );
}

// "2026-10-17T07:05", local, as the clock reads it.
function clock(t: string, minutes = true) {
  const [y, m, d] = t.slice(0, 10).split("-").map(Number);
  const at = new Date(y, m - 1, d, Number(t.slice(11, 13)), Number(t.slice(14, 16)));
  return at.toLocaleTimeString(undefined, minutes ? { hour: "numeric", minute: "2-digit" } : { hour: "numeric" });
}

// The weather: now large at the top with how it feels, wind, humidity and
// the sun; the day ahead every three hours; then the week, each day's span
// drawn against the week's, as phone weather apps draw it.
function WeatherCard({ w }: { w: Forecast }) {
  const [icon, word] = sky(w.now.code, w.now.day);
  const today = w.days[0];
  const hours = w.hours.filter((_, n) => n % 3 === 0);
  const lo = Math.min(...w.days.map((d) => d.low));
  const hi = Math.max(...w.days.map((d) => d.high));
  const span = Math.max(1, hi - lo);
  const stat = (label: string, value: string) => (
    <div className="flex flex-col items-center gap-0.5">
      <span className="text-[11px] font-semibold tracking-wide text-soft uppercase">{label}</span>
      <span className="text-[15px] text-ink tabular-nums">{value}</span>
    </div>
  );
  return (
    <div className={SHEET}>
      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className="flex items-center justify-center gap-4 px-5 pt-6 pb-2">
          <span className="text-[64px] leading-none max-sm:text-[54px]">{icon}</span>
          <span className="text-[84px] leading-[0.85] text-ink tabular-nums max-sm:text-[70px]">{deg(w.now.temp)}</span>
        </div>
        <p className="text-center text-[17px] text-mid">
          {word} · feels {deg(w.now.feels)}
        </p>
        {today && (
          <p className="mt-1 text-center text-[15px] text-mid">
            High <span className="text-ink tabular-nums">{deg(today.high)}</span> · Low <span className="text-ink tabular-nums">{deg(today.low)}</span>
          </p>
        )}
        <div className="mx-5 mt-5 grid grid-cols-4 gap-2 border-y border-hair py-3 max-sm:mx-4">
          {stat("Wind", `${Math.round(w.now.wind)} mph`)}
          {stat("Humidity", `${w.now.humidity}%`)}
          {today && stat("Sunrise", clock(today.sunrise))}
          {today && stat("Sunset", clock(today.sunset))}
        </div>
        {hours.length > 0 && (
          <ol className="mx-5 grid border-b border-hair py-3 max-sm:mx-4" style={{ gridTemplateColumns: `repeat(${hours.length}, minmax(0, 1fr))` }}>
            {hours.map((h, n) => (
              <li key={h.time} className="flex flex-col items-center gap-1">
                <span className="text-[12px] whitespace-nowrap text-soft">{n === 0 ? "Now" : clock(h.time, false)}</span>
                <span className="text-[22px] leading-none" title={sky(h.code, h.day)[1]}>
                  {sky(h.code, h.day)[0]}
                </span>
                <span className="text-[15px] text-ink tabular-nums">{deg(h.temp)}</span>
                <span className="h-4 text-[11.5px] text-accent tabular-nums">{h.rain ? `${h.rain}%` : ""}</span>
              </li>
            ))}
          </ol>
        )}
        <ul className="flex flex-col px-5 py-1.5 max-sm:px-4">
          {w.days.map((d, n) => {
            const [dayIcon, dayWord] = sky(d.code);
            const [y, m, day] = d.date.split("-").map(Number);
            const name = n === 0 ? "Today" : new Date(y, m - 1, day).toLocaleDateString(undefined, { weekday: "short" });
            return (
              <li key={d.date} className="flex items-center gap-3 border-hair py-2.5 not-first:border-t max-sm:gap-2">
                <span className="w-14 shrink-0 text-[15px] font-medium text-ink">{name}</span>
                <span className="w-8 shrink-0 text-center text-[22px] leading-none" title={dayWord}>
                  {dayIcon}
                </span>
                <span className="w-9 shrink-0 text-[12.5px] text-accent tabular-nums">{d.rain ? `${d.rain}%` : ""}</span>
                <span className="w-9 shrink-0 text-right text-[15px] text-soft tabular-nums">{deg(d.low)}</span>
                <span className="relative h-1.5 min-w-8 flex-1 rounded-full bg-hair">
                  <span
                    className="absolute inset-y-0 rounded-full bg-accent/70"
                    style={{ left: `${((d.low - lo) / span) * 100}%`, right: `${((hi - d.high) / span) * 100}%` }}
                  />
                </span>
                <span className="w-9 shrink-0 text-right text-[15px] text-ink tabular-nums">{deg(d.high)}</span>
              </li>
            );
          })}
        </ul>
      </div>
    </div>
  );
}

// A tool's JSON result, if it parses and has the expected shape.
function parsed<T>(result: unknown, ok: (v: any) => boolean): T | undefined {
  try {
    const v = typeof result === "string" ? JSON.parse(result) : result;
    return ok(v) ? v : undefined;
  } catch {
    // A long answer is cut short on the way here and no longer parses.
    return undefined;
  }
}

// One event as the calendar tool reports it; times are "YYYY-MM-DD HH:MM",
// or just the date when it lasts all day.
type Event = { uid: string; calendar: string; start: string; end: string; summary: string; location: string | null; repeats: boolean };

function events(result: unknown) {
  return parsed<Event[]>(result, (v) => Array.isArray(v) && v.every((e) => typeof e?.start === "string"));
}

function dayLabel(day: string) {
  const [y, m, d] = day.split("-").map(Number);
  const date = new Date(y, m - 1, d);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const ahead = Math.round((date.getTime() - today.getTime()) / 86_400_000);
  const name = date.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
  return ahead === 0 ? `Today · ${name}` : ahead === 1 ? `Tomorrow · ${name}` : name;
}

// The calendar as a card, by day.
function CalendarCard({ list }: { list: Event[] }) {
  const days = new Map<string, Event[]>();
  for (const e of list) days.set(e.start.slice(0, 10), [...(days.get(e.start.slice(0, 10)) ?? []), e]);
  return (
    <BigCard icon="📅" title="Calendar">
      {days.size === 0 && <p className="px-5 py-4 text-[15px] text-mid">Nothing on the calendar.</p>}
      {[...days].map(([day, es]) => (
        <section key={day} className="border-hair not-first:border-t">
          <h4 className="sticky top-0 z-10 bg-block px-5 py-2 text-xs font-semibold tracking-wide text-mid uppercase">{dayLabel(day)}</h4>
          <ul className="flex flex-col py-1.5 text-[15px]">
            {es.map((e) => (
              <li key={e.uid + e.start} className="flex gap-4 px-5 py-2">
                <span className="w-24 shrink-0 text-mid tabular-nums max-sm:w-20">
                  {e.start.length > 10 ? `${e.start.slice(11)}–${e.end.startsWith(day) ? e.end.slice(11) : "…"}` : "All day"}
                </span>
                <span className="min-w-0">
                  <span className="text-ink">{e.summary}</span>
                  {e.repeats && <span className="ml-1.5 text-soft" title="Repeats">↻</span>}
                  {e.location && <span className="block truncate text-[13.5px] text-soft">{e.location}</span>}
                </span>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </BigCard>
  );
}

// A list as the list tools report it: one object, or an array from `lists`.
type List = { list: string; shared: boolean; items: string[]; missing?: string[] };

function lists(result: unknown) {
  const v = parsed<List | List[]>(result, (v) => (Array.isArray(v) ? v : [v]).every((l) => typeof l?.list === "string" && Array.isArray(l.items)));
  return v && (Array.isArray(v) ? v : [v]);
}

// A list as an index card: a ruled line under every item. A deck holds one
// card per list; `null` is the answer that there are none.
function ListCard({ list: l }: { list: List | null }) {
  if (!l)
    return (
      <BigCard icon="🗂️" title="Lists">
        <p className="px-5 py-4 font-serif text-[15px] text-mid italic">No lists.</p>
      </BigCard>
    );
  return (
    <BigCard icon="🗂️" title={l.list} tag={l.shared ? "shared" : undefined} bodyClass="px-5 py-2">
      {l.items.length === 0 ? (
        <p className="py-1.5 font-serif text-[15px] text-soft italic">Emptied and put away.</p>
      ) : (
        <ul className="ruled">
          {l.items.map((item) => (
            <li key={item} className="font-serif text-[16px] text-ink [overflow-wrap:anywhere]">
              {item}
            </li>
          ))}
        </ul>
      )}
      {l.missing && <p className="pt-1 pb-2 text-[12.5px] text-soft">Wasn't on it: {l.missing.join(", ")}</p>}
    </BigCard>
  );
}

// Mail as the mail tools report it: headers from a search, and the text,
// recipients and attachment names too when one message is read.
type Mail = { uid: number; date: string; from: string; subject: string; unread: boolean; to?: string; text?: string; attachments?: string[] };


const isMail = (m: any) => typeof m?.uid === "number" && typeof m.subject === "string";

// "Gab Cleary <gab@x.com>" reads as Gab Cleary; a bare address stays whole.
const sender = (from: string) => /^\s*"?([^"<]+?)"?\s*<[^>]+>/.exec(from)?.[1] ?? from;

// The time today, the weekday this week, else the date.
function when(date: string) {
  const d = new Date(date);
  if (isNaN(d.getTime())) return "";
  const days = (Date.now() - d.getTime()) / 86_400_000;
  if (d.toDateString() === new Date().toDateString()) return d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  if (days < 6) return d.toLocaleDateString(undefined, { weekday: "short" });
  return d.toLocaleDateString(undefined, { day: "numeric", month: "short" });
}

// A search as an inbox: newest first, unread in ink with a red mark.
function InboxCard({ list }: { list: Mail[] }) {
  const unread = list.filter((m) => m.unread).length;
  return (
    <BigCard icon="✉️" title={unread ? `Inbox · ${unread} unread` : "Inbox"}>
      {list.length === 0 && <p className="px-5 py-4 text-[15px] text-mid">No mail found.</p>}
      <ul className="divide-y divide-hair text-[15px]">
        {list.map((m) => (
          <li key={m.uid} className="flex gap-3 px-5 py-3">
            <span className={`mt-[0.55em] size-1.5 shrink-0 rounded-full ${m.unread ? "bg-accent" : ""}`} />
            <span className="min-w-0 flex-1">
              <span className="flex items-baseline gap-3">
                <span className={`min-w-0 flex-1 truncate ${m.unread ? "font-semibold text-ink" : "text-mid"}`}>{sender(m.from)}</span>
                <span className="shrink-0 text-[12.5px] text-soft tabular-nums">{when(m.date)}</span>
              </span>
              <span className={`block truncate font-serif text-[16px] ${m.unread ? "text-ink" : "text-mid"}`}>{m.subject || "(no subject)"}</span>
            </span>
          </li>
        ))}
      </ul>
    </BigCard>
  );
}

// One message read whole, as a letter.
function MailCard({ m }: { m: Mail }) {
  const head = "w-14 shrink-0 text-[11px] font-semibold tracking-wider text-soft uppercase";
  return (
    <BigCard icon="✉️" title={m.subject || "(no subject)"}>
      <dl className="flex flex-col gap-1 border-b border-dashed border-frame px-5 py-3.5 text-[14.5px]">
        <div className="flex items-baseline">
          <dt className={head}>From</dt>
          <dd className="min-w-0 flex-1 truncate" title={m.from}>{sender(m.from)}</dd>
          <dd className="shrink-0 pl-3 text-[13px] text-soft">{when(m.date)}</dd>
        </div>
        {m.to && (
          <div className="flex items-baseline">
            <dt className={head}>To</dt>
            <dd className="min-w-0 flex-1 truncate" title={m.to}>{m.to}</dd>
          </div>
        )}
      </dl>
      {m.text && (
        <div className="px-5 py-4">
          <p className="font-serif text-[16px] leading-relaxed whitespace-pre-wrap text-ink [overflow-wrap:anywhere]">{m.text.replace(/\n\[cut\]$/, "")}</p>
        </div>
      )}
      {!!m.attachments?.length && (
        <ul className="flex flex-wrap gap-1.5 px-5 pb-4">
          {m.attachments.map((a, i) => (
            <li key={i} className="max-w-full truncate rounded-full border border-hair bg-block px-2.5 py-0.5 text-[12.5px] text-mid">
              📎 {a}
            </li>
          ))}
        </ul>
      )}
    </BigCard>
  );
}

// Weather as the weather tool reports it: now, the coming hours, the week.
// Times are local, "YYYY-MM-DDTHH:MM".
type Forecast = {
  now: { temp: number; feels: number; code: number; day: boolean; wind: number; humidity: number };
  hours: { time: string; temp: number; code: number; day: boolean; rain: number | null }[];
  days: { date: string; code: number; high: number; low: number; rain: number | null; sunrise: string; sunset: string }[];
};

const isForecast = (v: any) => typeof v?.now?.temp === "number" && Array.isArray(v.hours) && Array.isArray(v.days);
const deg = (t: number) => `${Math.round(t)}°`;

// WMO weather codes, as Open-Meteo reports them, to an emoji and a word.
function sky(code: number, day = true): [string, string] {
  if (code === 0) return [day ? "☀️" : "🌙", "Clear"];
  if (code <= 2) return [day ? "⛅" : "☁️", "Partly cloudy"];
  if (code === 3) return ["☁️", "Overcast"];
  if (code <= 48) return ["🌫️", "Fog"];
  if (code <= 67 || (code >= 80 && code <= 82)) return ["🌧️", "Rain"];
  if (code <= 77 || code === 85 || code === 86) return ["🌨️", "Snow"];
  return ["⛈️", "Storm"];
}

// What the yeoman notes beside the talk: quiet, in the serif. Alerts land
// here with whole log lines, so it breaks anywhere too.
function Note() {
  const text = useAuiState((s) => s.message.content.map((p) => (p.type === "text" ? p.text : "")).join(""));
  const fed = /^\((routine|task|alert|message|seat)\) /.exec(text);
  const style = "font-serif text-[14.5px] leading-relaxed whitespace-pre-wrap text-mid italic [overflow-wrap:anywhere]";
  if (!fed) {
    return (
      <MessagePrimitive.Root className={`rise ${style}`}>
        <MessagePrimitive.Parts />
      </MessagePrimitive.Root>
    );
  }
  // What the house fed the yeoman (routine prompts, alert logs, passed-on
  // messages) is long and not meant for reading; its answer follows as
  // talk, so this folds to one line that opens on a click.
  const body = text.slice(fed[0].length);
  const label = { routine: "Routine", task: "Task", alert: "Alert", message: "Message", seat: "From Bridge" }[fed[1]];
  return (
    <MessagePrimitive.Root className={`rise ${style}`}>
      <details className="group">
        <summary className="cursor-pointer list-none truncate marker:hidden [&::-webkit-details-marker]:hidden">
          <span className="not-italic">{label}</span>
          <span className="group-open:hidden"> · {body.split("\n")[0]}</span>
        </summary>
        <div className="mt-1">{body}</div>
      </details>
    </MessagePrimitive.Root>
  );
}

// Whether the window is wide enough for the screen to sit beside the talk.
function useWide() {
  const query = "(min-width: 1024px)";
  const [wide, setWide] = useState(() => matchMedia(query).matches);
  useEffect(() => {
    const m = matchMedia(query);
    const change = () => setWide(m.matches);
    m.addEventListener("change", change);
    return () => m.removeEventListener("change", change);
  }, []);
  return wide;
}

// The computer's screen, watched while its browser is open: noVNC's own
// page, view only, so a stray tap does not fight the model. Take over opens
// it with the keyboard, for a captcha or a sign-in only the person can do.
// It opens by itself when the work turns to the computer and stays until
// the browser closes; Close closes it, though not while the yeoman is at
// it. Hidden, it stays a line to bring it back. As a pane it fills the
// right of a wide window, top to bottom.
function Screen({ url, shape = 16 / 9, on, driving, close, pane }: { url: string; shape?: number; on: boolean; driving: boolean; close: () => Promise<void>; pane?: boolean }) {
  const [hidden, setHidden] = useState(false);
  useEffect(() => {
    if (on) setHidden(false);
  }, [on]);
  if (!on) return null;
  const sep = url.includes("?") ? "&" : "?";
  const bar = "flex h-8 items-center gap-1 px-1 text-[13px] text-mid";
  const link = "rounded-full px-3 py-1 hover:bg-hover hover:text-ink";
  return (
    <section
      className={`rise overflow-hidden rounded-[14px] border-[1.25px] border-edge bg-lift shadow-lift ${pane ? "my-4 mr-4 flex w-[58%] shrink-0 flex-col" : "mb-3"}`}
      aria-label="The computer's screen"
    >
      <div className={`${bar} justify-between`}>
        <span className="flex min-w-0 items-center gap-2 truncate pl-2.5 font-medium text-ink/80">
          <span className="size-2 animate-pulse rounded-full bg-accent" /> On the computer
        </span>
        <span className="flex">
          <a href={url} target="_blank" rel="noreferrer" className={link}>
            Take over
          </a>
          {!pane && (
            <button type="button" onClick={() => setHidden(!hidden)} className={link}>
              {hidden ? "Show" : "Hide"}
            </button>
          )}
          {!driving && (
            <button type="button" onClick={() => void close()} className={link}>
              Close
            </button>
          )}
        </span>
      </div>
      {!hidden && (
        <iframe
          src={`${url}${sep}view_only=1`}
          title="The computer's screen"
          className={`block w-full border-0 border-t border-hair bg-ink ${pane ? "min-h-0 flex-1" : ""}`}
          // Inline, the frame spans the card in the screen's own shape, so
          // on a phone noVNC scales it with no bands; only a window too
          // short for that caps it, and noVNC letterboxes.
          style={pane ? undefined : { aspectRatio: shape, maxHeight: "55vh" }}
        />
      )}
    </section>
  );
}

// A subagent's name: the Agent call's description, or a yeoman agent's own.
const nameOf = (t: Task) => t.title || t.name;

// Each subagent at work is a dot at the bottom left, above the composer,
// as in Victor's chat; a tap opens its page.
function AgentDots({ tasks, open }: { tasks: Task[]; open: (name: string) => void }) {
  const on = tasks.filter((t) => !t.done);
  if (!on.length) return null;
  return (
    <div className="mb-2 flex flex-wrap items-center gap-1.5 px-1">
      {on.map((t) => (
        <button
          key={t.name}
          type="button"
          onClick={() => open(t.name)}
          title={`${nameOf(t)}: working`}
          className="rise flex h-7 max-w-[15rem] items-center gap-2 rounded-full border border-hair bg-lift px-2.5 text-[12.5px] text-mid shadow-lift hover:text-ink max-sm:max-w-[10rem]"
        >
          <span className="relative grid size-2.5 shrink-0 place-items-center">
            <span className="absolute size-2.5 animate-ping rounded-full bg-accent/40 motion-reduce:hidden" />
            <span className="size-2 rounded-full bg-accent" />
          </span>
          <span className="truncate">{nameOf(t)}</span>
        </button>
      ))}
    </div>
  );
}

// The Agent call in the talk: a frame named on its edge, holding the
// report; its work stays on the agent's own page.
function AgentFrame({ toolCallId, args, result, isError, artifact }: ToolCallMessagePartProps) {
  const { tasks, open } = useContext(AgentCtx);
  const { live } = useCustom();
  const { description } = (args ?? {}) as { description?: string };
  const { agent, report } = (artifact ?? {}) as { agent?: string; report?: string };
  const task = tasks.find((t) => t.name === toolCallId);
  const out = typeof result === "string" ? result : result === undefined ? undefined : JSON.stringify(result);
  const launched = !!out?.startsWith("Async agent launched");
  // Run in the foreground, the call's result is the report itself.
  const said = report ?? (out !== undefined && !launched && !isError && !POINTER.test(out) ? out : undefined);
  const working = task ? !task.done : live && said === undefined && !isError;
  const name = description || "Agent";
  return (
    <div className="relative my-5 rounded-[14px] border-[1.25px] border-edge">
      <span className="absolute -top-[0.75em] left-3.5 flex items-center gap-1.5 bg-paper px-1.5 text-xs font-semibold tracking-wide text-mid uppercase">
        {working && <span className="size-1.5 animate-pulse rounded-full bg-accent" />}
        {name}
      </span>
      <div className="px-5 pt-3.5 pb-1 text-[14.5px]">
        {said ? (
          <Streamdown mode="static" lineNumbers={false} controls={{ code: true, table: false }} linkSafety={{ enabled: false }}>
            {said}
          </Streamdown>
        ) : isError ? (
          <p className="text-accent [overflow-wrap:anywhere]">{out}</p>
        ) : (
          <p className="flex items-center gap-2 py-1 text-mid">
            {working && <span className="size-3 shrink-0 animate-spin rounded-full border-[1.5px] border-hair border-t-accent" />}
            {working ? "Working" : "No report came back."}
          </p>
        )}
      </div>
      <div className="flex justify-end px-3 pb-2">
        <button type="button" onClick={() => open(toolCallId, agent, name)} className="rounded-full px-2.5 py-1 text-[12.5px] text-soft hover:bg-hover hover:text-ink">
          Its work ›
        </button>
      </div>
    </div>
  );
}

// A subagent's own page, over the talk: its task, then its words and calls
// in order, live while it works. One the page no longer holds, after a
// reload, comes from hippo, which keeps every subagent's chat. Only the
// yeoman's own agents can be stopped.
function AgentPage({ call, agent, title, tasks, stop, close }: { call: string; agent?: string; title?: string; tasks: Task[]; stop: (name: string) => Promise<void>; close: () => void }) {
  const task = tasks.find((t) => t.name === call);
  const [kept, setKept] = useState<Pick<Task, "text" | "tools" | "words"> | null>();
  const fetching = !!agent && !task?.tools.length;
  useEffect(() => {
    if (!fetching) return;
    let on = true;
    fetch(`/api/agent/${encodeURIComponent(agent!)}/chat`)
      .then((r) => (r.ok ? r.json() : null))
      .then((j: { text: string } | null) => on && setKept(j ? fromAgentChat(j.text) : null))
      .catch(() => on && setKept(null));
    return () => {
      on = false;
    };
  }, [fetching, agent]);
  useEffect(() => {
    const key = (e: KeyboardEvent) => e.key === "Escape" && close();
    addEventListener("keydown", key);
    return () => removeEventListener("keydown", key);
  }, [close]);
  const work = task?.tools.length || !kept ? task : { ...task, ...kept };
  const live = !!task && !task.done;
  const md = (text: string) => (
    <Streamdown mode="static" lineNumbers={false} controls={{ code: true, table: false }} linkSafety={{ enabled: false }}>
      {text}
    </Streamdown>
  );
  return (
    <div className="rise fixed inset-0 z-30 flex flex-col bg-paper" role="dialog" aria-label={title ?? (task ? nameOf(task) : "Agent")}>
      <header className="flex h-[57px] shrink-0 items-center gap-1.5 border-b border-hair px-[max(12px,env(safe-area-inset-left))] max-sm:h-[51px]">
        <button type="button" onClick={close} aria-label="Back to the talk" title="Back" className="grid size-9 shrink-0 place-items-center rounded-full text-mid hover:bg-hover hover:text-ink">
          <svg viewBox="0 0 24 24" className="size-[18px]" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
            <path d="m15 18-6-6 6-6" />
          </svg>
        </button>
        <h2 className="min-w-0 flex-1 truncate text-[15px] font-semibold">
          {title ?? (task ? nameOf(task) : "Agent")}
          <span className="font-normal text-mid"> · {live ? "working" : "done"}</span>
        </h2>
        {live && !task.title && (
          <button type="button" onClick={() => void stop(task.name)} disabled={task.stopping} className="h-9 shrink-0 rounded-full px-4 text-[14px] text-mid hover:bg-hover hover:text-ink disabled:opacity-50">
            {task.stopping ? "Stopping" : "Stop"}
          </button>
        )}
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto">
        <main style={{ zoom: "var(--talk, 1)" }} className="mx-auto flex w-[min(740px,100%-40px)] flex-col gap-3 pt-6 pb-16 max-sm:w-[calc(100%-28px)]">
          {work?.text && <p className="self-end rounded-[18px] bg-hover px-4 py-2.5 text-[14.5px] whitespace-pre-wrap [overflow-wrap:anywhere] max-w-[85%]">{work.text}</p>}
          <div className="md">
            {work?.tools.map((t) => (
              <div key={t.id}>
                {t.before && md(t.before)}
                <ToolRow name={t.name} args={t.input as Args} result={t.result} isError={t.error} live={live} />
              </div>
            ))}
            {work?.words && md(work.words)}
          </div>
          {live && <Dots />}
          {!work?.text && !work?.tools.length && (fetching && kept === undefined ? <Dots /> : !live && <p className="text-mid">Its work wasn't kept.</p>)}
        </main>
      </div>
    </div>
  );
}

// Acts waiting for the person's word sit above the composer, where the
// next thing is done, until a verdict here or in Matrix settles them. A
// mail draft reads as a letter on a sheet of its own.
// What the seat asks mid-turn, where Claude Code would ask in the terminal:
// AskUserQuestion's questions to pick from, or whether a tool may run.
function AskCard({ ask: a, reply }: { ask: Ask; reply: Reply }) {
  const questions = a.tool === "AskUserQuestion" ? ((a.input.questions as Question[] | undefined) ?? []) : undefined;
  const [picked, setPicked] = useState<Record<string, string[]>>({});
  const [other, setOther] = useState<Record<string, string>>({});
  const answer = (q: Question) => (other[q.question]?.trim() ? [...(picked[q.question] ?? []), other[q.question].trim()] : (picked[q.question] ?? [])).join(", ");
  const pick = (q: Question, label: string) =>
    setPicked((p) => {
      const was = p[q.question] ?? [];
      const now = q.multiSelect ? (was.includes(label) ? was.filter((l) => l !== label) : [...was, label]) : [label];
      return { ...p, [q.question]: now };
    });
  const ready = !questions || questions.every((q) => answer(q));
  const go = () => reply(a.id, true, questions && Object.fromEntries(questions.map((q) => [q.question, answer(q)])));
  return (
    <article className="rise relative mb-3.5 shrink-0 rounded-[14px] border-[1.25px] border-edge bg-lift shadow-lift" aria-label={questions ? "Questions" : `May ${a.tool} run?`}>
      <span className="absolute -top-[0.75em] left-3.5 rounded bg-lift px-1.5 text-xs font-semibold tracking-wide text-accent uppercase">Waiting on you</span>
      {questions ? (
        <div className="flex flex-col gap-4 px-5 pt-4 pb-2">
          {questions.map((q) => (
            <fieldset key={q.question} className="flex flex-col gap-2">
              {q.header && <legend className="text-[11px] font-semibold tracking-wider text-soft uppercase">{q.header}</legend>}
              <p className="text-[15px] font-medium">{q.question}</p>
              <div className="flex flex-wrap gap-2">
                {q.options.map((o) => {
                  const on = picked[q.question]?.includes(o.label);
                  return (
                    <button
                      key={o.label}
                      title={o.description}
                      onClick={() => pick(q, o.label)}
                      className={`rounded-xl border px-3 py-1.5 text-left text-[14px] ${on ? "border-ink bg-ink text-paper" : "border-frame hover:bg-hover"}`}
                    >
                      {o.label}
                      {o.description && <span className={`block text-[12px] ${on ? "opacity-75" : "text-mid"}`}>{o.description}</span>}
                    </button>
                  );
                })}
              </div>
              <input
                value={other[q.question] ?? ""}
                onChange={(e) => setOther((o) => ({ ...o, [q.question]: e.target.value }))}
                placeholder="Or say something else"
                className="rounded-xl border border-frame bg-transparent px-3 py-1.5 text-[14px] outline-none focus:border-soft"
              />
            </fieldset>
          ))}
        </div>
      ) : (
        <div className="flex flex-col gap-1.5 px-5 pt-4 pb-2">
          <p className="text-[15px] font-medium">
            May I use <code className="text-[14px]">{a.tool}</code>?
          </p>
          {a.about && <p className="text-[14px] text-mid">{a.about}</p>}
          <pre className="max-h-48 overflow-auto rounded-lg bg-hover px-3 py-2 text-[12.5px] whitespace-pre-wrap [overflow-wrap:anywhere]">{shown(a.input)}</pre>
        </div>
      )}
      <footer className="flex items-center justify-end gap-2 px-3.5 pb-3">
        {a.busy ? (
          <span className="flex h-9 items-center gap-2 px-3 text-[13.5px] text-mid">
            <span className="size-3 animate-spin rounded-full border-[1.5px] border-hair border-t-accent" /> Working
          </span>
        ) : (
          <>
            <button onClick={() => reply(a.id, false)} className="h-9 rounded-full px-4 text-[14px] text-mid hover:bg-hover hover:text-ink">
              {questions ? "Skip" : "Deny"}
            </button>
            <button disabled={!ready} onClick={go} className="h-9 rounded-full bg-ink px-5 text-[14px] font-medium text-paper hover:opacity-85 disabled:opacity-40">
              {questions ? "Answer" : "Allow"}
            </button>
          </>
        )}
      </footer>
    </article>
  );
}

// A tool's input as the person reads it: the command or the file when it
// has one, else the whole input.
function shown(input: Record<string, unknown>): string {
  for (const k of ["command", "file_path", "url", "pattern"]) if (typeof input[k] === "string") return input[k] as string;
  return JSON.stringify(input, null, 2);
}

function Tray({ cards, decide }: { cards: Card[]; decide: Decide }) {
  if (cards.length === 0) return null;
  return (
    <div className="mb-3 flex flex-col gap-3.5">
      {cards.map((c) => (
        <Letter key={c.id} card={c} decide={decide} />
      ))}
    </div>
  );
}

function Letter({ card: c, decide }: { card: Card; decide: Decide }) {
  const { to, account, subject, body } = c.act;
  const [open, setOpen] = useState(false);
  const head = "w-16 shrink-0 text-[11px] font-semibold tracking-wider text-soft uppercase";
  return (
    <article className="rise relative shrink-0 rounded-[14px] border-[1.25px] border-edge bg-lift shadow-lift" aria-label={`Draft to ${to}`}>
      <span className="absolute -top-[0.75em] left-3.5 rounded bg-lift px-1.5 text-xs font-semibold tracking-wide text-accent uppercase">
        Waiting on you
      </span>
      <dl className="flex flex-col gap-0.5 border-b border-dashed border-frame px-5 pt-4 pb-2.5 text-[14px]">
        <div className="flex items-baseline">
          <dt className={head}>To</dt>
          <dd className="truncate">{to}</dd>
        </div>
        {account && (
          <div className="flex items-baseline">
            <dt className={head}>From</dt>
            <dd className="truncate text-mid">{account}</dd>
          </div>
        )}
        <div className="flex items-baseline">
          <dt className={head}>Subject</dt>
          <dd className="font-medium [overflow-wrap:anywhere]">{subject}</dd>
        </div>
      </dl>
      {/* Folded to a few lines so the talk stays in view; a click reads it whole. */}
      <div onClick={() => setOpen(!open)} title={open ? undefined : "Read it all"} className="cursor-pointer px-5 py-3">
        <p className={`font-serif text-[15.5px] leading-relaxed whitespace-pre-wrap [overflow-wrap:anywhere] ${open ? "max-h-72 overflow-y-auto" : "line-clamp-3"}`}>
          {body}
        </p>
      </div>
      {c.error && <p className="px-5 pb-1 text-[13px] text-accent">{c.error}</p>}
      <footer className="flex items-center justify-end gap-2 px-3.5 pb-3">
        {c.busy ? (
          <span className="flex h-9 items-center gap-2 px-3 text-[13.5px] text-mid">
            <span className="size-3 animate-spin rounded-full border-[1.5px] border-hair border-t-accent" /> Working
          </span>
        ) : (
          <>
            <button onClick={() => decide(c.id, false)} className="h-9 rounded-full px-4 text-[14px] text-mid hover:bg-hover hover:text-ink">
              Drop
            </button>
            <button onClick={() => decide(c.id, true)} className="h-9 rounded-full bg-ink px-5 text-[14px] font-medium text-paper hover:opacity-85">
              Send
            </button>
          </>
        )}
      </footer>
    </article>
  );
}

// Money as the money page writes it: dollars and cents, the sign apart.
const dollars = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
const usd = (n: number) => dollars.format(Math.abs(n) < 0.005 ? 0 : n);
const signed = (n: number) => (n > 0.005 ? "+" : n < -0.005 ? "−" : "") + usd(Math.abs(n));

// "2026-10-01" read as a local day.
function localDay(d: string) {
  const [y, m, day] = d.split("-").map(Number);
  return new Date(y, m - 1, day);
}
const shortDay = (d: string) => localDay(d).toLocaleDateString(undefined, { month: "short", day: "numeric" });
const span = (from: string, to: string) => (from === to ? shortDay(from) : `${shortDay(from)} – ${shortDay(to)}`);

// What the transactions tool gives: totals, spending by category, and the
// newest rows that fit, as [date, merchant, amount, category, kind, pending,
// account mask]. Amounts are Plaid's: positive is money out.
type Charge = [string, string | null, number, string, string, boolean, string];
type Ledger = {
  from: string;
  to: string;
  category: string | null;
  merchant: string | null;
  spent: number;
  income: number;
  count: number;
  shown: number;
  categories: { category: string; amount: number; count: number }[];
  accounts: Record<string, string | null>;
  rows: Charge[];
};

// Transactions over the days asked: what went out and came in, where the
// spending went, then each transaction by day. Spending is red, money in is
// ink, and moves between our own accounts stay quiet.
function TransactionsCard({ l }: { l: Ledger }) {
  const days = new Map<string, Charge[]>();
  for (const r of l.rows) days.set(r[0], [...(days.get(r[0]) ?? []), r]);
  const top = l.categories.filter((c) => c.amount > 0);
  const most = Math.max(1, ...top.map((c) => c.amount));
  const tile = (label: string, value: string, tone: string) => (
    <div className="flex min-w-0 flex-col gap-0.5">
      <span className="text-[11px] font-semibold tracking-wide text-soft uppercase">{label}</span>
      <span className={`truncate text-[22px] tabular-nums ${tone}`}>{value}</span>
    </div>
  );
  const filter = [l.category, l.merchant].filter(Boolean).join(" · ");
  return (
    <BigCard icon="💳" title={filter || "Transactions"} tag={span(l.from, l.to)}>
      <div className="grid grid-cols-3 gap-3 border-b border-hair px-5 py-4 max-sm:px-4">
        {tile("Spent", usd(l.spent), "text-accent")}
        {tile("Came in", usd(l.income), "text-ink")}
        {tile("Transactions", String(l.count), "text-ink")}
      </div>
      {top.length > 1 && (
        <ul className="flex flex-col gap-2 border-b border-hair px-5 py-3.5 max-sm:px-4">
          {top.slice(0, 8).map((c) => (
            <li key={c.category} className="group/bar flex items-center gap-3 text-[14px]" title={`${c.category}: ${usd(c.amount)} over ${c.count} ${c.count === 1 ? "charge" : "charges"}`}>
              <span className="w-28 shrink-0 truncate text-mid group-hover/bar:text-ink max-sm:w-24">{c.category}</span>
              <span className="h-2 min-w-0 flex-1">
                <span className="block h-full rounded-r-[4px] bg-accent/70 group-hover/bar:bg-accent" style={{ width: `${Math.max(1.5, (c.amount / most) * 100)}%` }} />
              </span>
              <span className="w-24 shrink-0 text-right text-ink tabular-nums">{usd(c.amount)}</span>
            </li>
          ))}
          {top.length > 8 && <li className="text-[12.5px] text-soft">and {top.length - 8} more categories</li>}
        </ul>
      )}
      {l.rows.length === 0 && <p className="px-5 py-4 text-[15px] text-mid">No transactions in these days.</p>}
      {[...days].map(([day, rows]) => (
        <section key={day} className="border-hair not-first:border-t">
          <h4 className="sticky top-0 z-10 bg-block px-5 py-2 text-xs font-semibold tracking-wide text-mid uppercase max-sm:px-4">{dayLabel(day)}</h4>
          <ul className="flex flex-col py-1">
            {rows.map(([, merchant, amount, category, kind, pending, mask], n) => {
              const tone = kind === "spend" ? (amount > 0 ? "text-accent" : "text-ink") : kind === "income" ? "text-ink" : "text-soft";
              const shown = kind === "spend" ? (amount > 0 ? usd(amount) : signed(-amount)) : kind === "income" ? signed(-amount) : usd(Math.abs(amount));
              const account = l.accounts[mask];
              return (
                <li key={n} className="flex items-baseline gap-3 px-5 py-2 max-sm:px-4">
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-[15px] text-ink">{merchant || "Unnamed"}</span>
                    <span className="block truncate text-[12.5px] text-soft">
                      {category}
                      {account ? ` · ${account}` : ""}
                      {mask ? ` ··${mask}` : ""}
                      {pending ? " · pending" : ""}
                    </span>
                  </span>
                  <span className={`shrink-0 text-[15px] tabular-nums ${tone}`}>{shown}</span>
                </li>
              );
            })}
          </ul>
        </section>
      ))}
      {l.shown < l.count && <p className="border-t border-hair px-5 py-3 text-[13px] text-soft max-sm:px-4">The newest {l.shown} of {l.count}. Ask for fewer days to see the rest.</p>}
    </BigCard>
  );
}

// What the markets tool gives: the investment accounts with their holdings,
// and their total on each day the money page kept balances.
type Holding = { ticker: string | null; name: string | null; type: string | null; quantity: number | null; price: number | null; as_of: string | null; value: number | null; cost: number | null };
type Account = { name: string | null; mask: string | null; subtype: string | null; institution: string | null; value: number; cash: number; cost: number; gain: number; holdings: Holding[] };
type Markets = { value: number; cost: number; gain: number; as_of: string | null; accounts: Account[]; history: { date: string; value: number }[] };

// How the investments are doing: their worth now and against what they
// cost, the total over time, then each account and what it holds. Gains are
// ink, losses red.
function MarketsCard({ m }: { m: Markets }) {
  const tone = (n: number) => (n < -0.005 ? "text-accent" : "text-ink");
  const pct = (gain: number, cost: number) => (cost > 0 ? ` (${(gain / cost * 100).toFixed(1)}%)` : "");
  const first = m.history[0];
  const moved = first ? m.value - first.value : 0;
  return (
    <BigCard icon="📈" title="Markets" tag={m.as_of ? `prices ${shortDay(m.as_of)}` : undefined}>
      <div className="flex flex-col gap-1 border-b border-hair px-5 pt-5 pb-4 max-sm:px-4">
        <span className="text-[11px] font-semibold tracking-wide text-soft uppercase">Invested</span>
        <span className="text-[40px] leading-none text-ink tabular-nums max-sm:text-[34px]">{usd(m.value)}</span>
        {m.cost > 0 && (
          <span className={`text-[15px] tabular-nums ${tone(m.gain)}`}>
            {signed(m.gain)}
            {pct(m.gain, m.cost)} on cost
          </span>
        )}
        {first && m.history.length > 1 && (
          <span className={`text-[15px] tabular-nums ${tone(moved)}`}>
            {signed(moved)} since {shortDay(first.date)}
          </span>
        )}
      </div>
      {m.history.length > 1 ? (
        <History points={m.history} />
      ) : (
        <p className="border-b border-hair px-5 py-3 text-[13px] text-soft max-sm:px-4">The money page keeps a balance each day; the line over time fills in from here.</p>
      )}
      {m.accounts.length === 0 && <p className="px-5 py-4 text-[15px] text-mid">No investment accounts linked.</p>}
      {m.accounts.map((a, n) => (
        <section key={n} className="border-hair not-first:border-t">
          <header className="flex items-baseline gap-3 px-5 pt-3.5 pb-1 max-sm:px-4">
            <span className="min-w-0 flex-1">
              <span className="block truncate text-[16px] font-medium text-ink">{a.name || "Account"}</span>
              <span className="block truncate text-[12.5px] text-soft">
                {[a.institution, a.subtype, a.mask && `··${a.mask}`].filter(Boolean).join(" · ")}
              </span>
            </span>
            <span className="shrink-0 text-right">
              <span className="block text-[16px] text-ink tabular-nums">{usd(a.value)}</span>
              {a.cost > 0 && <span className={`block text-[12.5px] tabular-nums ${tone(a.gain)}`}>{signed(a.gain)}{pct(a.gain, a.cost)}</span>}
            </span>
          </header>
          <ul className="flex flex-col pb-2">
            {a.holdings.map((h, k) => {
              const gain = h.value != null && h.cost != null ? h.value - h.cost : null;
              return (
                <li key={k} className="flex items-baseline gap-3 px-5 py-1.5 text-[14px] max-sm:px-4">
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-ink">
                      {h.ticker && <span className="font-medium">{h.ticker} </span>}
                      <span className={h.ticker ? "text-mid" : ""}>{h.name || ""}</span>
                    </span>
                    {h.quantity != null && h.price != null && (
                      <span className="block truncate text-[12.5px] text-soft tabular-nums">
                        {+h.quantity.toFixed(4)} × {usd(h.price)}
                      </span>
                    )}
                  </span>
                  <span className="shrink-0 text-right">
                    <span className="block text-ink tabular-nums">{h.value != null ? usd(h.value) : "—"}</span>
                    {gain != null && <span className={`block text-[12.5px] tabular-nums ${tone(gain)}`}>{signed(gain)}</span>}
                  </span>
                </li>
              );
            })}
            {Math.abs(a.cash) >= 0.5 && (
              <li className="flex items-baseline gap-3 px-5 py-1.5 text-[14px] max-sm:px-4">
                <span className="min-w-0 flex-1 truncate text-mid">{a.holdings.length ? "Cash and the rest" : "Holdings not reported"}</span>
                <span className="shrink-0 text-ink tabular-nums">{usd(a.cash)}</span>
              </li>
            )}
          </ul>
        </section>
      ))}
    </BigCard>
  );
}

// The total over time as one ink line, with a crosshair and the day's value
// under the finger or pointer.
function History({ points }: { points: { date: string; value: number }[] }) {
  const [at, setAt] = useState<number | null>(null);
  const W = 600;
  const H = 120;
  const lo = Math.min(...points.map((p) => p.value));
  const hi = Math.max(...points.map((p) => p.value));
  const pad = Math.max(1, (hi - lo) * 0.12);
  const x = (n: number) => (n / (points.length - 1)) * W;
  const y = (v: number) => H - ((v - lo + pad) / (hi - lo + 2 * pad)) * H;
  const line = points.map((p, n) => `${n ? "L" : "M"}${x(n).toFixed(1)},${y(p.value).toFixed(1)}`).join("");
  const pick = (e: PointerEvent<HTMLDivElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    setAt(Math.round(Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)) * (points.length - 1)));
  };
  const p = at == null ? null : points[at];
  return (
    <div className="border-b border-hair px-5 pt-9 pb-3 max-sm:px-4">
      <div className="relative h-[120px] touch-pan-y" onPointerMove={pick} onPointerDown={pick} onPointerLeave={() => setAt(null)}>
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" className="absolute inset-0 size-full overflow-visible">
          <path d={line} fill="none" stroke="var(--ink)" strokeWidth={2} vectorEffect="non-scaling-stroke" strokeLinejoin="round" strokeLinecap="round" />
          {p && <line x1={x(at!)} x2={x(at!)} y1={0} y2={H} stroke="var(--ink)" strokeOpacity={0.25} strokeWidth={1} vectorEffect="non-scaling-stroke" />}
        </svg>
        {p && (
          <>
            <span
              className="pointer-events-none absolute size-2.5 -translate-1/2 rounded-full border-2 border-lift bg-ink"
              style={{ left: `${(x(at!) / W) * 100}%`, top: `${(y(p.value) / H) * 100}%` }}
            />
            <span
              className="pointer-events-none absolute -top-1 rounded-md border border-hair bg-lift px-2 py-1 text-[12.5px] whitespace-nowrap text-ink shadow-lift tabular-nums"
              style={{ left: `${(x(at!) / W) * 100}%`, transform: `translate(${at! > points.length / 2 ? "calc(-100% - 8px)" : "8px"}, -100%)` }}
            >
              {shortDay(p.date)} · {usd(p.value)}
            </span>
          </>
        )}
      </div>
      <div className="mt-1 flex justify-between text-[11.5px] text-soft tabular-nums">
        <span>{shortDay(points[0].date)}</span>
        <span>{shortDay(points[points.length - 1].date)}</span>
      </div>
    </div>
  );
}
