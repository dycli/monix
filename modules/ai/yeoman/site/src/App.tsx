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

export function App() {
  const chat = useChat();
  if (chat.state === "loading") return <Centered>…</Centered>;
  if (chat.state === "signed-out") return <SignIn />;
  if (chat.state === "error") return <Centered>{chat.error}</Centered>;
  return <Thread messages={chat.messages} typing={chat.typing} send={chat.send} />;
}

function Centered({ children }: { children: React.ReactNode }) {
  return <div className="flex h-full items-center justify-center p-6 text-center text-neutral-500">{children}</div>;
}

function SignIn() {
  const [said, setSaid] = useState<React.ReactNode>();
  const [busy, setBusy] = useState(false);
  const start = async () => {
    setBusy(true);
    const asked = await askToSignIn();
    if ("error" in asked) {
      setSaid(asked.error);
      return setBusy(false);
    }
    setSaid(
      <>
        React 👍 in Matrix to the message showing
        <span className="mt-2 block font-mono text-3xl tracking-widest text-neutral-900 dark:text-neutral-100">
          {asked.code}
        </span>
      </>,
    );
    if (await waitToSignIn(asked.secret)) return location.reload();
    setSaid("Not let in. Ask again if that was a mistake.");
    setBusy(false);
  };
  return (
    <Centered>
      <div className="flex flex-col items-center gap-4">
        {!busy && (
          <button
            className="rounded-full bg-neutral-900 px-5 py-2 text-white dark:bg-neutral-100 dark:text-neutral-900"
            onClick={start}
          >
            Sign in
          </button>
        )}
        {said && <p>{said}</p>}
      </div>
    </Centered>
  );
}

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
        <ThreadPrimitive.Viewport className="flex flex-1 flex-col overflow-y-auto px-4 pt-6">
          <div className="mx-auto flex w-full max-w-2xl flex-col gap-5">
            <ThreadPrimitive.Messages>
              {({ message }) =>
                message.role === "user" ? <UserMessage /> : message.role === "assistant" ? <AssistantMessage /> : <Note />
              }
            </ThreadPrimitive.Messages>
            {typing && <div className="animate-pulse text-neutral-400">…</div>}
          </div>
          <ThreadPrimitive.ViewportFooter className="sticky bottom-0 mx-auto mt-auto w-full max-w-2xl bg-white pt-4 pb-[max(1rem,env(safe-area-inset-bottom))] dark:bg-neutral-950">
            <ComposerPrimitive.Root className="flex items-end gap-2 rounded-3xl border border-neutral-300 px-4 py-2 dark:border-neutral-700">
              <ComposerPrimitive.Input
                autoFocus
                placeholder="Message"
                className="max-h-48 flex-1 resize-none bg-transparent py-1.5 outline-none"
              />
              <ComposerPrimitive.Send className="rounded-full bg-neutral-900 px-3 py-1.5 text-sm text-white disabled:opacity-30 dark:bg-neutral-100 dark:text-neutral-900">
                Send
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
  return reaction ? <span className="absolute -bottom-3 right-2 text-base">{reaction}</span> : null;
}

function UserMessage() {
  return (
    <MessagePrimitive.Root className="relative ml-auto max-w-[85%] rounded-3xl bg-neutral-100 px-4 py-2.5 whitespace-pre-wrap dark:bg-neutral-800">
      <MessagePrimitive.Parts />
      <Reaction />
    </MessagePrimitive.Root>
  );
}

const Text = () => <StreamdownTextPrimitive plugins={{ code, math }} mode="static" />;

function AssistantMessage() {
  const { plain } = useCustom();
  return (
    <MessagePrimitive.Root className="relative max-w-full leading-relaxed">
      {plain ? (
        <pre className="rounded-xl bg-neutral-100 p-3 text-sm whitespace-pre-wrap dark:bg-neutral-900">
          <MessagePrimitive.Parts />
        </pre>
      ) : (
        <MessagePrimitive.Parts
          components={{
            Text,
            Image: () => <MessagePartPrimitive.Image className="max-w-sm rounded-xl" />,
          }}
        />
      )}
      <Reaction />
    </MessagePrimitive.Root>
  );
}

function Note() {
  return (
    <MessagePrimitive.Root className="text-center text-xs text-neutral-500">
      <MessagePrimitive.Parts />
    </MessagePrimitive.Root>
  );
}
