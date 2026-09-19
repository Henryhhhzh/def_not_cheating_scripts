# type_clipboard

A Hammerspoon script that types your clipboard out keystroke by keystroke with
human cadence — variable delays, longer pauses after sentences and line breaks,
and occasional typos that get noticed, backspaced and corrected.

Typos come from a built-in generator. Sentence drafts come from a small model
running locally through Ollama, so nothing leaves your machine and nothing is
metered. If the model is unavailable the sentence just types normally.

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

Sentence drafting needs Ollama and a small model:

```bash
brew install ollama
brew services start ollama
ollama pull qwen2.5:0.5b
```

That is a 397MB download and about 400MB of RAM while it runs. Without it the
script still works — you get typos, just no sentence drafting.

## How it works

The clipboard is split into chunks of 2–4 words. Each chunk is a `core` (the
words) and a `tail` (the trailing whitespace). Chunks never span a line break,
so a correction never has to backspace over a newline.

Two things keep the pace from reading as mechanical. Speed carries a clamped
random walk across chunks, so the typing has fast and slow stretches rather
than a constant rate that jitter averages back to. And a think pause can stop
it before any chunk, anywhere in the text, independent of punctuation.

About 28% of chunks get a mistake. Most are caught at once:

```
type the wrong version
  pause 0.25–0.7s          <- noticing it
backspace it, 0.02–0.055s per character
  pause 0.08–0.25s
type the correct text
```

The rest are caught late, the way a typo usually is in practice — a
sentence or two after it happened:

```
type the wrong version, carry on for 1-4 chunks
  pause 0.4–1.6s           <- spotting it
← × trail                  <- walk the caret back
backspace it, type the correct text
  pause 0.15–0.5s
→ × trail                  <- walk back to the end
```

Whole sentences get the same treatment. At most one per paragraph is sent to
Claude for a plainer first-draft version, typed in place of the real sentence
and repaired the same way:

```
final : this raised quite a conundrum for one such as himself
draft : this was a real problem for him
```

`trail` is the number of characters typed since the mistake. Because every
one of them sits *after* the cursor, the repair never changes that count, so
the caret lands back exactly where it left. Only one repair is outstanding at
a time, which keeps the count unambiguous.

Every chunk that needs a variant goes into **one** background request, fired as
typing starts. Anything that has not arrived by the time it is needed uses a
local typo instead, so the typing never stalls waiting on the network.

The final text always equals the clipboard exactly. Deletions are counted from
the variant that was actually typed, so nothing can survive a correction.

## Why a small model

The task is to write *worse*, which is the one thing a 0.5B model does without
being asked. Measured on this machine:

| | Claude Haiku | qwen2.5:0.5b |
| --- | --- | --- |
| tokens per paste | ~3,900 in / ~174 out | none |
| time | ~3.5s | ~0.2s |
| network | required | none |

It only follows the task if you show it rather than tell it. With an
instruction-only prompt, two of four sentences came back unchanged. With three
worked examples in the system prompt, all five rewrote cleanly:

```
final : this raised quite a conundrum for one such as himself
draft : this caused a lot of confusion for someone like him
```

Typos deliberately do **not** go through the model. Head to head, the 0.5B
dropped whole words and produced implausible slips like `pnsed`, while the
built-in generator gives clean single-key errors instantly. Keyboard slips are
mechanical, and a language model is the wrong tool for them.

A bad draft cannot corrupt anything: the draft is always replaced by your real
text, so the only thing a weak model costs you is a slightly odd sentence
briefly on screen.

## Configuring it

Open `cadence-console.html` in a browser. It has a live preview that runs the
same typing engine, so you can watch a setting before committing to it. Copy
the JSON it produces to:

```
~/.hammerspoon/type_clipboard_config.json
```

The file is read fresh on every paste, so there is no reload step. Delete it to
go back to defaults.

Every key is optional — anything absent uses the built-in default, and a value
of the wrong type is ignored rather than breaking the run. This is a complete,
valid config:

```json
{ "mistakes": { "chance": 0.5 } }
```

The full shape:

| Key | Default | Effect |
| --- | --- | --- |
| `speed.baseDelay` | `0.055` | Seconds between keystrokes, before jitter |
| `speed.jitterMin/Max` | `0.6, 1.6` | Random multiplier applied per keystroke |
| `speed.spaceFactor` | `0.8` | Spaces are typed quicker than letters |
| `speed.driftAmount` | `0.25` | How far the pace wanders; `0` is a metronome |
| `pauses.startDelay` | `1.5` | Time to focus the target field |
| `pauses.clauseMin/Max` | `0.08, 0.20` | Pause after `,` `;` `:` |
| `pauses.sentenceMin/Max` | `0.25, 0.60` | Pause after `.` `!` `?` |
| `pauses.lineMin/Max` | `0.20, 0.50` | Pause after a line break |
| `pauses.paragraphMin/Max` | `0.80, 2.00` | Pause after a blank line |
| `pauses.thinkChance` | `0.08` | Odds of stopping before a chunk, anywhere |
| `pauses.thinkMin/Max` | `0.60, 2.50` | Length of that pause |
| `mistakes.chance` | `0.28` | Share of eligible chunks typed wrong first |
| `mistakes.chunkMin/Max` | `2, 4` | Words per chunk |
| `mistakes.minLength` | `10` | Chunks shorter than this are never mistyped |
| `mistakes.realizeMin/Max` | `0.25, 0.70` | Beat before noticing the mistake |
| `mistakes.backspaceMin/Max` | `0.02, 0.055` | Per-character delete speed |
| `mistakes.resumeMin/Max` | `0.08, 0.25` | Pause after deleting, before retyping |
| `mistakes.kinds.*` | all `true` | `transpose`, `drop`, `double`, `adjacent` |
| `mistakes.deferredShare` | `0.35` | Share of mistakes repaired late instead of at once |
| `mistakes.deferMin/Max` | `1, 4` | Chunks to keep typing before going back |
| `mistakes.noticeMin/Max` | `0.40, 1.60` | Pause before walking the caret back |
| `mistakes.arrowMin/Max` | `0.012, 0.035` | Per arrow keypress, both directions |
| `mistakes.returnMin/Max` | `0.15, 0.50` | Pause after fixing, before returning |
| `drafts.enabled` | `true` | Draft whole sentences before rewriting them |
| `drafts.chance` | `0.70` | Odds a paragraph gets one drafted sentence |
| `drafts.minLength` | `40` | Sentences shorter than this are left alone |
| `ai.enabled` | `true` | Use the local model for sentence drafts |
| `ai.url` | localhost:11434 | Ollama generate endpoint |
| `ai.model` | `qwen2.5:0.5b` | Local model name |
| `ai.temperature` | `0.9` | Higher wanders further from the original |

## Background

Started as a plain clipboard typer with randomised delays. The chunking, the
mistake-and-correct behaviour and the AI variant layer were added afterwards;
the commit history walks through it, including the two bugs that made the AI
path fail silently on any multi-line text.
