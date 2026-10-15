import { useEffect, useState } from "react";
import {
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
} from "@assistant-ui/react";
import { StreamdownTextPrimitive } from "@assistant-ui/react-streamdown";
import { code } from "@streamdown/code";
import { math } from "@streamdown/math";
import { askToSignIn, attachments, useChat, waitToSignIn, type Msg } from "./chat";
import { useTheme } from "./theme";

const convert = (m: Msg): ThreadMessageLike => ({
  id: m.id,
  role: m.role,
  content: [
    ...(m.text ? [{ type: "text" as const, text: m.text }] : []),
    ...(m.png ? [{ type: "image" as const, image: `data:image/png;base64,${m.png}` }] : []),
  ],
  attachments: m.file && [
    {
      id: `${m.id}-file`,
      type: m.file.image ? "image" : "document",
      name: m.file.name,
      status: { type: "complete" },
      content: m.file.image ? [{ type: "image", image: m.file.image }] : [],
    },
  ],
  createdAt: m.date,
  metadata: { custom: { plain: m.plain ?? false, reaction: m.reaction ?? null } },
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
  return <Thread messages={chat.messages} typing={chat.typing} send={chat.send} />;
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

type Send = (text: string, file?: File) => Promise<void>;

function Thread({ messages, typing, send }: { messages: Msg[]; typing: boolean; send: Send }) {
  const runtime = useExternalStoreRuntime({
    messages,
    convertMessage: convert,
    isRunning: false,
    adapters: { attachments },
    onNew: async (m: AppendMessage) => {
      const text = m.content.flatMap((p) => (p.type === "text" ? [p.text] : [])).join("\n");
      // The yeoman takes one file a message; the composer allows only one.
      const file = m.attachments?.[0]?.file;
      if (text.trim() || file) await send(text, file);
    },
  });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ThreadPrimitive.Root className="flex h-full flex-col">
        <header className="flex h-[57px] shrink-0 items-center justify-between border-b border-hair bg-paper px-[max(20px,env(safe-area-inset-left))] max-sm:h-[51px] max-sm:px-3.5">
          <span className="font-brand text-xl font-semibold tracking-[-0.01em]">{NAME}</span>
          <ThemeButton className="-mr-2" />
        </header>
        <ThreadPrimitive.Viewport className="flex flex-1 flex-col overflow-y-auto">
          <main className="mx-auto flex w-[min(740px,100%-40px)] flex-col gap-3.5 pt-6 pb-10 max-sm:w-[calc(100%-28px)]">
            <ThreadPrimitive.Messages>
              {({ message }) =>
                message.role === "user" ? <UserMessage /> : message.role === "assistant" ? <AssistantMessage /> : <Note />
              }
            </ThreadPrimitive.Messages>
            {typing && <Dots />}
          </main>
          <ThreadPrimitive.ViewportFooter className="sticky bottom-0 mt-auto bg-[linear-gradient(transparent,var(--paper)_14px)] px-5 pt-[18px] pb-[max(14px,env(safe-area-inset-bottom))] max-sm:px-3.5 max-sm:pt-3 max-sm:pb-[max(8px,env(safe-area-inset-bottom))]">
            <div className="relative mx-auto w-[min(740px,100%)]">
              <ThreadPrimitive.ScrollToBottom className="absolute -top-12 left-1/2 grid size-9 -translate-x-1/2 place-items-center rounded-full border border-frame bg-lift text-mid shadow-lift hover:text-ink disabled:invisible">
                <Arrow down />
              </ThreadPrimitive.ScrollToBottom>
              <ComposerPrimitive.Root className="rounded-3xl border border-frame bg-lift py-[7px] pr-[7px] pl-2 shadow-lift focus-within:border-soft max-sm:py-[5px] max-sm:pr-[5px] max-sm:pl-1.5">
                <ComposerPrimitive.AttachmentDropzone className="flex flex-col">
                <div className="flex flex-wrap gap-2 px-3 empty:hidden [&:not(:empty)]:pt-2 [&:not(:empty)]:pb-1">
                  <ComposerPrimitive.Attachments>{({ attachment }) => <Chip attachment={attachment} removable />}</ComposerPrimitive.Attachments>
                </div>
                <div className="flex items-end gap-1.5">
                <ComposerPrimitive.AddAttachment
                  multiple={false}
                  aria-label="Attach a file"
                  className="grid size-[38px] shrink-0 place-items-center rounded-full text-mid hover:text-ink disabled:invisible"
                >
                  <Clip />
                </ComposerPrimitive.AddAttachment>
                <ComposerPrimitive.Input
                  autoFocus
                  placeholder={`Message ${NAME}`}
                  className="max-h-[40vh] flex-1 resize-none bg-transparent py-[7px] text-base leading-normal outline-none placeholder:text-soft"
                />
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
  return useAuiState((s) => s.message.metadata.custom) as { plain: boolean; reaction: string | null };
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
    <MessagePrimitive.Root className="group flex flex-col items-end gap-1.5">
      <MessagePrimitive.Attachments>{({ attachment }) => <Chip attachment={attachment} />}</MessagePrimitive.Attachments>
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

const Text = () => (
  <StreamdownTextPrimitive plugins={{ code, math }} mode="static" lineNumbers={false} controls={{ code: true, table: false }} />
);

function AssistantMessage() {
  const { plain } = useCustom();
  return (
    <MessagePrimitive.Root className="group relative">
      {plain ? (
        // A draft waiting for approval: framed and named on its frame, as
        // UniiChat frames a report.
        <div className="relative mt-2 rounded-[14px] border-[1.25px] border-edge px-5 py-3.5 whitespace-pre-wrap [overflow-wrap:anywhere]">
          <span className="absolute -top-[0.75em] left-3.5 bg-paper px-1.5 text-xs font-semibold text-mid">Draft</span>
          <MessagePrimitive.Parts />
        </div>
      ) : (
        <div className="md">
          <MessagePrimitive.Parts
            components={{
              Text,
              Image: () => <MessagePartPrimitive.Image className="max-h-80 max-w-full rounded-lg border border-hair" />,
            }}
          />
        </div>
      )}
      <Reaction />
      <Time className="mt-1" />
    </MessagePrimitive.Root>
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
      <MessagePrimitive.Root className={style}>
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
    <MessagePrimitive.Root className={style}>
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
