# hippo

Episodic memory for an AI agent: every chat it has ever had, kept word for
word, and folded into one fixed-size summary that fits in its context.

hippo follows an agent's transcripts as they are written, logs each message,
and keeps a binary tree of summaries over the log. The tree's frontier is the
**view**: the whole history as one block of `id+n|text` lines within a byte
budget. Recent lines cover one message each, older lines cover more. The
agent reads the view at session start, and drills into any line with `zoom`.
Nothing is ever forgotten; it only gets further away.

The design is Victor Taelin's [OptChat](https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449).
OptChat is a chat client of its own; hippo is the same memory bolted onto the
harnesses you already use. It never replaces Claude Code, Codex or OpenCode:
it reads the transcripts they write, builds the tree beside them, and hands
the view back as a file they load as a rule, so a session opens with the
whole history already in context and no tool call. The compactor runs
through the `claude` CLI on a plain subscription, so there is no API bill;
any chat-completions endpoint works as well. One harness's compaction
becomes a handoff, not a loss: Claude Code's PreCompact hook folds the view
first, and the fresh context picks up where the old one stopped.

It is about 5,000 lines of Rust with seven dependencies and has been the
memory of a household of agents since 2026. It is developed inside
[monix](https://github.com/dycli/monix), the NixOS flake those agents live
in, and mirrored here with `git subtree`.

## How it works

**Recording.** A watcher follows Claude Code, Codex and OpenCode transcripts
(OpenCode through its SQLite database) and appends each message to an
append-only day-file log. Secrets of known shapes (API keys, tokens, private
keys, named passwords) are masked before they are written. Nothing else is
dropped; tool calls and results are kept too.

**Compaction.** Messages are the leaves of a binary tree. Each message is
compressed to a line of at most 512 bytes; each pair of lines is merged into
one line covering both, and so on upward. Lines are tagged by kind (`user`,
`talk`, `tool`, `echo`, `note`). A node, once built, is never rewritten.
The compactor calls a model with the compactions' own view (so calls share a
cached prefix), a ruler of 512 dashes for scale, and the step. When a merge's
two halves come from different chats, the step says so, so the model does not
read one chat as a reply to the other.

**The view.** Built nodes tile the log, oldest first, under a 128 KB budget
(about 60k tokens). It changes only by appending each new message and
merging the most due pairs; a merged part never splits, so consecutive views
share all but their end and stay cached. Merges come in batches: past the
budget the view folds down to 64 KB, then only grows. A reader whose context
is about to be rewritten anyway (Claude Code, before a compaction) can ask for
the batch early with `hippo fold`, so the fresh context opens on a 64 KB view
and the chat itself is the raw frontier.

**Reading.** `hippo view` prints the view; `zoom <id> <n>` opens a line into
its two halves, down to the whole message; `search <regex>` reads every
message word for word; `date <id>` says when. The service answers over a
unix socket in a few milliseconds.

## Running it

```
hippo serve [--no-follow]     the service, and the only writer
hippo view                    the whole history as one-line summaries
hippo zoom <id> <n>           open line id+n; n = 1 prints message id whole
hippo date <id>               date and time of message id
hippo search <regex>          search every message, word for word
hippo status                  what the service is doing
hippo fold                    merge the view down to half its budget now
hippo pause / resume          stop or restart the compactor's model calls
hippo audit [YYYY-MM-DD]      check a day of the log against the transcripts
hippo import [--since DATE]   bootstrap an empty store from past transcripts
hippo replay <store> <from> <to>
                              rebuild a scratch store from a date range
```

The service reads its configuration from the environment:

| Variable | Meaning |
| --- | --- |
| `HIPPO_DIR` | the store: log, SQLite tree, socket, `view.md` |
| `HIPPO_ARCHIVE` | older transcripts, for `import` |
| `HIPPO_BACKEND` | `claude` (the `claude` CLI, on a subscription), `http` (any chat-completions endpoint, with `HIPPO_URL` and `HIPPO_HTTP_EXTRA`) or `codex` (`HIPPO_CODEX`) |
| `HIPPO_MODEL`, `HIPPO_EFFORT` | the compactor's model and reasoning effort |
| `HIPPO_LEVELS` | per-level overrides, `level=backend/model/effort` separated by spaces, say `0=claude/haiku/xhigh` |
| `HIPPO_VIEW` | the view budget in bytes, default 128000 |
| `HIPPO_AGENT` | the agent's name in the compactor's prompt |

With `--no-follow` the service only serves and compacts its store; a program
that writes the log itself (a chat bot, say) uses hippo this way.

`nix build` builds it; `nix flake check` runs the tests, clippy with warnings
denied, and rustfmt. `cargo build` works too.

## What was measured

- Five-minute prompt caching instead of one hour cut the cost per compactor
  call by about two thirds.
- Haiku, Sonnet, Opus and two OpenAI models were replayed over the same 512
  messages and judged blind, by level. Haiku at high effort matched Sonnet at
  compressing single messages, once a guard held each line to its message's
  kind, and invented at merges; hence `HIPPO_LEVELS`.
- A real history line as the scale example got copied into summaries as fact;
  so did an invented one. The scale is now a ruler of dashes.
- Chat labels on tree lines proved unreliable and were dropped for the
  session check on merges.

## License

MIT.
