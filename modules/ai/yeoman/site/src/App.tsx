import { useState } from "react";
import {
  AssistantRuntimeProvider,
  ComposerPrimitive,
  MessagePartPrimitive,
  MessagePrimitive,
  ThreadPrimitive,
  useAuiState,
  useExternalStoreRuntime,
  type AppendMessage,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import { StreamdownTextPrimitive } from "@assistant-ui/react-streamdown";
import { code } from "@streamdown/code";
import { math } from "@streamdown/math";
import { askToSignIn, useChat, waitToSignIn, type Msg } from "./chat";

const convert = (m: Msg): ThreadMessageLike => ({
  id: m.id,
  role: m.role,
  content: [
    ...(m.text ? [{ type: "text" as const, text: m.text }] : []),
    ...(m.png ? [{ type: "image" as const, image: `data:image/png;base64,${m.png}` }] : []),
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
  return <main className="mx-auto mt-[18vh] w-[min(420px,100%-48px)] text-center">{children}</main>;
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

function Thread({ messages, typing, send }: { messages: Msg[]; typing: boolean; send: (t: string) => Promise<void> }) {
  const runtime = useExternalStoreRuntime({
    messages,
    convertMessage: convert,
    isRunning: false,
    onNew: async (m: AppendMessage) => {
      const text = m.content.flatMap((p) => (p.type === "text" ? [p.text] : [])).join("\n");
      if (text.trim()) await send(text);
    },
  });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ThreadPrimitive.Root className="flex h-full flex-col">
        <header className="flex h-[57px] shrink-0 items-center border-b border-hair bg-paper px-[max(20px,env(safe-area-inset-left))] max-sm:h-[51px] max-sm:px-3.5">
          <span className="font-brand text-xl font-semibold tracking-[-0.01em]">{NAME}</span>
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
              <ComposerPrimitive.Root className="flex items-end gap-2.5 rounded-3xl border border-frame bg-lift py-[7px] pr-[7px] pl-5 shadow-lift focus-within:border-soft max-sm:py-[5px] max-sm:pr-[5px] max-sm:pl-4">
                <ComposerPrimitive.Input
                  autoFocus
                  placeholder={`Message ${NAME}`}
                  className="max-h-[40vh] flex-1 resize-none bg-transparent py-[7px] text-base leading-normal outline-none placeholder:text-soft"
                />
                <ComposerPrimitive.Send className="grid size-[38px] shrink-0 place-items-center rounded-full bg-ink text-paper disabled:bg-hair disabled:text-soft">
                  <Arrow />
                </ComposerPrimitive.Send>
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
    <MessagePrimitive.Root className="group flex flex-col items-end">
      <div className="relative w-fit max-w-[min(82%,560px)] rounded-[20px_20px_6px_20px] border-[1.25px] border-edge px-[17px] py-2.5 whitespace-pre-wrap [overflow-wrap:anywhere]">
        <MessagePrimitive.Parts />
        <Reaction />
      </div>
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
  return (
    <MessagePrimitive.Root className="font-serif text-[14.5px] leading-relaxed whitespace-pre-wrap text-mid italic [overflow-wrap:anywhere]">
      <MessagePrimitive.Parts />
    </MessagePrimitive.Root>
  );
}
