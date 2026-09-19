local M = {}

local CONFIG_PATH = os.getenv("HOME") .. "/.hammerspoon/type_clipboard_config.json"

local DEFAULTS = {
  speed = {
    baseDelay = 0.055,
    jitterMin = 0.6,
    jitterMax = 1.6,
    spaceFactor = 0.8,
    driftAmount = 0.25,
  },
  pauses = {
    startDelay = 1.5,
    sentenceMin = 0.25, sentenceMax = 0.60,
    clauseMin = 0.08, clauseMax = 0.20,
    lineMin = 0.20, lineMax = 0.50,
    paragraphMin = 0.80, paragraphMax = 2.00,
    thinkChance = 0.08,
    thinkMin = 0.60, thinkMax = 2.50,
  },
  mistakes = {
    chance = 0.28,
    chunkMin = 2, chunkMax = 4,
    minLength = 10,
    realizeMin = 0.25, realizeMax = 0.70,
    backspaceMin = 0.02, backspaceMax = 0.055,
    resumeMin = 0.08, resumeMax = 0.25,
    kinds = {
      transpose = true,
      drop = true,
      double = true,
      adjacent = true,
    },
  },
  ai = {
    enabled = true,
    model = "claude-haiku-4-5-20251001",
    maxLinesPerCall = 40,
  },
}

local CLAUDE = os.getenv("HOME") .. "/.local/bin/claude"
local SYSTEM_PROMPT = "You corrupt text. Each input line is a fragment of a larger document; fragments are "
  .. "deliberate and must never be completed, explained or asked about. For every input line produce exactly "
  .. "one output string: the same fragment as a person would first mistype it before correcting. Usually a "
  .. "keyboard typo (adjacent-key slip, transposed letters, doubled or dropped letter); occasionally a "
  .. "clumsier wording. Keep the same words and a similar length. Never add or remove words."
local SCHEMA = '{"type":"object","properties":{"lines":{"type":"array","items":{"type":"string"}}},'
  .. '"required":["lines"],"additionalProperties":false}'

local cfg = DEFAULTS
local drift = 1
local timer = nil
local task = nil
local running = false
local chunks = {}
local variants = {}

local function merge(defaults, override)
  local out = {}
  for key, value in pairs(defaults) do
    local supplied = override and override[key]
    if type(value) == "table" then
      out[key] = merge(value, type(supplied) == "table" and supplied or nil)
    elseif supplied ~= nil and type(supplied) == type(value) then
      out[key] = supplied
    else
      out[key] = value
    end
  end
  return out
end

local function loadConfig()
  local file = io.open(CONFIG_PATH, "r")
  if not file then
    cfg = DEFAULTS
    return
  end
  local body = file:read("*a")
  file:close()

  local ok, decoded = pcall(hs.json.decode, body)
  if not ok or type(decoded) ~= "table" then
    hs.alert.show("Bad config JSON — using defaults", 2)
    cfg = DEFAULTS
    return
  end
  cfg = merge(DEFAULTS, decoded)
end

local function randRange(lo, hi)
  if hi < lo then
    lo, hi = hi, lo
  end
  return lo + math.random() * (hi - lo)
end

local function delayAfter(char, chars, index)
  local speed, pauses = cfg.speed, cfg.pauses
  local delay = speed.baseDelay * drift * randRange(speed.jitterMin, speed.jitterMax)

  if char == "\n" then
    if chars[index + 1] == "\n" then
      return delay
    elseif chars[index - 1] == "\n" then
      return delay + randRange(pauses.paragraphMin, pauses.paragraphMax)
    end
    return delay + randRange(pauses.lineMin, pauses.lineMax)
  elseif char:match("[%.%!%?]") then
    return delay + randRange(pauses.sentenceMin, pauses.sentenceMax)
  elseif char:match("[,;:]") then
    return delay + randRange(pauses.clauseMin, pauses.clauseMax)
  elseif char == " " then
    return delay * speed.spaceFactor
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

  local mistakes = cfg.mistakes
  local out = {}
  local index = 1
  while index <= #words do
    local take = math.random(mistakes.chunkMin, math.max(mistakes.chunkMin, mistakes.chunkMax))
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
        mistake = #core >= mistakes.minLength and math.random() < mistakes.chance,
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

local function enabledKinds()
  local kinds = {}
  for name, on in pairs(cfg.mistakes.kinds) do
    if on then
      kinds[#kinds + 1] = name
    end
  end
  table.sort(kinds)
  return kinds
end

local ATTEMPTS = 8

local function attemptTypo(core, kinds)
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
  local kind = kinds[math.random(#kinds)]

  if kind == "transpose" then
    if pick >= #letters or not letters[pick + 1]:match("%a") then
      return nil
    end
    letters[pick], letters[pick + 1] = letters[pick + 1], letters[pick]
  elseif kind == "drop" then
    table.remove(letters, pick)
  elseif kind == "double" then
    table.insert(letters, pick, letters[pick])
  else
    local neighbours = ADJACENT[letters[pick]:lower()]
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

-- A chosen kind can fail on a given position (transposing a word's last
-- letter, or a key with no neighbour), so retry before giving up. Without
-- this, narrowing the enabled kinds quietly drops most mistakes.
local function localTypo(core)
  local kinds = enabledKinds()
  if #kinds == 0 then
    return nil
  end
  for _ = 1, ATTEMPTS do
    local result = attemptTypo(core, kinds)
    if result then
      return result
    end
  end
  return nil
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
  if not cfg.ai.enabled then
    return
  end

  local indices, prompt = {}, {}
  for index, chunk in ipairs(chunks) do
    if chunk.mistake and #indices < cfg.ai.maxLinesPerCall then
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
    "-p --model " .. cfg.ai.model,
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

-- Real typing is not stationary: it comes in fast and slow stretches. An
-- independent jitter per keystroke averages back to a metronome, so carry a
-- slow random walk across chunks instead.
local function nudgeDrift()
  local amount = cfg.speed.driftAmount
  if amount <= 0 then
    drift = 1
    return
  end
  drift = drift + randRange(-amount / 3, amount / 3)
  drift = math.max(1 - amount, math.min(1 + amount, drift))
end

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

  timer = hs.timer.doAfter(delayAfter(char, characters, index), function()
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
  local mistakes = cfg.mistakes
  timer = hs.timer.doAfter(randRange(mistakes.backspaceMin, mistakes.backspaceMax), function()
    backspace(count - 1, done)
  end)
end

local function typeCorrect(chunk, index)
  typeCharacters(splitCharacters(chunk.core .. chunk.tail), 1, function()
    typeChunk(index + 1)
  end)
end

local function runChunk(index)
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

  local mistakes = cfg.mistakes
  local wrongCharacters = splitCharacters(wrong)
  typeCharacters(wrongCharacters, 1, function()
    timer = hs.timer.doAfter(randRange(mistakes.realizeMin, mistakes.realizeMax), function()
      backspace(#wrongCharacters, function()
        timer = hs.timer.doAfter(randRange(mistakes.resumeMin, mistakes.resumeMax), function()
          typeCorrect(chunk, index)
        end)
      end)
    end)
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

  nudgeDrift()

  local pauses = cfg.pauses
  if index > 1 and math.random() < pauses.thinkChance then
    timer = hs.timer.doAfter(randRange(pauses.thinkMin, pauses.thinkMax), function()
      if running then
        runChunk(index)
      end
    end)
    return
  end

  runChunk(index)
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

  loadConfig()
  chunks = buildChunks(text)
  variants = {}
  drift = 1
  running = true
  requestVariants()

  local startDelay = cfg.pauses.startDelay
  hs.alert.show(("Typing %d chunks in %.1fs — focus the target field"):format(#chunks, startDelay), startDelay)
  timer = hs.timer.doAfter(startDelay, function()
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
