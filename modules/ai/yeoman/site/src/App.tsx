import { useEffect, useState } from "react";
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
import { code } from "@streamdown/code";
import { math } from "@streamdown/math";
import { askToSignIn, attachments, drives, said, search, useChat, waitToSignIn, type Card, type Hit, type Msg, type Task } from "./chat";
import { useTheme } from "./theme";
import { usePush } from "./push";

type Args = ToolCallMessagePartProps["args"];

const convert = (m: Msg): ThreadMessageLike => ({
  id: m.id,
  role: m.role,
  content: [
    ...(m.tools ?? []).map((t) => ({
      type: "tool-call" as const,
      toolCallId: t.id,
      toolName: t.name,
      args: (t.input ?? {}) as Args,
      result: t.result,
      isError: t.error,
    })),
    ...(m.text ? [{ type: "text" as const, text: m.text }] : []),
    ...(m.png ? [{ type: "image" as const, image: `data:image/png;base64,${m.png}` }] : []),
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

// The page has no name of its own: it takes the assistant's from the host,
// sokka.su.is → Sokka.
const label = location.hostname.split(".")[0];
const NAME = /^[a-z]+$/.test(label) ? label[0].toUpperCase() + label.slice(1) : "Chat";
document.title = NAME;

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

const WHO: Record<string, string> = { user: "You", talk: NAME, note: "Note" };

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

function BellButton() {
  const [bell, toggle] = usePush();
  if (bell === "unsupported") return null;
  const label = {
    on: "Notifications on",
    off: "Turn on notifications",
    denied: "Notifications blocked in the browser's settings",
  }[bell];
  return (
    <button
      onClick={toggle}
      disabled={bell === "denied"}
      aria-label={label}
      title={label}
      aria-pressed={bell === "on"}
      className={`grid size-9 place-items-center rounded-full hover:bg-hover hover:text-ink disabled:opacity-40 ${bell === "on" ? "text-ink" : "text-mid"}`}
    >
      <svg viewBox="0 0 24 24" className="size-[18px]" fill={bell === "on" ? "currentColor" : "none"} stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
        <path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9" />
        <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0" />
        {bell !== "on" && bell !== "off" && <path d="M3 3l18 18" />}
      </svg>
    </button>
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
      <h1 className="font-serif text-[46px] leading-[1.05] tracking-[-0.015em]">{NAME}</h1>
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

const Clip = () => (
  <svg viewBox="0 0 24 24" className="size-5" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
    <path d="m21.4 11.1-9.2 9.2a6 6 0 0 1-8.5-8.5l9.2-9.2a4 4 0 0 1 5.7 5.7l-9.2 9.2a2 2 0 0 1-2.8-2.8l8.5-8.5" />
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

type Send = (text: string, files: File[]) => Promise<void>;
type Decide = (id: number, yes: boolean) => Promise<void>;

type ThreadProps = {
  messages: Msg[];
  typing: boolean;
  send: Send;
  stop: () => Promise<void>;
  cards: Card[];
  decide: Decide;
  task: Task | null;
  stopTask: () => Promise<void>;
  screen?: string;
};

function Thread({ messages, typing, send, stop, cards, decide, task, stopTask, screen }: ThreadProps) {
  const [finding, setFinding] = useState(false);
  // The dots stand for work not yet shown; once words or tools arrive, they show it.
  const working = typing && !messages.at(-1)?.live;
  // The screen shows while the turn or the task drives the computer.
  const last = messages.at(-1);
  const watching = !!screen && ((!!last?.live && drives(last.tools)) || drives(task?.tools));
  const runtime = useExternalStoreRuntime({
    messages,
    convertMessage: convert,
    isRunning: false,
    adapters: { attachments },
    onNew: async (m: AppendMessage) => {
      const text = m.content.flatMap((p) => (p.type === "text" ? [p.text] : [])).join("\n");
      const files = (m.attachments ?? []).flatMap((a) => (a.file ? [a.file] : []));
      if (text.trim() || files.length) await send(text, files);
    },
  });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ThreadPrimitive.Root className="flex h-full flex-col">
        <header className="flex h-[57px] shrink-0 items-center justify-between border-b border-hair bg-paper px-[max(20px,env(safe-area-inset-left))] max-sm:h-[51px] max-sm:px-3.5">
          <span className="font-serif text-[22px] tracking-[-0.01em]">{NAME}</span>
          <div className="-mr-2 flex">
            <HeaderButton label="Search the conversation" onClick={() => setFinding(true)}>
              <circle cx="11" cy="11" r="7" />
              <path d="m20 20-3.5-3.5" />
            </HeaderButton>
            <BellButton />
            <ThemeButton />
          </div>
        </header>
        {finding && <Search close={() => setFinding(false)} />}
        <ThreadPrimitive.Viewport className="flex flex-1 flex-col overflow-y-auto">
          <main className="mx-auto flex w-[min(740px,100%-40px)] flex-col gap-3.5 pt-6 pb-10 max-sm:w-[calc(100%-28px)]">
            <ThreadPrimitive.Messages>
              {({ message }) =>
                message.role === "user" ? <UserMessage /> : message.role === "assistant" ? <AssistantMessage /> : <Note />
              }
            </ThreadPrimitive.Messages>
            {working && <Dots />}
          </main>
          <ThreadPrimitive.ViewportFooter className="sticky bottom-0 mt-auto bg-[linear-gradient(transparent,var(--paper)_14px)] px-5 pt-[18px] pb-[max(14px,env(safe-area-inset-bottom))] max-sm:px-3.5 max-sm:pt-3 max-sm:pb-[max(8px,env(safe-area-inset-bottom))]">
            <div className="relative mx-auto w-[min(740px,100%)]">
              {/* What waits or works above the composer scrolls as one, so the talk stays in view. */}
              <div className="max-h-[min(66vh,720px)] overflow-y-auto pt-2.5 empty:hidden">
                {screen && <Screen url={screen} on={watching} />}
                {task && <TaskStrip task={task} stop={stopTask} />}
                <Tray cards={cards} decide={decide} />
              </div>
              <ThreadPrimitive.ScrollToBottom className="absolute -top-12 left-1/2 z-10 grid size-9 -translate-x-1/2 place-items-center rounded-full border border-frame bg-lift text-mid shadow-lift hover:text-ink disabled:invisible">
                <Arrow down />
              </ThreadPrimitive.ScrollToBottom>
              <ComposerPrimitive.Root className="rounded-3xl border border-frame bg-lift py-[7px] pr-[7px] pl-2 shadow-lift focus-within:border-soft max-sm:py-[5px] max-sm:pr-[5px] max-sm:pl-1.5">
                <ComposerPrimitive.AttachmentDropzone className="flex flex-col">
                <div className="flex flex-wrap gap-2 px-3 empty:hidden [&:not(:empty)]:pt-2 [&:not(:empty)]:pb-1">
                  <ComposerPrimitive.Attachments>{({ attachment }) => <Chip attachment={attachment} removable />}</ComposerPrimitive.Attachments>
                </div>
                <div className="flex items-end gap-1.5">
                <ComposerPrimitive.AddAttachment
                  aria-label="Attach files"
                  className="grid size-[38px] shrink-0 place-items-center rounded-full text-mid hover:text-ink disabled:invisible"
                >
                  <Clip />
                </ComposerPrimitive.AddAttachment>
                <ComposerPrimitive.Input
                  autoFocus
                  placeholder={`Message ${NAME}`}
                  className="max-h-[40vh] flex-1 resize-none bg-transparent py-[7px] text-base leading-normal outline-none placeholder:text-soft"
                />
                {typing && (
                  <button
                    type="button"
                    onClick={() => void stop()}
                    aria-label="Stop"
                    title="Stop"
                    className="grid size-[38px] shrink-0 place-items-center rounded-full border border-frame text-ink hover:bg-hover"
                  >
                    <span className="size-3 rounded-[2px] bg-current" />
                  </button>
                )}
                <ComposerPrimitive.Send aria-label="Send" className="grid size-[38px] shrink-0 place-items-center rounded-full bg-ink text-paper disabled:bg-hair disabled:text-soft">
                  <Arrow />
                </ComposerPrimitive.Send>
                </div>
                </ComposerPrimitive.AttachmentDropzone>
              </ComposerPrimitive.Root>
            </div>
          </ThreadPrimitive.ViewportFooter>
        </ThreadPrimitive.Viewport>
      </ThreadPrimitive.Root>
    </AssistantRuntimeProvider>
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
// breaks anywhere rather than running off the page.
function UserMessage() {
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
      <Time className="mt-1 mr-1" />
    </MessagePrimitive.Root>
  );
}

// A live answer is parsed as it streams, its unfinished markdown closed
// for it, and shows a caret until the whole answer replaces it.
function Text() {
  const { live } = useCustom();
  return (
    <StreamdownTextPrimitive
      plugins={{ code, math }}
      mode={live ? "streaming" : "static"}
      containerClassName={live ? "writing" : undefined}
      lineNumbers={false}
      controls={{ code: true, table: false }}
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
          <MessagePrimitive.Parts
            components={{
              Text,
              tools: { Fallback: Tool },
              Image: () => <MessagePartPrimitive.Image className="max-h-80 max-w-full rounded-lg border border-hair" />,
            }}
          />
        </div>
      )}
      <Reaction />
      <div className="mt-1 flex items-center gap-2">
        <Copy />
        <Time />
      </div>
    </MessagePrimitive.Root>
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
function gist(args: Args | undefined) {
  const first = Object.values(args ?? {}).find((v) => typeof v === "string" && v.trim());
  return typeof first === "string" ? first.split("\n")[0] : "";
}

// One quiet line per tool the model used on its way to an answer, with a
// spinner until the result is back; a click opens what went in and came out.
function ToolLine({ toolName: name, args, result, isError }: ToolCallMessagePartProps) {
  const { live } = useCustom();
  return <ToolRow name={name} args={args} result={result} isError={isError} live={live} />;
}

type Row = { name: string; args: Args | undefined; result: unknown; isError?: boolean; live?: boolean };

function ToolRow({ name, args, result, isError, live }: Row) {
  const done = result !== undefined;
  const mark = !done ? (live ? "spin" : "·") : isError ? "✕" : "✓";
  return (
    <details className="group/tool not-prose my-0.5 text-[13.5px] text-mid last-of-type:mb-3">
      <summary className="flex cursor-pointer list-none items-center gap-2 marker:hidden [&::-webkit-details-marker]:hidden">
        {mark === "spin" ? (
          <span className="size-3 shrink-0 animate-spin rounded-full border-[1.5px] border-hair border-t-accent" />
        ) : (
          <span className={`w-3 shrink-0 text-center ${isError ? "text-accent" : "text-soft"}`}>{mark}</span>
        )}
        <span className="shrink-0 font-medium text-ink/80">{toolName(name)}</span>
        <span className="truncate text-soft">{gist(args)}</span>
      </summary>
      <div className="mt-1.5 mb-2 ml-5 flex flex-col gap-1.5">
        <pre className="max-h-48 overflow-auto rounded-lg border border-hair bg-lift px-3 py-2 text-xs whitespace-pre-wrap [overflow-wrap:anywhere]">
          {JSON.stringify(args, null, 2)}
        </pre>
        {done && (
          <pre className="max-h-72 overflow-auto rounded-lg border border-hair bg-lift px-3 py-2 text-xs whitespace-pre-wrap [overflow-wrap:anywhere]">
            {String(result) || "(nothing)"}
          </pre>
        )}
      </div>
    </details>
  );
}

// Tools with a card of their own; the rest draw as a ToolLine. Keyed by the
// tool's own name, whichever server carries it.
function Tool(props: ToolCallMessagePartProps) {
  if (props.toolName.endsWith("__events")) return <CalendarCard {...props} />;
  if (/__(lists|list_add|list_remove|share_list)$/.test(props.toolName)) return <ListCards {...props} />;
  if (props.toolName.endsWith("__mail_search")) return <InboxCard {...props} />;
  if (props.toolName.endsWith("__mail_read")) return <MailCard {...props} />;
  if (props.toolName.endsWith("__weather")) return <WeatherCard {...props} />;
  return <ToolLine {...props} />;
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

// The calendar as a card, by day; a running, failed or unreadable call stays
// a ToolLine.
function CalendarCard(props: ToolCallMessagePartProps) {
  const list = props.isError ? undefined : events(props.result);
  if (!list) return <ToolLine {...props} />;
  const days = new Map<string, Event[]>();
  for (const e of list) days.set(e.start.slice(0, 10), [...(days.get(e.start.slice(0, 10)) ?? []), e]);
  return (
    <div className="not-prose my-2 overflow-hidden rounded-[14px] border-[1.25px] border-edge text-[14px] last-of-type:mb-3">
      {days.size === 0 && <p className="px-4 py-3 text-mid">Nothing on the calendar.</p>}
      {[...days].map(([day, es]) => (
        <section key={day} className="border-hair not-first:border-t">
          <h4 className="bg-lift px-4 py-1.5 text-xs font-semibold tracking-wide text-mid uppercase">{dayLabel(day)}</h4>
          <ul className="flex flex-col py-1">
            {es.map((e) => (
              <li key={e.uid + e.start} className="flex gap-3 px-4 py-1.5">
                <span className="w-[5.5rem] shrink-0 text-mid tabular-nums">
                  {e.start.length > 10 ? `${e.start.slice(11)}–${e.end.startsWith(day) ? e.end.slice(11) : "…"}` : "All day"}
                </span>
                <span className="min-w-0">
                  <span className="text-ink">{e.summary}</span>
                  {e.repeats && <span className="ml-1.5 text-soft" title="Repeats">↻</span>}
                  {e.location && <span className="block truncate text-[13px] text-soft">{e.location}</span>}
                </span>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </div>
  );
}

// A list as the list tools report it: one object, or an array from `lists`.
type List = { list: string; shared: boolean; items: string[]; missing?: string[] };

function lists(result: unknown) {
  const v = parsed<List | List[]>(result, (v) => (Array.isArray(v) ? v : [v]).every((l) => typeof l?.list === "string" && Array.isArray(l.items)));
  return v && (Array.isArray(v) ? v : [v]);
}

// Each list as an index card: a ruled line under every item, the title over
// a red rule. A running, failed or unreadable call stays a ToolLine.
function ListCards(props: ToolCallMessagePartProps) {
  const all = props.isError ? undefined : lists(props.result);
  if (!all) return <ToolLine {...props} />;
  if (all.length === 0) return <p className="not-prose my-2 font-serif text-[14.5px] text-mid italic">No lists.</p>;
  return (
    <div className="not-prose my-2 grid gap-3 last-of-type:mb-3 sm:grid-cols-[repeat(auto-fill,minmax(15rem,1fr))]">
      {all.map((l) => (
        <section key={l.list} className="rounded-[3px] bg-lift px-4 pt-3 pb-2 shadow-lift">
          <h4 className="flex items-baseline justify-between gap-2 border-b-[1.5px] border-accent/60 pb-1 font-serif text-[16px] text-ink">
            <span className="min-w-0 truncate">{l.list}</span>
            {l.shared && <span className="shrink-0 font-sans text-[11px] tracking-wide text-soft uppercase">shared</span>}
          </h4>
          {l.items.length === 0 ? (
            <p className="py-1.5 font-serif text-[14.5px] text-soft italic">Emptied and put away.</p>
          ) : (
            <ul className="ruled">
              {l.items.map((item) => (
                <li key={item} className="font-serif text-[15px] text-ink [overflow-wrap:anywhere]">
                  {item}
                </li>
              ))}
            </ul>
          )}
          {l.missing && <p className="pt-1 text-[12.5px] text-soft">Wasn't on it: {l.missing.join(", ")}</p>}
        </section>
      ))}
    </div>
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
function InboxCard(props: ToolCallMessagePartProps) {
  const list = props.isError ? undefined : parsed<Mail[]>(props.result, (v) => Array.isArray(v) && v.every(isMail));
  if (!list) return <ToolLine {...props} />;
  return (
    <div className="not-prose my-2 overflow-hidden rounded-[14px] border-[1.25px] border-edge bg-lift text-[14px] last-of-type:mb-3">
      {list.length === 0 && <p className="px-4 py-3 text-mid">No mail found.</p>}
      <ul className="divide-y divide-hair">
        {list.map((m) => (
          <li key={m.uid} className="flex gap-3 px-4 py-2.5">
            <span className={`mt-[0.55em] size-1.5 shrink-0 rounded-full ${m.unread ? "bg-accent" : ""}`} />
            <span className="min-w-0 flex-1">
              <span className="flex items-baseline gap-3">
                <span className={`min-w-0 flex-1 truncate ${m.unread ? "font-semibold text-ink" : "text-mid"}`}>{sender(m.from)}</span>
                <span className="shrink-0 text-[12.5px] text-soft tabular-nums">{when(m.date)}</span>
              </span>
              <span className={`block truncate font-serif text-[15px] ${m.unread ? "text-ink" : "text-mid"}`}>{m.subject || "(no subject)"}</span>
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

// One message read whole, as a letter folded to a few lines.
function MailCard(props: ToolCallMessagePartProps) {
  const m = props.isError ? undefined : parsed<Mail>(props.result, isMail);
  const [open, setOpen] = useState(false);
  if (!m) return <ToolLine {...props} />;
  const head = "w-16 shrink-0 text-[11px] font-semibold tracking-wider text-soft uppercase";
  return (
    <article className="not-prose my-2 rounded-[14px] border-[1.25px] border-edge bg-lift last-of-type:mb-3">
      <dl className="flex flex-col gap-0.5 border-b border-dashed border-frame px-5 pt-3.5 pb-2.5 text-[14px]">
        <div className="flex items-baseline">
          <dt className={head}>From</dt>
          <dd className="min-w-0 flex-1 truncate" title={m.from}>{sender(m.from)}</dd>
          <dd className="shrink-0 pl-3 text-[12.5px] text-soft">{when(m.date)}</dd>
        </div>
        <div className="flex items-baseline">
          <dt className={head}>Subject</dt>
          <dd className="font-medium [overflow-wrap:anywhere]">{m.subject || "(no subject)"}</dd>
        </div>
      </dl>
      {m.text && (
        <div onClick={() => setOpen(!open)} title={open ? undefined : "Read it all"} className="cursor-pointer px-5 py-3">
          <p className={`font-serif text-[15.5px] leading-relaxed whitespace-pre-wrap [overflow-wrap:anywhere] ${open ? "max-h-96 overflow-y-auto" : "line-clamp-4"}`}>
            {m.text.replace(/\n\[cut\]$/, "")}
          </p>
        </div>
      )}
      {!!m.attachments?.length && (
        <ul className="flex flex-wrap gap-1.5 px-5 pb-3">
          {m.attachments.map((a, i) => (
            <li key={i} className="max-w-full truncate rounded-full border border-hair bg-block px-2.5 py-0.5 text-[12.5px] text-mid">
              📎 {a}
            </li>
          ))}
        </ul>
      )}
    </article>
  );
}

// Weather as the weather tool reports it: now, then a day a row.
type Forecast = { now: { temp: number; feels: number; code: number; day: boolean }; days: { date: string; code: number; high: number; low: number; rain: number | null }[] };

const isForecast = (v: any) => typeof v?.now?.temp === "number" && Array.isArray(v.days);
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

// The forecast as a card: now large, the days as a row beneath. A running,
// failed or unreadable call stays a ToolLine.
function WeatherCard(props: ToolCallMessagePartProps) {
  const w = props.isError ? undefined : parsed<Forecast>(props.result, isForecast);
  if (!w) return <ToolLine {...props} />;
  const [nowIcon, nowWord] = sky(w.now.code, w.now.day);
  return (
    <div className="not-prose my-2 overflow-hidden rounded-[14px] border-[1.25px] border-edge bg-lift text-[14px] last-of-type:mb-3">
      <div className="flex items-center gap-3 px-4 py-3">
        <span className="text-[34px] leading-none">{nowIcon}</span>
        <span className="min-w-0">
          <span className="text-[26px] leading-none text-ink tabular-nums">{deg(w.now.temp)}</span>
          <span className="block text-[13px] text-soft">{nowWord} · feels {deg(w.now.feels)}</span>
        </span>
      </div>
      {w.days.length > 0 && (
        <ul className="flex divide-x divide-hair border-t border-hair">
          {w.days.map((d, i) => {
            const [icon] = sky(d.code);
            const [y, m, day] = d.date.split("-").map(Number);
            const name = i === 0 ? "Now" : new Date(y, m - 1, day).toLocaleDateString(undefined, { weekday: "short" });
            return (
              <li key={d.date} className="flex min-w-0 flex-1 flex-col items-center gap-0.5 px-1 py-2">
                <span className="text-[12px] font-semibold tracking-wide text-mid uppercase">{name}</span>
                <span className="text-[20px] leading-none" title={sky(d.code)[1]}>{icon}</span>
                <span className="text-[13px] text-ink tabular-nums">{deg(d.high)}</span>
                <span className="text-[12.5px] text-soft tabular-nums">{deg(d.low)}</span>
                {d.rain != null && d.rain > 0 && <span className="text-[11px] text-accent tabular-nums">{d.rain}%</span>}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
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

// The computer's screen, watched while the yeoman works on it: noVNC's own
// page, view only, so a stray tap does not fight the model. Take over opens
// it with the keyboard, for a captcha or a sign-in only the person can do.
// It opens by itself when the work turns to the computer; hidden, it stays
// a line to bring it back.
function Screen({ url, on }: { url: string; on: boolean }) {
  const [hidden, setHidden] = useState(false);
  useEffect(() => {
    if (on) setHidden(false);
  }, [on]);
  if (!on) return null;
  const sep = url.includes("?") ? "&" : "?";
  const bar = "flex h-8 items-center gap-1 px-1 text-[13px] text-mid";
  const link = "rounded-full px-3 py-1 hover:bg-hover hover:text-ink";
  return (
    <section className="rise mb-3 overflow-hidden rounded-[14px] border-[1.25px] border-edge bg-lift shadow-lift" aria-label="The computer's screen">
      <div className={`${bar} justify-between`}>
        <span className="flex items-center gap-2 pl-2.5 font-medium text-ink/80">
          <span className="size-2 animate-pulse rounded-full bg-accent" /> On the computer
        </span>
        <span className="flex">
          <a href={url} target="_blank" rel="noreferrer" className={link}>
            Take over
          </a>
          <button type="button" onClick={() => setHidden(!hidden)} className={link}>
            {hidden ? "Show" : "Hide"}
          </button>
        </span>
      </div>
      {!hidden && <iframe src={`${url}${sep}view_only=1`} title="The computer's screen" className="block aspect-[16/10] max-h-[42vh] w-full border-0 border-t border-hair bg-ink" />}
    </section>
  );
}

// The task running on its own, apart from the talk: what was asked, what it
// is doing now, its work so far on a click, and Stop.
function TaskStrip({ task, stop }: { task: Task; stop: () => Promise<void> }) {
  const [open, setOpen] = useState(false);
  const now = task.tools.at(-1);
  const doing = task.words.trim() ? task.words.trim().split("\n").at(-1) : now ? `${toolName(now.name)} ${gist(now.input as Args)}` : "Starting";
  return (
    <section className="rise relative mb-3 rounded-[14px] border-[1.25px] border-edge bg-lift shadow-lift" aria-label="The task under way">
      <span className="absolute -top-[0.75em] left-3.5 rounded bg-lift px-1.5 text-xs font-semibold tracking-wide text-accent uppercase">
        {task.question ? "Task · waiting on you" : "Task under way"}
      </span>
      <div className="flex items-start gap-3 px-4 pt-3.5 pb-3">
        <button type="button" onClick={() => setOpen(!open)} className="flex min-w-0 flex-1 flex-col items-start gap-1 text-left" aria-expanded={open}>
          <p className={`text-[14.5px] [overflow-wrap:anywhere] ${open ? "" : "line-clamp-2"}`}>{task.text || "A task"}</p>
          <p className="flex w-full items-center gap-2 text-[13px] text-mid">
            {!task.question && <span className="size-3 shrink-0 animate-spin rounded-full border-[1.5px] border-hair border-t-accent" />}
            <span className="truncate">{task.question ?? doing}</span>
          </p>
        </button>
        <button
          type="button"
          onClick={stop}
          disabled={task.stopping}
          className="h-9 shrink-0 rounded-full px-4 text-[14px] text-mid hover:bg-hover hover:text-ink disabled:opacity-50"
        >
          {task.stopping ? "Stopping" : "Stop"}
        </button>
      </div>
      {open && task.tools.length > 0 && (
        <div className="max-h-[38vh] overflow-y-auto border-t border-dashed border-frame px-4 pt-2.5 pb-1">
          {task.tools.map((t) => (
            <ToolRow key={t.id} name={t.name} args={t.input as Args} result={t.result} isError={t.error} live />
          ))}
        </div>
      )}
    </section>
  );
}

// Acts waiting for the person's word sit above the composer, where the
// next thing is done, until a verdict here or in Matrix settles them. A
// mail draft reads as a letter on a sheet of its own.
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
