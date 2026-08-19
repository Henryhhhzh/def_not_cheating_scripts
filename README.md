# type_clipboard

A Hammerspoon script that types your clipboard out keystroke by keystroke with
human cadence — variable delays, longer pauses after sentences and line breaks,
and occasional typos that get noticed, backspaced and corrected.

Typo variants come from a headless `claude -p` call. If that fails, is slow, or
you are offline, it falls back to a local generator and keeps going.

## Install

Requires [Hammerspoon](https://www.hammerspoon.org/). Drop `type_clipboard.lua`
into `~/.hammerspoon/` and bind it in `init.lua`:

```lua
local typeClipboard = require("type_clipboard")

hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "V", typeClipboard.start)
hs.hotkey.bind({ "cmd", "alt", "ctrl" }, ".", typeClipboard.stop)
```

Copy some text, focus a field, press <kbd>⌘⌥⌃V</kbd>. You get 1.5s to focus the
target before it starts. <kbd>⌘⌥⌃.</kbd> stops it.

The AI layer needs the `claude` CLI installed and logged in. Without it the
script still works, using local typos only.

## How it works

The clipboard is split into chunks of 2–4 words. Each chunk is a `core` (the
words) and a `tail` (the trailing whitespace). Chunks never span a line break,
so a correction never has to backspace over a newline.

About 28% of chunks get a mistake. Those play out as:

```
type the wrong version
  pause 0.25–0.7s          <- noticing it
backspace it, 0.02–0.055s per character
  pause 0.08–0.25s
type the correct text
```

Every chunk that needs a variant goes into **one** background request, fired as
typing starts. Anything that has not arrived by the time it is needed uses a
local typo instead, so the typing never stalls waiting on the network.

The final text always equals the clipboard exactly. Deletions are counted from
the variant that was actually typed, so nothing can survive a correction.

## Keeping the token cost down

A plain `claude -p` call costs about **34,600 input tokens**, because it loads
Claude Code's system prompt, every tool schema, `CLAUDE.md`, skills and MCP
config. For a task this small that is almost all waste:

|                | before | after |
| -------------- | -----: | ----: |
| input tokens   | 34,600 | 3,500 |
| output tokens  |  1,176 |   123 |
| latency        |   9.7s |  3.5s |

The flags that do it:

```
MAX_THINKING_TOKENS=0 claude -p --model claude-haiku-4-5-20251001 \
  --system-prompt "<task>" \
  --json-schema '{"type":"object","properties":{"lines":{...}},"required":["lines"]}' \
  --effort low --safe-mode --strict-mcp-config --disable-slash-commands \
  --setting-sources '' \
  --disallowed-tools Bash Read Write Edit Glob Grep WebFetch WebSearch Task TodoWrite \
  --no-session-persistence < prompt.txt
```

Three things worth knowing if you copy this:

- `--bare` looks like the right flag but requires `ANTHROPIC_API_KEY` and never
  reads OAuth, so it breaks on a subscription login. `--safe-mode` gets you the
  same stripping without that.
- `--json-schema` earns its extra output tokens. Without it the model prepends
  chatter like *"I'll process these fragments..."*, which breaks any parsing
  that depends on line counts.
- Short or fragmentary input makes the model ask a clarifying question rather
  than do the task. The system prompt has to say that fragments are deliberate.

## Tuning

All at the top of the file:

| Constant | Default | Effect |
| --- | --- | --- |
| `MISTAKE_CHANCE` | `0.28` | Share of chunks that get a typo |
| `WORDS_PER_CHUNK_MIN/MAX` | `2, 4` | Chunk size; lower means smaller corrections |
| `MIN_CORE_LENGTH` | `10` | Chunks shorter than this are never mistyped |
| `BASE_DELAY` | `0.055` | Base per-character delay |
| `REALIZE_PAUSE_MIN/MAX` | `0.25, 0.70` | Pause before noticing a mistake |
| `MAX_LINES_PER_CALL` | `40` | Cap on variants requested per paste |

## Background

Started as a plain clipboard typer with randomised delays. The chunking, the
mistake-and-correct behaviour and the AI variant layer were added afterwards;
the commit history walks through it, including the two bugs that made the AI
path fail silently on any multi-line text.
