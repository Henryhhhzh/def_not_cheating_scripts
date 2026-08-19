local M = {}

local START_DELAY = 1.5
local BASE_DELAY = 0.055
local JITTER_MIN = 0.6
local JITTER_MAX = 1.6
local SENTENCE_PAUSE_MIN, SENTENCE_PAUSE_MAX = 0.25, 0.60
local CLAUSE_PAUSE_MIN, CLAUSE_PAUSE_MAX = 0.08, 0.20
local LINE_PAUSE_MIN, LINE_PAUSE_MAX = 0.20, 0.50
local SPACE_FACTOR = 0.8

local MISTAKE_CHANCE = 0.28
local WORDS_PER_CHUNK_MIN, WORDS_PER_CHUNK_MAX = 2, 4
local MIN_CORE_LENGTH = 10
local REALIZE_PAUSE_MIN, REALIZE_PAUSE_MAX = 0.25, 0.70
local BACKSPACE_DELAY_MIN, BACKSPACE_DELAY_MAX = 0.02, 0.055
local RESUME_PAUSE_MIN, RESUME_PAUSE_MAX = 0.08, 0.25

local CLAUDE = os.getenv("HOME") .. "/.local/bin/claude"
local MODEL = "claude-haiku-4-5-20251001"
local MAX_LINES_PER_CALL = 40
local SYSTEM_PROMPT = "You corrupt text. Each input line is a fragment of a larger document; fragments are "
  .. "deliberate and must never be completed, explained or asked about. For every input line produce exactly "
  .. "one output string: the same fragment as a person would first mistype it before correcting. Usually a "
  .. "keyboard typo (adjacent-key slip, transposed letters, doubled or dropped letter); occasionally a "
  .. "clumsier wording. Keep the same words and a similar length. Never add or remove words."
local SCHEMA = '{"type":"object","properties":{"lines":{"type":"array","items":{"type":"string"}}},'
  .. '"required":["lines"],"additionalProperties":false}'

local timer = nil
local task = nil
local running = false
local chunks = {}
local variants = {}

local function randRange(lo, hi)
  return lo + math.random() * (hi - lo)
end

local function delayAfter(char)
  local delay = BASE_DELAY * randRange(JITTER_MIN, JITTER_MAX)
  if char == "\n" then
    return delay + randRange(LINE_PAUSE_MIN, LINE_PAUSE_MAX)
  elseif char:match("[%.%!%?]") then
    return delay + randRange(SENTENCE_PAUSE_MIN, SENTENCE_PAUSE_MAX)
  elseif char:match("[,;:]") then
    return delay + randRange(CLAUSE_PAUSE_MIN, CLAUSE_PAUSE_MAX)
  elseif char == " " then
    return delay * SPACE_FACTOR
  end
  return delay
end

local function splitCharacters(text)
  local out = {}
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = char
  end
  return out
end

-- Split into chunks of a few words. `core` is the word text we may mistype;
-- `tail` is the trailing whitespace, typed only on the correct pass so a
-- deletion never has to cross a newline.
local function buildChunks(text)
  local words = {}
  for word, space in text:gmatch("([^%s]*)(%s*)") do
    if word ~= "" or space ~= "" then
      words[#words + 1] = { word = word, space = space }
    end
  end

  local out = {}
  local index = 1
  while index <= #words do
    local take = math.random(WORDS_PER_CHUNK_MIN, WORDS_PER_CHUNK_MAX)
    local last = math.min(index + take - 1, #words)
    local core, tail = "", ""
    local position = index
    repeat
      core = core .. tail .. words[position].word
      tail = words[position].space
      position = position + 1
    until position > last or tail:find("\n")
    if core ~= "" or tail ~= "" then
      out[#out + 1] = {
        core = core,
        tail = tail,
        mistake = #core >= MIN_CORE_LENGTH and math.random() < MISTAKE_CHANCE,
      }
    end
    index = position
  end
  return out
end

local ADJACENT = {
  a = "qsz", b = "vgn", c = "xdv", d = "sfce", e = "wrd", f = "dgrv", g = "fhtb",
  h = "gjyn", i = "uok", j = "hkum", k = "jlim", l = "kop", m = "njk", n = "bhm",
  o = "ipl", p = "ol", q = "wa", r = "etf", s = "adwx", t = "ryg", u = "yij",
  v = "cfb", w = "qes", x = "zsc", y = "tuh", z = "asx",
}

local function localTypo(core)
  local letters = splitCharacters(core)
  local positions = {}
  for index, char in ipairs(letters) do
    if char:match("%a") then
      positions[#positions + 1] = index
    end
  end
  if #positions < 2 then
    return nil
  end

  local pick = positions[math.random(#positions)]
  local mode = math.random(4)

  if mode == 1 and pick < #letters and letters[pick + 1]:match("%a") then
    letters[pick], letters[pick + 1] = letters[pick + 1], letters[pick]
  elseif mode == 2 then
    table.remove(letters, pick)
  elseif mode == 3 then
    table.insert(letters, pick, letters[pick])
  else
    local lower = letters[pick]:lower()
    local neighbours = ADJACENT[lower]
    if not neighbours then
      return nil
    end
    local at = math.random(#neighbours)
    local swap = neighbours:sub(at, at)
    letters[pick] = letters[pick]:match("%u") and swap:upper() or swap
  end

  local result = table.concat(letters)
  if result == core then
    return nil
  end
  return result
end

local function parseVariants(output, indices)
  local ok, decoded = pcall(hs.json.decode, output or "")
  if not ok or type(decoded) ~= "table" or type(decoded.lines) ~= "table" then
    return false
  end
  local lines = decoded.lines
  if #lines ~= #indices then
    return false
  end
  for position, index in ipairs(indices) do
    local line = lines[position]
    local core = chunks[index].core
    if not line:find("\n") and math.abs(#line - #core) <= #core * 0.4 + 3 then
      variants[index] = line
    end
  end
  return true
end

local function requestVariants()
  local indices, prompt = {}, {}
  for index, chunk in ipairs(chunks) do
    if chunk.mistake and #indices < MAX_LINES_PER_CALL then
      indices[#indices + 1] = index
      prompt[#prompt + 1] = chunk.core
    end
  end
  if #indices == 0 then
    return
  end

  local path = os.tmpname()
  local file = io.open(path, "w")
  file:write(table.concat(prompt, "\n"), "\n")
  file:close()

  -- Strip Claude Code's system prompt, tools, CLAUDE.md, skills and MCP config:
  -- ~34.6k tokens per call down to ~3.5k, and thinking off drops output to ~36.
  local command = table.concat({
    "MAX_THINKING_TOKENS=0",
    ("%q"):format(CLAUDE),
    "-p --model " .. MODEL,
    "--system-prompt " .. ("%q"):format(SYSTEM_PROMPT),
    "--json-schema " .. ("%q"):format(SCHEMA),
    "--effort low --safe-mode --strict-mcp-config --disable-slash-commands",
    "--setting-sources ''",
    "--disallowed-tools Bash Read Write Edit Glob Grep WebFetch WebSearch Task TodoWrite",
    "--no-session-persistence",
    "< " .. ("%q"):format(path),
  }, " ")

  task = hs.task.new("/bin/zsh", function(code, stdout)
    task = nil
    os.remove(path)
    if code ~= 0 or not parseVariants(stdout, indices) then
      hs.alert.show("Typo AI unavailable — using local typos", 1)
    end
  end, { "-c", command })

  task:start()
end

local function finish(message)
  running = false
  timer = nil
  if task then
    task:terminate()
    task = nil
  end
  hs.alert.show(message, 1)
end

local typeChunk

local function typeCharacters(characters, index, done)
  if not running then
    return
  end
  if index > #characters then
    done()
    return
  end

  local char = characters[index]
  if char == "\n" then
    hs.eventtap.keyStroke({}, "return", 0)
  elseif char ~= "\r" then
    hs.eventtap.keyStrokes(char)
  end

  timer = hs.timer.doAfter(delayAfter(char), function()
    typeCharacters(characters, index + 1, done)
  end)
end

local function backspace(count, done)
  if not running then
    return
  end
  if count <= 0 then
    done()
    return
  end

  hs.eventtap.keyStroke({}, "delete", 0)
  timer = hs.timer.doAfter(randRange(BACKSPACE_DELAY_MIN, BACKSPACE_DELAY_MAX), function()
    backspace(count - 1, done)
  end)
end

local function typeCorrect(chunk, index)
  typeCharacters(splitCharacters(chunk.core .. chunk.tail), 1, function()
    typeChunk(index + 1)
  end)
end

typeChunk = function(index)
  if not running then
    return
  end
  if index > #chunks then
    finish("Typing done")
    return
  end

  local chunk = chunks[index]
  local wrong = nil
  if chunk.mistake then
    wrong = variants[index]
    if not wrong or wrong == chunk.core then
      wrong = localTypo(chunk.core)
    end
  end
  if not wrong or wrong == chunk.core then
    typeCorrect(chunk, index)
    return
  end

  local wrongCharacters = splitCharacters(wrong)
  typeCharacters(wrongCharacters, 1, function()
    timer = hs.timer.doAfter(randRange(REALIZE_PAUSE_MIN, REALIZE_PAUSE_MAX), function()
      backspace(#wrongCharacters, function()
        timer = hs.timer.doAfter(randRange(RESUME_PAUSE_MIN, RESUME_PAUSE_MAX), function()
          typeCorrect(chunk, index)
        end)
      end)
    end)
  end)
end

function M.start()
  if running then
    hs.alert.show("Already typing — ⌘⌥⌃. to stop")
    return
  end

  local text = hs.pasteboard.getContents()
  if not text or text == "" then
    hs.alert.show("Clipboard is empty")
    return
  end

  chunks = buildChunks(text)
  variants = {}
  running = true
  requestVariants()

  hs.alert.show(("Typing %d chunks in %.1fs — focus the target field"):format(#chunks, START_DELAY), START_DELAY)
  timer = hs.timer.doAfter(START_DELAY, function()
    typeChunk(1)
  end)
end

function M.stop()
  if not running then
    hs.alert.show("Not typing")
    return
  end
  if timer then
    timer:stop()
  end
  finish("Typing stopped")
end

return M
