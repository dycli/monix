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
  if (chat.state === "loading") return <Centered><Dots /></Centered>;
  if (chat.state === "signed-out") return <SignIn />;
  if (chat.state === "error") return <Centered><p className="text-stone-500">{chat.error}</p></Centered>;
  return <Thread messages={chat.messages} typing={chat.typing} send={chat.send} />;
}

function Centered({ children }: { children: React.ReactNode }) {
  return <div className="flex h-full items-center justify-center p-6 text-center">{children}</div>;
}

function Avatar({ size = "size-8 text-sm" }: { size?: string }) {
  return (
    <div className={`${size} grid shrink-0 place-items-center rounded-full bg-accent font-semibold text-white select-none`}>
      {NAME[0]}
    </div>
  );
}

function Dots() {
  return (
    <div className="flex gap-1 py-2" aria-label="Typing">
      {[0, 150, 300].map((d) => (
        <span key={d} className="size-1.5 animate-bounce rounded-full bg-stone-400" style={{ animationDelay: `${d}ms` }} />
      ))}
    </div>
  );
}

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
    <Centered>
      <div className="flex w-full max-w-sm flex-col items-center gap-6 rounded-3xl border border-stone-200 bg-white px-8 py-10 shadow-sm dark:border-stone-800 dark:bg-stone-900">
        <Avatar size="size-14 text-2xl" />
        <div className="space-y-1.5">
          <h1 className="text-xl font-semibold tracking-tight">{NAME}</h1>
          <p className="text-sm text-stone-500 dark:text-stone-400">
            {code ? "React 👍 in Matrix to the message showing this code." : "Sign in by approving a code in Matrix."}
          </p>
        </div>
        {code ? (
          <div className="flex flex-col items-center gap-4">
            <span className="rounded-2xl bg-stone-100 px-5 py-3 font-mono text-3xl font-medium tracking-[0.2em] dark:bg-stone-800">
              {code}
            </span>
            <span className="flex items-center gap-2 text-xs text-stone-400">
              <Dots /> Waiting for approval
            </span>
          </div>
        ) : (
          <button
            className="w-full rounded-full bg-ink py-2.5 text-sm font-medium text-white transition hover:bg-stone-700 disabled:opacity-40 dark:bg-stone-100 dark:text-ink dark:hover:bg-white"
            disabled={busy}
            onClick={start}
          >
            Sign in
          </button>
        )}
        {said && <p className="text-sm text-red-600 dark:text-red-400">{said}</p>}
      </div>
    </Centered>
  );
}

const ArrowUp = () => (
  <svg viewBox="0 0 24 24" className="size-4" fill="none" stroke="currentColor" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 19V5M5 12l7-7 7 7" />
  </svg>
);

const ArrowDown = () => (
  <svg viewBox="0 0 24 24" className="size-4" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 5v14M19 12l-7 7-7-7" />
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
        <header className="flex shrink-0 items-center gap-3 border-b border-stone-200/80 px-4 py-3 dark:border-stone-800">
          <div className="mx-auto flex w-full max-w-3xl items-center gap-3">
            <Avatar />
            <div className="font-semibold">{NAME}</div>
          </div>
        </header>
        <ThreadPrimitive.Viewport className="flex flex-1 flex-col overflow-y-auto px-4 pt-8">
          <div className="mx-auto flex w-full max-w-3xl flex-col gap-6">
            <ThreadPrimitive.Empty>
              <div className="flex flex-col items-center gap-3 pt-[20vh] text-center">
                <Avatar size="size-12 text-xl" />
                <p className="text-lg text-stone-500">What can I do for you?</p>
              </div>
            </ThreadPrimitive.Empty>
            <ThreadPrimitive.Messages>
              {({ message }) =>
                message.role === "user" ? <UserMessage /> : message.role === "assistant" ? <AssistantMessage /> : <Note />
              }
            </ThreadPrimitive.Messages>
            {typing && (
              <div className="flex gap-3">
                <Avatar />
                <Dots />
              </div>
            )}
          </div>
          <ThreadPrimitive.ViewportFooter className="sticky bottom-0 mx-auto mt-auto w-full max-w-3xl bg-gradient-to-t from-paper from-70% to-transparent pt-6 pb-[max(1rem,env(safe-area-inset-bottom))] dark:from-stone-950">
            <ThreadPrimitive.ScrollToBottom className="absolute -top-6 left-1/2 grid size-9 -translate-x-1/2 place-items-center rounded-full border border-stone-200 bg-white text-stone-600 shadow-sm disabled:invisible dark:border-stone-700 dark:bg-stone-900 dark:text-stone-300">
              <ArrowDown />
            </ThreadPrimitive.ScrollToBottom>
            <ComposerPrimitive.Root className="flex items-end gap-2 rounded-3xl border border-stone-200 bg-white p-2 pl-5 shadow-[0_2px_12px_rgb(0_0_0/0.06)] transition focus-within:border-stone-300 dark:border-stone-800 dark:bg-stone-900 dark:focus-within:border-stone-700">
              <ComposerPrimitive.Input
                autoFocus
                placeholder={`Message ${NAME}`}
                className="max-h-48 flex-1 resize-none bg-transparent py-2 outline-none placeholder:text-stone-400"
              />
              <ComposerPrimitive.Send className="grid size-9 shrink-0 place-items-center rounded-full bg-accent text-white transition hover:brightness-110 disabled:bg-stone-200 disabled:text-stone-400 dark:disabled:bg-stone-800 dark:disabled:text-stone-500">
                <ArrowUp />
              </ComposerPrimitive.Send>
            </ComposerPrimitive.Root>
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
    <span className="absolute -bottom-3 right-3 rounded-full border border-stone-200 bg-white px-1.5 py-0.5 text-sm leading-none shadow-sm dark:border-stone-700 dark:bg-stone-900">
      {reaction}
    </span>
  ) : null;
}

/** The time, shown when the pointer rests on a message. */
function Time({ className = "" }: { className?: string }) {
  const at = useAuiState((s) => s.message.createdAt);
  if (!at) return null;
  const today = at.toDateString() === new Date().toDateString();
  const when = at.toLocaleString(undefined, today ? { timeStyle: "short" } : { dateStyle: "medium", timeStyle: "short" });
  return <div className={`text-xs text-stone-400 opacity-0 transition group-hover:opacity-100 ${className}`}>{when}</div>;
}

function UserMessage() {
  return (
    <MessagePrimitive.Root className="group flex flex-col items-end gap-1">
      <div className="relative max-w-[80%] rounded-3xl rounded-br-lg bg-stone-200/70 px-4 py-2.5 whitespace-pre-wrap dark:bg-stone-800">
        <MessagePrimitive.Parts />
        <Reaction />
      </div>
      <Time className="mr-2" />
    </MessagePrimitive.Root>
  );
}

const Text = () => <StreamdownTextPrimitive plugins={{ code, math }} mode="static" />;

function AssistantMessage() {
  const { plain } = useCustom();
  return (
    <MessagePrimitive.Root className="group flex gap-3">
      <Avatar />
      <div className="relative min-w-0 flex-1 pt-0.5">
        {plain ? (
          <pre className="rounded-2xl border border-amber-200 bg-amber-50 p-4 font-sans text-sm whitespace-pre-wrap dark:border-amber-900/60 dark:bg-amber-950/30">
            <MessagePrimitive.Parts />
          </pre>
        ) : (
          <div className="prose-chat">
            <MessagePrimitive.Parts
              components={{
                Text,
                Image: () => <MessagePartPrimitive.Image className="max-w-sm rounded-2xl border border-stone-200 dark:border-stone-800" />,
              }}
            />
          </div>
        )}
        <Reaction />
        <Time className="mt-1" />
      </div>
    </MessagePrimitive.Root>
  );
}

function Note() {
  return (
    <MessagePrimitive.Root className="mx-auto rounded-full bg-stone-200/60 px-3 py-1 text-center text-xs text-stone-500 dark:bg-stone-800/60 dark:text-stone-400">
      <MessagePrimitive.Parts />
    </MessagePrimitive.Root>
  );
}
