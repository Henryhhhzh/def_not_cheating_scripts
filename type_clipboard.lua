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
    deferredShare = 0.35,
    deferMin = 1, deferMax = 4,
    arrowMin = 0.012, arrowMax = 0.035,
    noticeMin = 0.40, noticeMax = 1.60,
    returnMin = 0.15, returnMax = 0.50,
    kinds = {
      transpose = true,
      drop = true,
      double = true,
      adjacent = true,
    },
  },
  drafts = {
    enabled = true,
    chance = 0.70,
    minLength = 40,
  },
  ai = {
    enabled = true,
    model = "claude-haiku-4-5-20251001",
    maxLinesPerCall = 40,
  },
}

local CLAUDE = os.getenv("HOME") .. "/.local/bin/claude"
local SYSTEM_PROMPT = "You rough up finished writing. The input has two sections. Every line in both is "
  .. "taken from a real document; lines are deliberate and must never be completed, explained or asked about.\n"
  .. "TYPOS: for each line return the same fragment as a person would first mistype it — a keyboard slip, "
  .. "transposed letters, a doubled or dropped letter. Keep the same words and a similar length.\n"
  .. "DRAFTS: for each line return a plainer, rougher way the writer might have put that same idea in a first "
  .. "draft, before going back and sharpening it. Keep the meaning, voice and tense. Prefer ordinary words over "
  .. "polished ones. It may be shorter or longer, but must be a single line with no line breaks.\n"
  .. "Return one output per input line in each section, in order."
local SCHEMA = '{"type":"object","properties":'
  .. '{"typos":{"type":"array","items":{"type":"string"}},'
  .. '"drafts":{"type":"array","items":{"type":"string"}}},'
  .. '"required":["typos","drafts"],"additionalProperties":false}'

local cfg = DEFAULTS
local drift = 1
local pending = nil
local draftPlan = {}
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
    until position > last or tail:find("\n") or core:match("[%.%!%?][\"')%]]*$")
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

-- A sentence is drafted as a whole, so chunk boundaries have to line up with
-- it; buildChunks ends a chunk at sentence-final punctuation for that reason.
local function planDrafts()
  draftPlan = {}
  if not cfg.drafts.enabled then
    return {}
  end

  local groups, first = {}, 1
  for index, chunk in ipairs(chunks) do
    if chunk.core:match("[%.%!%?][\"')%]]*$") or chunk.tail:find("\n%s*\n") or index == #chunks then
      groups[#groups + 1] = { first = first, last = index }
      first = index + 1
    end
  end

  local byParagraph, paragraph = {}, 1
  for _, group in ipairs(groups) do
    local real = ""
    for index = group.first, group.last - 1 do
      real = real .. chunks[index].core .. chunks[index].tail
    end
    real = real .. chunks[group.last].core
    group.real = real
    group.tail = chunks[group.last].tail

    if not real:find("\n") and #real >= cfg.drafts.minLength then
      byParagraph[paragraph] = byParagraph[paragraph] or {}
      table.insert(byParagraph[paragraph], group)
    end
    if group.tail:find("\n%s*\n") then
      paragraph = paragraph + 1
    end
  end

  local picked = {}
  for _, candidates in pairs(byParagraph) do
    if math.random() < cfg.drafts.chance then
      local group = candidates[math.random(#candidates)]
      draftPlan[group.first] = group
      picked[#picked + 1] = group
    end
  end
  return picked
end

local function parseVariants(output, typoIndices, draftGroups)
  local ok, decoded = pcall(hs.json.decode, output or "")
  if not ok or type(decoded) ~= "table" then
    return false
  end
  local typos, drafts = decoded.typos, decoded.drafts
  if type(typos) ~= "table" or type(drafts) ~= "table" then
    return false
  end
  if #typos ~= #typoIndices or #drafts ~= #draftGroups then
    return false
  end

  for position, index in ipairs(typoIndices) do
    local line = typos[position]
    local core = chunks[index].core
    if not line:find("\n") and math.abs(#line - #core) <= #core * 0.4 + 3 then
      variants[index] = line
    end
  end
  for position, group in ipairs(draftGroups) do
    local line = drafts[position]
    if line ~= "" and not line:find("\n") and line ~= group.real then
      group.text = line
    end
  end
  return true
end

local function requestVariants(draftGroups)
  if not cfg.ai.enabled then
    return
  end

  local indices, lines = {}, { "TYPOS" }
  for index, chunk in ipairs(chunks) do
    if chunk.mistake and #indices < cfg.ai.maxLinesPerCall then
      indices[#indices + 1] = index
      lines[#lines + 1] = chunk.core
    end
  end

  lines[#lines + 1] = "DRAFTS"
  for _, group in ipairs(draftGroups) do
    lines[#lines + 1] = group.real
  end

  if #indices == 0 and #draftGroups == 0 then
    return
  end

  local path = os.tmpname()
  local file = io.open(path, "w")
  file:write(table.concat(lines, "\n"), "\n")
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
    if code ~= 0 or not parseVariants(stdout, indices, draftGroups) then
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
local advance
local doRevision

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

local function pressKey(key, count, done)
  if not running then
    return
  end
  if count <= 0 then
    done()
    return
  end

  hs.eventtap.keyStroke({}, key, 0)
  local mistakes = cfg.mistakes
  timer = hs.timer.doAfter(randRange(mistakes.arrowMin, mistakes.arrowMax), function()
    pressKey(key, count - 1, done)
  end)
end

local function typeCorrect(chunk, index)
  local text = chunk.core .. chunk.tail
  typeCharacters(splitCharacters(text), 1, function()
    advance(index, text)
  end)
end

-- A mistake noticed late is repaired in place: walk back over everything typed
-- since, swap the text, then walk forward again. `trail` counts only characters
-- that sit after the cursor, so the edit never changes it.
doRevision = function(done)
  local revision = pending
  pending = nil

  local mistakes = cfg.mistakes
  timer = hs.timer.doAfter(randRange(mistakes.noticeMin, mistakes.noticeMax), function()
    pressKey("left", revision.trail, function()
      backspace(#splitCharacters(revision.wrong), function()
        typeCharacters(splitCharacters(revision.correct), 1, function()
          timer = hs.timer.doAfter(randRange(mistakes.returnMin, mistakes.returnMax), function()
            pressKey("right", revision.trail, done)
          end)
        end)
      end)
    end)
  end)
end

advance = function(index, typedText)
  if pending then
    pending.trail = pending.trail + #splitCharacters(typedText)
    if index >= pending.due then
      doRevision(function()
        typeChunk(index + 1)
      end)
      return
    end
  end
  typeChunk(index + 1)
end

local function runChunk(index)
  local group = draftPlan[index]
  if group and group.text and not pending then
    local mistakes = cfg.mistakes
    typeCharacters(splitCharacters(group.text), 1, function()
      pending = {
        wrong = group.text,
        correct = group.real,
        trail = 0,
        due = group.last + math.random(mistakes.deferMin, math.max(mistakes.deferMin, mistakes.deferMax)),
      }
      typeCharacters(splitCharacters(group.tail), 1, function()
        advance(group.last, group.tail)
      end)
    end)
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

  local mistakes = cfg.mistakes
  local wrongCharacters = splitCharacters(wrong)

  -- Only one repair is ever outstanding, so the trail count stays unambiguous.
  if not pending and math.random() < mistakes.deferredShare then
    typeCharacters(wrongCharacters, 1, function()
      pending = {
        wrong = wrong,
        correct = chunk.core,
        trail = 0,
        due = index + math.random(mistakes.deferMin, math.max(mistakes.deferMin, mistakes.deferMax)),
      }
      typeCharacters(splitCharacters(chunk.tail), 1, function()
        advance(index, chunk.tail)
      end)
    end)
    return
  end

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
    if pending then
      doRevision(function()
        finish("Typing done")
      end)
    else
      finish("Typing done")
    end
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
  pending = nil
  running = true
  requestVariants(planDrafts())

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
